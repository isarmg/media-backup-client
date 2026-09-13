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
}
enum LocalCatalog {
    private static let log = Logger(subsystem: "org.sarmg.mediabackup", category: "LocalCatalog")
    static func scan(store: TransferStore, album: String?) throws -> [PhotoAlbum] {
        log.info("catalog begin")
        try store.gallery(["op": "begin_catalog"])
        log.info("catalog database ready")
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        log.info("catalog authorization \(authorization.rawValue)")
        guard authorization == .authorized || authorization == .limited else { return [] }
        let fetch: PHFetchResult<PHAsset>
        if let album, let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album], options: nil).firstObject {
            fetch = PHAsset.fetchAssets(in: collection, options: nil)
        } else { fetch = PHAsset.fetchAssets(with: nil) }
        log.info("catalog fetched \(fetch.count) assets")
        var page: [[String: Any]] = []
        for index in 0..<fetch.count {
            let asset = fetch.object(at: index)
            guard asset.mediaType == .image || asset.mediaType == .video else { continue }
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "媒体"
            let descriptor = try JSONSerialization.data(withJSONObject: ["kind": "photokit", "id": asset.localIdentifier, "name": name])
            page.append(["source_id": asset.localIdentifier, "name": name, "media_kind": asset.mediaType == .video ? "video" : "photo",
                "album_id": album ?? "", "created_ms": Int64((asset.creationDate ?? .distantPast).timeIntervalSince1970 * 1000),
                "modified_ms": Int64((asset.modificationDate ?? asset.creationDate ?? .distantPast).timeIntervalSince1970 * 1000),
                "size": 0, "descriptor": String(decoding: descriptor, as: UTF8.self)])
            if page.count == 200 { try store.gallery(["op": "catalog", "items": page]); page.removeAll(keepingCapacity: true) }
        }
        if !page.isEmpty { try store.gallery(["op": "catalog", "items": page]) }
        log.info("catalog stored; reading albums")
        let albums = PhotoScanner().albums()
        log.info("catalog finished with \(albums.count) albums")
        return albums
    }
    static func page(store: TransferStore, kind: String?, unbacked: Bool, offset: Int, limit: Int = 150) throws -> [LocalMedia] {
        let raw = try store.gallery(["op": "local_page", "album": NSNull(), "media_kind": kind as Any? ?? NSNull(), "unbacked": unbacked, "offset": offset, "limit": limit]) as? [[String: Any]] ?? []
        return raw.compactMap(LocalMedia.init)
    }
}

struct LocalGalleryScreen: View {
    let onSubmitted: () -> Void
    let onSystemPicker: () -> Void
    let onLogin: () -> Void
    @EnvironmentObject private var coordinator: BackupCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var rows: [LocalMedia] = []
    @State private var albums: [PhotoAlbum] = []
    @State private var album: String?
    @State private var kind: String?
    @State private var unbacked = false
    @State private var selected: [String: LocalMedia] = [:]
    @State private var preview: LocalMedia?
    @State private var busy = false
    @State private var more = false
    @State private var access = ""
    @State private var message = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
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
                        Divider()
                        Button("全选筛选结果") { Task { await selectScope() } }
                    } label: { Label("筛选", systemImage: "line.3.horizontal.decrease") }
                        .disabled(busy).buttonStyle(.bordered)
                    Spacer()
                    Menu {
                        Button("从系统照片选择", action: onSystemPicker).accessibilityIdentifier("gallery.system-picker")
                        Button("授权 / 调整照片范围") { Task { await requestAccess() } }
                        Button("刷新图库") { Task { await load(scan: true) } }
                    } label: { Label("添加照片", systemImage: "plus") }.buttonStyle(.bordered).accessibilityIdentifier("gallery.add")
                }
                Text([albums.first(where: { $0.id == album })?.name ?? "全部相册",
                      kind == "video" ? "视频" : kind == "photo" ? "照片" : "照片和视频",
                      unbacked ? "未备份 / 待确认" : "全部状态"].joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if !access.isEmpty { Text(access).font(.caption).foregroundStyle(.secondary) }
                if busy { ProgressView().frame(maxWidth: .infinity) }
                if rows.isEmpty && !busy {
                    GalleryEmptyState(title: "这里还没有照片", message: "添加可访问的照片，或调整筛选条件。", icon: "photo.on.rectangle")
                    Button("选择照片", action: onSystemPicker).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 4)], alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                    ForEach(Array(Set(rows.map(\.day))).sorted(by: >), id: \.self) { day in
                        Section {
                            ForEach(rows.filter { $0.day == day }) { row in localTile(row) }
                        } header: {
                            HStack {
                                Text(day, style: .date).font(.subheadline.bold())
                                Spacer()
                                Button("全选") { Task { await selectScope(day: day) } }.disabled(busy)
                                    .accessibilityLabel("选择此日期的全部照片")
                            }.padding(.vertical, 10).background(Color(uiColor: .systemBackground))
                        }
                    }
                }
                if more { Button("加载更多") { Task { await load(append: true) } }.disabled(busy).frame(maxWidth: .infinity) }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }.padding(.horizontal, 16).padding(.bottom, 12)
        }
        .refreshable { await load(scan: true) }
        .safeAreaInset(edge: .bottom, spacing: 0) { selectionBar }
        .task(id: coordinator.profile) { selected = [:]; await load(scan: true) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load(scan: true) } } }
        .onChange(of: album) { _, _ in Task { await load(scan: true) } }
        .onChange(of: kind) { _, _ in Task { await load() } }
        .onChange(of: unbacked) { _, _ in Task { await load() } }
        .sheet(item: $preview) { row in
            VStack {
                Text(row.name)
                if row.kind == "video" { PhotoKitVideo(id: row.id) }
                else { PhotoKitImage(id: row.id, preview: true) }
                Text(row.status)
                Button(selected[row.id] == nil ? "选择备份" : "取消选择") { toggle(row); preview = nil }
                Button(row.excluded ? "恢复自动备份" : "不再自动备份此项目") {
                    do { try coordinator.store().gallery(["op": "exclude", "source_id": row.id, "excluded": !row.excluded]); preview = nil; Task { await load() } }
                    catch { message = error.localizedDescription }
                }
            }.padding()
        }
    }
    private func localTile(_ row: LocalMedia) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        PhotoKitImage(id: row.id, preview: false)
                            .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                            .contentShape(Rectangle()).onTapGesture { preview = row }
                            .onLongPressGesture { toggle(row) }
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if row.kind == "video" {
                        Image(systemName: "video.fill").font(.caption).foregroundStyle(.white)
                            .padding(6).background(.black.opacity(0.45), in: Capsule()).padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(selected[row.id] == nil ? Color.clear : Color.accentColor, lineWidth: 3) }
                .overlay(alignment: .topTrailing) {
                    GallerySelectionButton(selected: selected[row.id] != nil, name: row.name) { toggle(row) }
                }
            Text(row.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            if row.excluded { Text("自动备份已排除").font(.caption2).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("media.tile.\(row.name)")
    }
    private var selectionBar: some View {
        VStack(spacing: 10) {
            if !selected.isEmpty {
                HStack {
                    Text("已选 \(selected.count) 项").font(.subheadline.bold())
                    Spacer()
                    Button("清空选择") { selected = [:] }.font(.subheadline)
                }
            }
            Button {
                if coordinator.authorizationCode.isEmpty || coordinator.serverURL.isEmpty { onLogin(); return }
                let descriptors = selected.values.map(\.descriptor); selected = [:]; onSubmitted()
                Task { await coordinator.enqueueLocal(descriptors) }
            } label: {
                Label(coordinator.authorizationCode.isEmpty ? "配对后备份" : selected.isEmpty ? "勾选照片开始备份" : "备份所选 \(selected.count) 项", systemImage: "icloud.and.arrow.up")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .disabled(busy || coordinator.running || (selected.isEmpty && !coordinator.authorizationCode.isEmpty))
            .buttonStyle(.borderedProminent)
        }.padding(.horizontal, 16).padding(.vertical, 12).background(.regularMaterial)
    }
    private func requestAccess() async {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if authorization == .limited, let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.windows.first(where: \.isKeyWindow), let controller = window.rootViewController {
            await PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
        }
        await load(scan: true)
    }
    private func toggle(_ row: LocalMedia) { if selected.removeValue(forKey: row.id) == nil { selected[row.id] = row } }
    @MainActor private func load(scan: Bool = false, append: Bool = false) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let identity = coordinator.profile
        do {
            let store = try coordinator.store(); let filter = kind; let missing = unbacked; let chosenAlbum = album
            if scan {
                let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                access = authorization == .authorized ? "完整访问" : authorization == .limited ? "部分访问：仅显示已授权媒体" : "无相册访问权：仍可使用系统选择器"
                let fetched = try await Task.detached { try LocalCatalog.scan(store: store, album: chosenAlbum) }.value
                guard identity == coordinator.profile else { return }
                albums = fetched; selected = [:]
            }
            let offset = append ? rows.count : 0
            let page = try await Task.detached { try LocalCatalog.page(store: store, kind: filter, unbacked: missing, offset: offset) }.value
            guard identity == coordinator.profile else { return }
            rows = append ? rows + page : page; more = page.count == 150
        } catch { message = error.localizedDescription }
    }
    @MainActor private func selectScope(day: Date? = nil) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let identity = coordinator.profile
        do {
            let store = try coordinator.store(); let filter = kind; let missing = unbacked
            let chosen = try await Task.detached { () -> [LocalMedia] in
                var all: [LocalMedia] = []; var offset = 0
                while true {
                    let page = try LocalCatalog.page(store: store, kind: filter, unbacked: missing, offset: offset, limit: 1000)
                    all.append(contentsOf: page.filter { day == nil || $0.day == day }); offset += page.count
                    if page.count < 1000 { return all }
                }
            }.value
            guard identity == coordinator.profile else { return }
            for row in chosen { selected[row.id] = row }
        } catch { message = error.localizedDescription }
    }
}
struct PhotoKitImage: View {
    let id: String
    let preview: Bool
    @State private var image: UIImage?
    @State private var request: PHImageRequestID?
    var body: some View {
        Group {
            if let image {
                if preview { ZoomablePhoto(image: image) } else { Image(uiImage: image).resizable().scaledToFill() }
            } else { Text("预览待加载").frame(maxWidth: .infinity, minHeight: 100) }
        }.onAppear {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
            let options = PHImageRequestOptions(); options.deliveryMode = .opportunistic; options.isNetworkAccessAllowed = preview
            request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: preview ? 2048 : 300, height: preview ? 2048 : 300), contentMode: .aspectFit, options: options) { value, _ in
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
