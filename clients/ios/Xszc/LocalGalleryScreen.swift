import SwiftUI
import Photos
import AVKit
import os

struct LocalMedia: Identifiable {
    let id: String
    let name: String
    let kind: String
    let created: Int64
    let descriptor: String
    let state: String
    let excluded: Bool
    init?(_ raw: [String: Any]) {
        guard let id = raw["source_id"] as? String, let descriptor = raw["descriptor"] as? String else { return nil }
        self.id = id; self.descriptor = descriptor
        name = raw["name"] as? String ?? "媒体"; kind = raw["media_kind"] as? String ?? "photo"
        created = (raw["created_ms"] as? Int64) ?? 0; state = (raw["backup_state"] as? String) ?? "unknown"
        excluded = (raw["excluded"] as? Bool) ?? false
    }
    var day: Date { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double(created) / 1000)) }
    var status: String {
        switch state {
        case "complete": "已备份"
        case "original_complete": "原件完成，缩略图待重试"
        case "queued": "排队中"
        case "uploading": "上传中"
        case "failed": "备份失败"
        default: "状态待确认"
        }
    }
    var statusSymbol: String? {
        switch state {
        case "complete": "checkmark.circle.fill"
        case "original_complete": "exclamationmark.triangle.fill"
        case "queued", "uploading": "arrow.up.circle.fill"
        case "failed": "exclamationmark.triangle.fill"
        default: nil
        }
    }
}
struct LocalCatalogPage {
    let rows: [LocalMedia]
    let hasMore: Bool
}

private struct LocalGalleryQuery: Equatable {
    let profile: String
    let album: String?
    let kind: String?
    let unbacked: Bool
}

enum LocalCatalog {
    static let pageSize = 150
    private static let log = Logger(subsystem: "org.sarmg.xszc", category: "LocalCatalog")
    static func scan(store: TransferStore, album: String?) throws -> [PhotoAlbum] {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        log.info("catalog authorization \(authorization.rawValue)")
        guard authorization == .authorized || authorization == .limited else {
            throw CoordinatorFailure.message("需要重新授权访问本地照片")
        }
        var selectedMembers = Set<String>()
        if let album {
            guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject else {
                throw CoordinatorFailure.message("所选相册不可访问，请重新选择")
            }
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                selectedMembers.insert(asset.localIdentifier)
            }
        }
        log.info("catalog begin")
        try store.gallery(["op": "begin_catalog"])
        log.info("catalog database ready")
        let fetch = PHAsset.fetchAssets(with: nil)
        log.info("catalog fetched \(fetch.count) assets")
        var page: [[String: Any]] = []
        for index in 0..<fetch.count {
            let asset = fetch.object(at: index)
            guard asset.mediaType == .image || asset.mediaType == .video else { continue }
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "媒体"
            let descriptor = try JSONSerialization.data(withJSONObject: ["kind": "photokit", "id": asset.localIdentifier, "name": name])
            page.append(["source_id": asset.localIdentifier, "name": name, "media_kind": asset.mediaType == .video ? "video" : "photo",
                "album_id": selectedMembers.contains(asset.localIdentifier) ? (album ?? "") : "",
                "created_ms": Int64((asset.creationDate ?? .distantPast).timeIntervalSince1970 * 1000),
                "modified_ms": Int64((asset.modificationDate ?? asset.creationDate ?? .distantPast).timeIntervalSince1970 * 1000),
                "size": 0, "descriptor": String(decoding: descriptor, as: UTF8.self)])
            if page.count == 200 { try store.gallery(["op": "catalog", "items": page]); page.removeAll(keepingCapacity: true) }
        }
        if !page.isEmpty { try store.gallery(["op": "catalog", "items": page]) }
        log.info("catalog stored; reading albums")
        let albums = PhotoScanner().albums()
        try store.gallery(["op": "finish_catalog"])
        log.info("catalog finished with \(albums.count) albums")
        return albums
    }
    static func page(store: TransferStore, album: String?, kind: String?, unbacked: Bool, offset: Int,
        limit: Int = pageSize) throws -> [LocalMedia] {
        guard let raw = try store.gallery(["op": "local_page", "album": album as Any? ?? NSNull(),
            "media_kind": kind as Any? ?? NSNull(), "unbacked": unbacked, "offset": offset, "limit": limit]) as? [[String: Any]] else {
            throw CoordinatorFailure.message("本地图库分页数据无效，请重试")
        }
        return raw.compactMap(LocalMedia.init)
    }

    static func window(store: TransferStore, album: String?, kind: String?, unbacked: Bool,
        offset: Int = 0, count: Int = pageSize) throws -> LocalCatalogPage {
        var rows: [LocalMedia] = []
        let capacity = max(1, count)
        while rows.count < capacity {
            try Task.checkCancellation()
            let limit = min(pageSize, capacity - rows.count)
            // One extra row determines whether another page actually exists.
            let fetched = try page(store: store, album: album, kind: kind, unbacked: unbacked,
                offset: offset + rows.count, limit: limit + 1)
            rows.append(contentsOf: fetched.prefix(limit))
            if fetched.count <= limit { return LocalCatalogPage(rows: rows, hasMore: false) }
        }
        return LocalCatalogPage(rows: rows, hasMore: true)
    }
}

private final class LocalPhotoLibraryChanges: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var revision = 0
    @MainActor private var assets: PHFetchResult<PHAsset>?
    @MainActor private var collections: PHFetchResult<PHAssetCollection>?
    @MainActor private var libraryAlbums: PHFetchResult<PHAssetCollection>?
    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    @MainActor func trackLibrary() {
        assets = PHAsset.fetchAssets(with: nil)
        collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        libraryAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil)
    }
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var changed = false
            if let assets, let details = changeInstance.changeDetails(for: assets) {
                self.assets = details.fetchResultAfterChanges
                changed = true
            }
            if let collections, let details = changeInstance.changeDetails(for: collections) {
                self.collections = details.fetchResultAfterChanges
                changed = true
            }
            if let libraryAlbums, let details = changeInstance.changeDetails(for: libraryAlbums) {
                self.libraryAlbums = details.fetchResultAfterChanges
                changed = true
            }
            // Thumbnail/cache notifications unrelated to our fetches must not restart a scan.
            if changed { revision += 1 }
        }
    }
}

struct LocalGalleryScreen: View {
    let onSubmitted: () -> Void
    let onLogin: () -> Void
    @EnvironmentObject private var coordinator: BackupCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var rows: [LocalMedia] = []
    @State private var albums: [PhotoAlbum] = []
    @State private var album: String?
    @State private var kind: String?
    @State private var unbacked = false
    @State private var selected: [String: LocalMedia] = [:]
    @State private var selectionScopes: [Date: Set<String>] = [:]
    @State private var selectionGeneration = 0
    @State private var preview: LocalMedia?
    @State private var videoPreview: LocalMedia?
    @State private var isSelecting = false
    @AppStorage("gallery_grid_columns") private var gridColumns = 3
    @State private var pinchStartColumns: Int?
    @GestureState private var isPinching = false
    private var displayedColumns: Int { min(8, max(1, gridColumns)) }
    @State private var busy = false
    @State private var loadingMore = false
    @State private var more = false
    @State private var loadedQuery: LocalGalleryQuery?
    @State private var loadedCapacity = LocalCatalog.pageSize
    @State private var message = ""
    @StateObject private var photoChanges = LocalPhotoLibraryChanges()
    @State private var queuedRefresh = false
    @State private var queuedScan = false
    private var hasFilters: Bool { album != nil || kind != nil || unbacked }
    private var needsPairing: Bool { coordinator.serverURL.isEmpty || coordinator.authorizationCode.isEmpty }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("已载入 \(rows.count) 项")
                        .font(.subheadline.weight(.medium))
                        .accessibilityIdentifier("gallery.loaded-count")
                    if isSelecting {
                        Text("已选 \(selected.count) 项").font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("gallery.selected-count")
                    }
                    Spacer(minLength: 8)
                    if hasFilters { Button("清除筛选") { clearFilters() }.font(.subheadline) }
                }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.red) }
                if busy && !loadingMore {
                    ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("gallery.loading")
                }
                if rows.isEmpty && !busy {
                    GalleryEmptyState(title: hasFilters ? "没有符合条件的照片" : "这里还没有照片",
                        message: hasFilters ? "清除筛选后查看全部可访问的媒体。" : "允许访问选定照片或全部照片后，在这里浏览和备份。",
                        icon: "photo.on.rectangle")
                    if hasFilters {
                        Button("清除筛选") { clearFilters() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    } else {
                        Text("请在“设置 → 照片权限设置”中授权访问照片。")
                            .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: displayedColumns),
                    alignment: .leading, spacing: 3) {
                    ForEach(Array(Set(rows.map(\.day))).sorted(by: >), id: \.self) { day in
                        Section {
                            ForEach(rows.filter { $0.day == day }) { row in localTile(row) }
                        } header: {
                            HStack {
                                Text(day, style: .date).font(.subheadline.bold())
                                    .accessibilityIdentifier("gallery.date.\(Int(day.timeIntervalSince1970))")
                                Spacer()
                                if isSelecting {
                                    let allSelected = isDaySelected(day)
                                    Button(allSelected ? "取消全选" : "全选") {
                                        Task { await selectScope(day: day, deselect: allSelected) }
                                    }.disabled(busy)
                                        .accessibilityLabel(allSelected ? "取消此日期的全选" : "选择此日期的全部照片")
                                        .accessibilityIdentifier("gallery.select-day.\(Int(day.timeIntervalSince1970))")
                                }
                            }.padding(.vertical, 10).background(Color(uiColor: .systemBackground))
                        }
                    }
                }
                .accessibilityIdentifier("gallery.grid")
                if more {
                    if loadingMore {
                        ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("gallery.loading-more")
                    } else {
                        Button("加载更多") { Task { await load(append: true) } }
                            .disabled(busy).frame(maxWidth: .infinity).accessibilityIdentifier("gallery.load-more")
                    }
                }
            }.padding(.horizontal, 16).padding(.top, 64).padding(.bottom, 12)
        }
        .accessibilityIdentifier("gallery.scroll")
        .simultaneousGesture(MagnifyGesture(minimumScaleDelta: 0.02)
            .updating($isPinching) { _, active, _ in active = true }
            .onChanged { value in updateGridScale(value.magnification) }
            .onEnded { _ in pinchStartColumns = nil })
        .onChange(of: isPinching) { _, active in
            if !active { pinchStartColumns = nil }
        }
        .overlay(alignment: .top) {
            galleryToolbar.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .scrollEdgeEffectHidden(true, for: .all)
        .task(id: coordinator.profile) {
            resetSelection()
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
                _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            photoChanges.trackLibrary()
            await load(scan: true)
        }
        .onChange(of: photoChanges.revision) { _, _ in Task { await load(scan: true) } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load(scan: true) } } }
        .onChange(of: album) { _, _ in filtersChanged(scan: true) }
        .onChange(of: kind) { _, _ in filtersChanged() }
        .onChange(of: unbacked) { _, _ in filtersChanged() }
        .fullScreenCover(item: Binding(get: { preview }, set: { setPreview($0) })) { row in
            ZStack {
                Color.black.ignoresSafeArea().onTapGesture { setPreview(nil) }
                PhotoKitImage(id: row.id, preview: true, onTap: { setPreview(nil) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("照片预览")
                    .accessibilityAction(named: "关闭照片") { setPreview(nil) }
                    .contextMenu {
                        Button(selected[row.id] == nil ? "选择备份" : "取消选择") { isSelecting = true; toggle(row); setPreview(nil) }
                        Button(row.excluded ? "恢复自动备份" : "不再自动备份此项目") {
                            do { try coordinator.store().gallery(["op": "exclude", "source_id": row.id, "excluded": !row.excluded]); setPreview(nil); Task { await load() } }
                            catch { message = error.localizedDescription }
                        }
                    }
            }
            .accessibilityIdentifier("gallery.preview")
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
        }
        .sheet(item: $videoPreview) { row in
            VStack {
                Text(row.name)
                PhotoKitVideo(id: row.id)
                Text(row.status)
                Button(selected[row.id] == nil ? "选择备份" : "取消选择") { isSelecting = true; toggle(row); videoPreview = nil }
                Button(row.excluded ? "恢复自动备份" : "不再自动备份此项目") {
                    do { try coordinator.store().gallery(["op": "exclude", "source_id": row.id, "excluded": !row.excluded]); videoPreview = nil; Task { await load() } }
                    catch { message = error.localizedDescription }
                }
            }.padding()
        }
    }
    private var galleryToolbar: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("相册", selection: $album) {
                    Text("全部相册").tag(Optional<String>.none)
                    ForEach(albums) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("类型", selection: $kind) {
                    Text("照片和视频").tag(Optional<String>.none)
                    Text("照片").tag(Optional("photo")); Text("视频").tag(Optional("video"))
                }
                Toggle("仅未备份 / 待确认", isOn: $unbacked)
            } label: { Text("筛选") }
                .disabled(busy).accessibilityIdentifier("gallery.filter")
            Spacer(minLength: 0)
            Button(action: submitBackup) { Text("备份") }
                .disabled(busy || coordinator.running).accessibilityIdentifier("gallery.backup")
            if isSelecting {
                Button { Task { await selectScope() } } label: { Text("全选") }
                    .disabled(busy).accessibilityIdentifier("gallery.select-all")
                Button { resetSelection() } label: { Text("取消") }
                    .accessibilityIdentifier("gallery.cancel-selection")
            } else {
                Button { isSelecting = true } label: { Text("选择") }
                    .accessibilityIdentifier("gallery.select")
            }
        }.buttonStyle(.glass).controlSize(.regular)
    }
    private func setPreview(_ row: LocalMedia?) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { preview = row }
    }
    private func submitBackup() {
        if needsPairing { onLogin(); return }
        if selected.isEmpty { isSelecting = true; return }
        let descriptors = selected.values.map(\.descriptor)
        resetSelection(); onSubmitted()
        Task { await coordinator.enqueueLocal(descriptors) }
    }
    private func updateGridScale(_ scale: CGFloat) {
        if pinchStartColumns == nil { pinchStartColumns = displayedColumns }
        guard let startingColumns = pinchStartColumns else { return }
        let columns = min(8, max(1, Int((CGFloat(startingColumns) / max(0.05, scale)).rounded())))
        if columns != gridColumns {
            withAnimation(.easeOut(duration: 0.12)) { gridColumns = columns }
        }
    }
    private func localTile(_ row: LocalMedia) -> some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    PhotoKitImage(id: row.id, preview: false)
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                        .contentShape(Rectangle()).onTapGesture {
                            if isSelecting { toggle(row) }
                            else if row.kind == "video" { videoPreview = row }
                            else { setPreview(row) }
                        }
                        .onLongPressGesture {
                            isSelecting = true
                            if selected[row.id] == nil { toggle(row) }
                        }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if row.kind == "video" {
                    Image(systemName: "video.fill").font(.caption).foregroundStyle(.white)
                        .padding(6).background(.black.opacity(0.55), in: Capsule()).padding(5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let symbol = row.statusSymbol {
                    Image(systemName: symbol).font(.caption).foregroundStyle(.white)
                        .padding(6).background(.black.opacity(0.55), in: Circle()).padding(5)
                        .accessibilityLabel(row.status)
                }
            }
            .overlay(alignment: .topLeading) {
                if row.excluded {
                    Image(systemName: "slash.circle.fill").font(.caption).foregroundStyle(.white)
                        .padding(6).background(.black.opacity(0.55), in: Circle()).padding(5)
                        .accessibilityLabel("自动备份已排除")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    GeometryReader { proxy in
                        GallerySelectionButton(selected: selected[row.id] != nil, name: row.name,
                            action: { toggle(row) }, size: min(44, max(24, proxy.size.width * 0.8)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("media.tile.\(row.name)")
    }
    private func isDaySelected(_ day: Date) -> Bool {
        // The final loaded date may continue onto the next page.
        guard selectionScopes[day] != nil || !more || rows.last?.day != day else { return false }
        let ids = (selectionScopes[day] ?? []).union(rows.filter { $0.day == day }.map(\.id))
        return !ids.isEmpty && ids.allSatisfy { selected[$0] != nil }
    }
    private func resetSelection() {
        selectionGeneration += 1
        selected = [:]; selectionScopes = [:]
        isSelecting = false
    }
    private func toggle(_ row: LocalMedia) {
        selectionGeneration += 1
        if selected.removeValue(forKey: row.id) == nil { selected[row.id] = row }
    }
    private func clearFilters() {
        album = nil; kind = nil; unbacked = false
    }
    private func filtersChanged(scan: Bool = false) {
        selectionGeneration += 1; selectionScopes = [:]
        Task { await load(scan: scan) }
    }
    @MainActor private func load(scan: Bool = false, append: Bool = false) async {
        guard !busy else {
            if !append { queuedRefresh = true; queuedScan = queuedScan || scan }
            return
        }
        let query = LocalGalleryQuery(profile: coordinator.profile, album: album, kind: kind, unbacked: unbacked)
        let appending = append && loadedQuery == query
        let offset = appending ? rows.count : 0
        let count = appending || loadedQuery != query ? LocalCatalog.pageSize : loadedCapacity
        busy = true
        loadingMore = appending
        defer {
            busy = false
            loadingMore = false
            if queuedRefresh {
                let scan = queuedScan
                queuedRefresh = false; queuedScan = false
                Task { await load(scan: scan) }
            }
        }
        let identity = coordinator.profile
        do {
            let store = try coordinator.store(); let filter = kind; let missing = unbacked; let chosenAlbum = album
            if scan {
                let fetched = try await Task.detached { try LocalCatalog.scan(store: store, album: chosenAlbum) }.value
                guard identity == coordinator.profile, chosenAlbum == album, filter == kind, missing == unbacked else {
                    queuedRefresh = true; queuedScan = true; return
                }
                albums = fetched
            }
            let page = try await Task.detached { try LocalCatalog.window(store: store, album: chosenAlbum,
                kind: filter, unbacked: missing, offset: offset, count: count) }.value
            guard identity == coordinator.profile, chosenAlbum == album, filter == kind, missing == unbacked else {
                queuedRefresh = true; queuedScan = queuedScan || chosenAlbum != album; return
            }
            rows = appending ? rows + page.rows : page.rows
            loadedCapacity = appending ? loadedCapacity + LocalCatalog.pageSize : count
            loadedQuery = query; more = page.hasMore; message = ""
        } catch { message = error.localizedDescription }
    }
    @MainActor private func selectScope(day: Date? = nil, deselect: Bool = false) async {
        guard isSelecting, !busy else { return }
        let generation = selectionGeneration
        busy = true
        defer {
            busy = false
            if queuedRefresh {
                let scan = queuedScan
                queuedRefresh = false; queuedScan = false
                Task { await load(scan: scan) }
            }
        }
        let identity = coordinator.profile
        do {
            let store = try coordinator.store(); let filter = kind; let missing = unbacked; let chosenAlbum = album
            let chosen = try await Task.detached { () -> [LocalMedia] in
                var all: [LocalMedia] = []; var offset = 0
                while true {
                    let page = try LocalCatalog.page(store: store, album: chosenAlbum,
                        kind: filter, unbacked: missing, offset: offset, limit: 1000)
                    all.append(contentsOf: page.filter { day == nil || $0.day == day }); offset += page.count
                    if page.count < 1000 { return all }
                }
            }.value
            guard isSelecting, generation == selectionGeneration,
                identity == coordinator.profile, chosenAlbum == album, filter == kind, missing == unbacked else { return }
            if let day {
                selectionScopes[day] = Set(chosen.map(\.id))
            } else {
                selectionScopes = Dictionary(grouping: chosen, by: \.day).mapValues { Set($0.map(\.id)) }
            }
            for row in chosen {
                if deselect { selected.removeValue(forKey: row.id) }
                else { selected[row.id] = row }
            }
        } catch { message = error.localizedDescription }
    }
}
struct PhotoKitImage: View {
    let id: String
    let preview: Bool
    var onTap: (() -> Void)? = nil
    var thumbnailSize: CGFloat = 300
    @State private var image: UIImage?
    @State private var request: PHImageRequestID?
    var body: some View {
        Group {
            if let image {
                if preview { ZoomablePhoto(image: image, onTap: onTap) } else { Image(uiImage: image).resizable().scaledToFill() }
            } else if preview { Color.black.onTapGesture { onTap?() } }
            else { Color(uiColor: .secondarySystemBackground).overlay { Image(systemName: "photo").foregroundStyle(.tertiary) } }
        }.onAppear {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
            let options = PHImageRequestOptions(); options.deliveryMode = .opportunistic; options.isNetworkAccessAllowed = preview
            request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: preview ? 2048 : thumbnailSize, height: preview ? 2048 : thumbnailSize), contentMode: .aspectFit, options: options) { value, _ in
                DispatchQueue.main.async { image = value }
            }
        }.onDisappear { if let request { PHImageManager.default().cancelImageRequest(request) }; image = nil }
    }
}
struct PhotoKitVideo: UIViewControllerRepresentable {
    let id: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
            let options = PHVideoRequestOptions(); options.isNetworkAccessAllowed = true
            context.coordinator.request = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                DispatchQueue.main.async { controller.player = item.map { AVPlayer(playerItem: $0) } }
            }
        }
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        if let request = coordinator.request { PHImageManager.default().cancelImageRequest(request) }
        controller.player?.pause(); controller.player = nil
    }
    final class Coordinator { var request: PHImageRequestID? }
}
