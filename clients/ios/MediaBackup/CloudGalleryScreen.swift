import SwiftUI
import UIKit

struct CloudGalleryScreen: View {
    @EnvironmentObject private var coordinator: BackupCoordinator
    @State private var selected: RemoteAsset?
    @State private var dateFilter = false
    @State private var startDate = Date().addingTimeInterval(-30 * 86400)
    @State private var endDate = Date().addingTimeInterval(86400)
    var body: some View {
        VStack {
            HStack {
                Button("刷新") { Task { await coordinator.refreshLibrary() } }
                Button(coordinator.showingTrash ? "返回云端" : "回收站") {
                    Task { await coordinator.refreshLibrary(trashed: !coordinator.showingTrash) }
                }
                Button(coordinator.favoritesOnly ? "全部" : "收藏") {
                    coordinator.favoritesOnly.toggle()
                    Task { await coordinator.refreshLibrary() }
                }
            }
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
            Text(coordinator.status).font(.caption)
            if coordinator.libraryLoading { ProgressView() }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))]) {
                    ForEach(coordinator.remoteAssets) { asset in
                        Button { selected = asset } label: {
                            VStack {
                                CloudImage(asset: asset, library: coordinator.library, profile: coordinator.profile, preview: false)
                                    .frame(height: 110).clipped()
                                Text(asset.mediaKind == "video" ? "视频" : "照片").font(.caption)
                                Text(Date(timeIntervalSince1970: Double(asset.sourceCreatedAtMs) / 1000), style: .date).font(.caption2)
                            }
                        }
                    }
                }
                if coordinator.nextCursor != nil {
                    Button("加载更多") { Task { await coordinator.loadLibraryPage() } }
                        .disabled(coordinator.libraryLoading)
                        .task(id: coordinator.nextCursor) { await coordinator.loadLibraryPage() }
                }
            }
            .refreshable { await coordinator.refreshLibrary() }
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
        .sheet(item: $selected) { asset in
            PhotoViewerScreen(initial: asset).environmentObject(coordinator)
        }
        .onChange(of: coordinator.profile) { _, _ in selected = nil }
    }
}

struct CloudImage: View {
    let asset: RemoteAsset
    let library: RemoteLibrary?
    let profile: String
    let preview: Bool
    @State private var image: UIImage?
    @State private var message = "暂无预览"
    var body: some View {
        Group {
            if let image {
                if preview { ZoomablePhoto(image: image) }
                else { Image(uiImage: image).resizable().scaledToFill() }
            } else { Text(message).frame(maxWidth: .infinity, minHeight: 90).background(.quaternary) }
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
    var body: some View {
        VStack {
            HStack {
                Button("关闭") { dismiss() }
                if let asset = coordinator.remoteAssets.first(where: { $0.id == (selected ?? initial.id) }) {
                    Button("保存到手机") { Task { await coordinator.restoreToPhone(asset) } }
                    Button(asset.favorite ? "取消收藏" : "收藏") { Task { await coordinator.toggleFavorite(asset); dismiss() } }
                    Button(asset.isTrashed ? "撤销删除" : "回收站") { Task { await coordinator.toggleTrash(asset); dismiss() } }
                }
            }
            if let asset = coordinator.remoteAssets.first(where: { $0.id == (selected ?? initial.id) }) {
                HStack {
                    Button(asset.archived ? "取消归档" : "归档") { Task { await coordinator.toggleArchived(asset); dismiss() } }
                    TextField("标签", text: $coordinator.newTagName)
                    Button("加标签") { Task { await coordinator.addTag(asset); dismiss() } }.disabled(coordinator.newTagName.isEmpty)
                }
            }
            TabView(selection: $selected) {
                ForEach(coordinator.remoteAssets) { asset in
                    Group {
                        if asset.mediaKind == "video", let library = coordinator.library, let primary = asset.primary {
                            CloudVideo(library: library, resource: primary, active: (selected ?? initial.id) == asset.id)
                        } else { CloudImage(asset: asset, library: coordinator.library, profile: coordinator.profile, preview: true) }
                    }.tag(Optional(asset.id))
                }
            }.tabViewStyle(.page)
            Text("查看只使用应用缓存；双指缩放，左右切换").font(.caption)
            Text(coordinator.status).font(.caption)
        }
        .padding()
        .onAppear { selected = initial.id }
    }
}

struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Delegate { Delegate() }
    func makeUIView(context: Context) -> UIScrollView {
        let view = UIScrollView()
        view.minimumZoomScale = 1; view.maximumZoomScale = 5
        view.delegate = context.coordinator
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
    func updateUIView(_ view: UIScrollView, context: Context) { context.coordinator.imageView?.image = image }
    final class Delegate: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
