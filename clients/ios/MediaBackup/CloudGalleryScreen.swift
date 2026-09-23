import SwiftUI
import UIKit

private struct RemoteMonthGroup: Identifiable {
    let id: Date
    let assets: [RemoteAsset]
}

struct CloudGalleryScreen: View {
    @EnvironmentObject private var coordinator: BackupCoordinator
    @State private var selected: RemoteAsset?
    @State private var dateFilter = false
    @State private var showFilters = false
    @State private var showDuplicates = false
    @State private var startDate = Date().addingTimeInterval(-30 * 86400)
    @State private var endDate = Date().addingTimeInterval(86400)
    @AppStorage("gallery_grid_columns") private var gridColumns = 3
    private var monthGroups: [RemoteMonthGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: coordinator.remoteAssets) { asset in
            calendar.dateInterval(of: .month, for: Date(timeIntervalSince1970: Double(asset.sourceCreatedAtMs) / 1000))?.start ?? .distantPast
        }
        return grouped.keys.sorted(by: >).map { RemoteMonthGroup(id: $0, assets: grouped[$0] ?? []) }
    }
    private var hasFilters: Bool {
        coordinator.favoritesOnly || coordinator.selectedRemoteAlbum != nil || coordinator.cloudFilters != CloudFilters()
    }
    private var emptyTitle: String {
        if coordinator.libraryError != nil { return "云端图库加载失败" }
        if coordinator.showingTrash { return "回收站为空" }
        return hasFilters ? "没有符合条件的照片" : "云端还没有照片"
    }
    private var emptyMessage: String {
        if let error = coordinator.libraryError { return error }
        if coordinator.showingTrash { return "已移入回收站的媒体会显示在这里。" }
        return hasFilters ? "清除筛选后查看全部云端媒体。" : "从本地图库选择照片，开始备份。"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button { showFilters = true } label: { Label("筛选", systemImage: "line.3.horizontal.decrease") }
                        .buttonStyle(.bordered)
                    Button {
                        coordinator.favoritesOnly.toggle(); Task { await coordinator.refreshLibrary() }
                    } label: { Label(coordinator.favoritesOnly ? "已收藏" : "收藏", systemImage: coordinator.favoritesOnly ? "heart.fill" : "heart") }
                        .buttonStyle(.bordered)
                    Spacer()
                    GalleryGridSizeControl(columns: $gridColumns)
                    Menu {
                        Button("刷新图库") { Task { await coordinator.refreshLibrary() } }
                        Button(coordinator.showingTrash ? "返回全部照片" : "打开回收站") {
                            Task { await coordinator.refreshLibrary(trashed: !coordinator.showingTrash) }
                        }
                        Button("查看重复项") {
                            showDuplicates = true
                            Task { await coordinator.loadDuplicateGroups() }
                        }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                        .accessibilityLabel("图库选项")
                }
                if coordinator.showingTrash { Label("回收站", systemImage: "trash").font(.headline) }
                HStack(alignment: .firstTextBaseline) {
                    Text("已载入 \(coordinator.remoteAssets.count) 项\(coordinator.nextCursor == nil ? "" : "，可继续加载")")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if hasFilters { Button("清除筛选") { clearFilters() }.font(.subheadline) }
                }
                if !coordinator.status.isEmpty && !coordinator.status.hasPrefix("已加载 ") && (coordinator.libraryError == nil || !coordinator.remoteAssets.isEmpty) {
                    Text(coordinator.status).font(.caption).foregroundStyle(.secondary)
                }
                if coordinator.libraryLoading { ProgressView().frame(maxWidth: .infinity) }
                if coordinator.remoteAssets.isEmpty && !coordinator.libraryLoading {
                    GalleryEmptyState(title: emptyTitle, message: emptyMessage,
                        icon: coordinator.libraryError == nil && coordinator.showingTrash ? "trash" : "cloud")
                    if coordinator.libraryError != nil || coordinator.showingTrash || hasFilters {
                        Button(coordinator.libraryError != nil ? "重试" : coordinator.showingTrash ? "返回全部照片" : "清除筛选") {
                            if coordinator.libraryError != nil { Task { await coordinator.refreshLibrary() } }
                            else { clearFilters(returnFromTrash: coordinator.showingTrash) }
                        }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: min(5, max(2, gridColumns))),
                    spacing: 3, pinnedViews: [.sectionHeaders]) {
                    ForEach(monthGroups) { group in
                        Section {
                            ForEach(group.assets) { asset in
                                Button { selected = asset } label: {
                                    Color.clear.aspectRatio(1, contentMode: .fit).overlay {
                                        GeometryReader { proxy in
                                            CloudImage(asset: asset, library: coordinator.library, profile: coordinator.profile, preview: false)
                                                .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(alignment: .bottomLeading) {
                                        if asset.mediaKind == "video" {
                                            Image(systemName: "video.fill").font(.caption).foregroundStyle(.white)
                                                .padding(6).background(.black.opacity(0.55), in: Capsule()).padding(5)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(asset.mediaKind == "video" ? "视频" : "照片")，\(asset.primary?.filename ?? "未命名媒体")")
                            }
                        } header: {
                            Text(group.id.formatted(.dateTime.year().month(.wide)))
                                .font(.subheadline.bold()).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10).background(Color(uiColor: .systemBackground))
                        }
                    }
                }
                .simultaneousGesture(MagnifyGesture().onEnded { value in
                    let scale = value.magnification
                    if scale > 1.18 { gridColumns = max(2, gridColumns - 1) }
                    else if scale < 0.85 { gridColumns = min(5, gridColumns + 1) }
                })
                if coordinator.nextCursor != nil {
                    Button("加载更多") { Task { await coordinator.loadLibraryPage() } }
                        .disabled(coordinator.libraryLoading).frame(maxWidth: .infinity)
                        .task(id: coordinator.nextCursor) { await coordinator.loadLibraryPage() }
                }
            }.padding(.horizontal, 16).padding(.bottom, 16)
        }
        .refreshable { await coordinator.refreshLibrary() }
        .sheet(isPresented: $showFilters) {
            NavigationStack {
                Form { filterControls }
                    .navigationTitle("筛选云端照片").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showFilters = false } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDuplicates) {
            NavigationStack {
                List {
                    if coordinator.duplicateGroups.isEmpty && !coordinator.libraryLoading {
                        Text("没有检测到内容相同的媒体。")
                    }
                    ForEach(Array(coordinator.duplicateGroups.enumerated()), id: \.element.id) { index, group in
                        Section("第 \(index + 1) 组 · \(group.assets.count) 项 · \(group.contentSize) 字节") {
                            ForEach(group.assets) { asset in
                                Text(asset.primary?.filename ?? asset.sourceAssetId)
                            }
                        }
                    }
                }
                .navigationTitle("重复项")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showDuplicates = false } } }
            }
        }
        .task(id: coordinator.profile) {
            if coordinator.remoteAssets.isEmpty { await coordinator.refreshLibrary() }
            while !Task.isCancelled {
                if selected == nil { await coordinator.synchronizeGallery() }
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
        .onChange(of: coordinator.cloudFilters) { _, _ in Task { await coordinator.refreshLibrary() } }
        .onChange(of: dateFilter) { _, enabled in if !enabled { coordinator.cloudFilters.from = nil; coordinator.cloudFilters.to = nil } }
        .fullScreenCover(item: $selected) { asset in
            PhotoViewerScreen(initial: asset).environmentObject(coordinator)
        }
        .onChange(of: coordinator.profile) { _, _ in selected = nil }
    }
    private func clearFilters(returnFromTrash: Bool = false) {
        coordinator.favoritesOnly = false
        coordinator.selectedRemoteAlbum = nil
        coordinator.cloudFilters = CloudFilters()
        dateFilter = false
        Task { await coordinator.refreshLibrary(trashed: returnFromTrash ? false : nil) }
    }
    private var filterControls: some View {
        Group {
            Picker("云端相册", selection: $coordinator.selectedRemoteAlbum) {
                Text("所有云端相册").tag(Optional<UUID>.none)
                ForEach(coordinator.remoteAlbums) { album in Text(album.name).tag(Optional(album.id)) }
            }.onChange(of: coordinator.selectedRemoteAlbum) { _, _ in Task { await coordinator.refreshLibrary() } }
            HStack {
                Picker("类型", selection: $coordinator.cloudFilters.kind) {
                    Text("全部类型").tag(Optional<String>.none)
                    Text("照片").tag(Optional("photo")); Text("视频").tag(Optional("video"))
                }
                Picker("设备", selection: $coordinator.cloudFilters.device) {
                    Text("所有设备").tag(Optional<String>.none)
                    ForEach(coordinator.remoteDevices) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            Toggle("按日期区间筛选", isOn: $dateFilter)
            if dateFilter {
                DatePicker("开始日期", selection: $startDate, displayedComponents: .date)
                DatePicker("结束日期（不含）", selection: $endDate, displayedComponents: .date)
                Button("应用日期") {
                    guard startDate < endDate else { coordinator.status = "结束日期应晚于开始日期"; return }
                    coordinator.cloudFilters.from = Int64(Calendar.current.startOfDay(for: startDate).timeIntervalSince1970 * 1000)
                    coordinator.cloudFilters.to = Int64(Calendar.current.startOfDay(for: endDate).timeIntervalSince1970 * 1000)
                }
            }
        }
    }

}

struct CloudImage: View {
    let asset: RemoteAsset
    let library: RemoteLibrary?
    let profile: String
    let preview: Bool
    var onTap: (() -> Void)? = nil
    @State private var image: UIImage?
    @State private var message = "暂无预览"
    var body: some View {
        Group {
            if let image {
                if preview { ZoomablePhoto(image: image, onTap: onTap) }
                else { Image(uiImage: image).resizable().scaledToFill() }
            } else if preview { Color.black.onTapGesture { onTap?() } }
            else { Text(message).frame(maxWidth: .infinity, minHeight: 90).background(.quaternary) }
        }
        .task(id: "\(profile)-\(asset.id)-\(preview)") {
            image = nil
            guard let library else { return }
            do {
                if let thumbnail = asset.thumbnail {
                    image = try await RemoteImageCache.shared.image(library: library, profile: profile, resource: thumbnail, preview: false)
                }
                if preview && asset.mediaKind != "video", let primary = asset.primary {
                    image = try await RemoteImageCache.shared.image(library: library, profile: profile, resource: primary, preview: true)
                }
                if asset.mediaKind == "video" { message = "视频" }
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}

struct PhotoViewerScreen: View {
    let initial: RemoteAsset
    @EnvironmentObject private var coordinator: BackupCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var addingTag = false
    @State private var confirmingDelete = false
    private var current: RemoteAsset? { coordinator.remoteAssets.first { $0.id == (selected ?? initial.id) } }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().onTapGesture { dismiss() }
            TabView(selection: $selected) {
                ForEach(coordinator.remoteAssets) { asset in
                    Group {
                        if asset.mediaKind == "video", let library = coordinator.library, let primary = asset.primary {
                            ZStack(alignment: .top) {
                                CloudVideo(library: library, resource: primary, active: (selected ?? initial.id) == asset.id)
                                HStack {
                                    Button("关闭") { dismiss() }
                                    Spacer()
                                    Menu { assetActions(asset) } label: { Image(systemName: "ellipsis.circle") }
                                        .accessibilityLabel("视频操作")
                                }
                                .foregroundStyle(.white).padding()
                            }
                        } else {
                            CloudImage(asset: asset, library: coordinator.library, profile: coordinator.profile,
                                preview: true, onTap: { dismiss() })
                                .accessibilityLabel("照片预览")
                                .accessibilityAction(named: "关闭照片") { dismiss() }
                                .contextMenu { assetActions(asset) }
                        }
                    }
                    .tag(Optional(asset.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .alert("添加标签", isPresented: $addingTag) {
            TextField("标签名称", text: $coordinator.newTagName)
            Button("取消", role: .cancel) {}
            Button("添加") { if let asset = current { Task { await coordinator.addTag(asset); dismiss() } } }
                .disabled(coordinator.newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("永久删除照片？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("永久删除", role: .destructive) {
                if let asset = current { Task { await coordinator.deletePermanently(asset); dismiss() } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作无法撤销。服务器可能在后台继续回收未引用的文件。")
        }.onAppear { selected = initial.id }
    }
    @ViewBuilder private func assetActions(_ asset: RemoteAsset) -> some View {
        Button("保存到手机") { Task { await coordinator.restoreToPhone(asset) } }
        Button(asset.favorite ? "取消收藏" : "收藏") { Task { await coordinator.toggleFavorite(asset); dismiss() } }
        Button(asset.archived ? "取消归档" : "归档") { Task { await coordinator.toggleArchived(asset); dismiss() } }
        Button("添加标签") { coordinator.newTagName = ""; addingTag = true }
        ForEach(asset.tagNames, id: \.self) { name in
            Button("移除标签：\(name)") { Task { await coordinator.removeTag(name, from: asset); dismiss() } }
        }
        Button(asset.isTrashed ? "恢复照片" : "移入回收站") { Task { await coordinator.toggleTrash(asset); dismiss() } }
        if asset.isTrashed { Button("永久删除", role: .destructive) { confirmingDelete = true } }
    }
}

struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    var onTap: (() -> Void)? = nil
    func makeCoordinator() -> Delegate { Delegate(onTap: onTap) }
    func makeUIView(context: Context) -> UIScrollView {
        let view = UIScrollView()
        view.minimumZoomScale = 1; view.maximumZoomScale = 5
        view.delegate = context.coordinator
        view.backgroundColor = .black
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Delegate.handleTap))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: view.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: view.frameLayoutGuide.heightAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.contentLayoutGuide.bottomAnchor)
        ])
        context.coordinator.imageView = imageView
        return view
    }
    func updateUIView(_ view: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        context.coordinator.onTap = onTap
    }
    final class Delegate: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        var onTap: (() -> Void)?
        init(onTap: (() -> Void)?) { self.onTap = onTap }
        @objc func handleTap() { onTap?() }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
