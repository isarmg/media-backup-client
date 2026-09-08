import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var coordinator: BackupCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var picker = false
    @AppStorage("gallery_cache_mib") private var cacheLimit = 256
    @State private var confirmPicker = false
    @State private var selection: [PHPickerResult] = []
    var body: some View {
        TabView(selection: $tab) {
            LocalGalleryScreen(onSubmitted: { tab = 2 }, onSystemPicker: { selection = []; picker = true }).id(coordinator.profile).tabItem { Label("本地", systemImage: "photo.on.rectangle") }.tag(0)
            CloudGalleryScreen().id(coordinator.profile).padding().tabItem { Label("云端", systemImage: "cloud") }.tag(1)
            transfers.tabItem { Label("传输", systemImage: "arrow.up.arrow.down") }.tag(2)
            settings.tabItem { Label("设置", systemImage: "gear") }.tag(3)
        }
        .sheet(isPresented: $picker, onDismiss: { confirmPicker = !selection.isEmpty }) {
            SelectedMediaPicker { results in selection = results; picker = false }
        }
        .sheet(isPresented: $confirmPicker, onDismiss: { selection = [] }) { local }
        .onChange(of: coordinator.profile) { _, _ in selection = [] }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { coordinator.refreshTransfers() }
        }
    }
    private var selectedVideos: Int { selection.filter { $0.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }.count }
    private var local: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择要备份的媒体").font(.title.bold())
            Text("在系统照片网格中预览并勾选，确认后只备份所选项目。")
            Button("取消本次选择") { selection = []; confirmPicker = false }
            List(selection.indices, id: \.self) { index in
                Text(selection[index].itemProvider.suggestedName ?? "媒体 \(index + 1)")
            }
            Text("已选择 \(selection.count - selectedVideos) 张照片、\(selectedVideos) 个视频；原始大小将在准备文件时确认。")
            Text("可访问 PhotoKit 原始资源时备份完整资产，否则保存选择器交付的导入副本。")
                .font(.caption).foregroundStyle(.secondary)
            Button("备份所选 \(selection.count) 项") {
                let results = selection; selection = []; confirmPicker = false; tab = 2
                Task { await coordinator.runBackup(selection: results) }
            }
            .disabled(selection.isEmpty || coordinator.running || coordinator.serverURL.isEmpty || coordinator.username.isEmpty)
            .buttonStyle(.borderedProminent)
        }.padding()
    }
    private var transfers: some View {
        List {
            Text(coordinator.status)
            Button("继续待处理任务") { Task { await coordinator.runBackup() } }.disabled(coordinator.running)
            Section("下载") {
                ForEach(coordinator.downloads) { download in
                    Text("\(download.name) · \(download.phase) · \(download.bytes / 1048576) / \(download.total / 1048576) MiB")
                }
            }
            Text("上传")
            ForEach(coordinator.batches) { batch in
                VStack(alignment: .leading, spacing: 8) {
                    Text("所选批次：\(batch.complete) / \(batch.count) 项完成")
                    if batch.cancelled { Text("已取消本次上传") }
                    ForEach(batch.items.indices, id: \.self) { index in
                        Text(itemName(batch.items[index]) + " · " + itemStatus(batch.items[index])).font(.caption)
                    }
                    HStack {
                        Button("取消本次上传") { Task { await coordinator.changeBatch(batch.id, retry: false) } }
                        Button("重试批次") { Task { await coordinator.changeBatch(batch.id, retry: true) } }
                    }.buttonStyle(.borderless)
                }
            }
        }
        .task { while !Task.isCancelled { coordinator.refreshTransfers(); try? await Task.sleep(for: .seconds(2)) } }
    }
    private func itemName(_ item: [String: Any]) -> String {
        guard let source = item["source"] as? String,
            let descriptor = try? JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any] else { return "媒体" }
        return descriptor["name"] as? String ?? "媒体"
    }
    private func itemStatus(_ item: [String: Any]) -> String {
        if item["state"] as? String == "blocked" {
            let expected = (item["originals_expected"] as? Int) ?? 0
            let originalDone = expected > 0 && ((item["originals_complete"] as? Int) ?? 0) >= expected
            return (originalDone ? "原件已备份，关联资源待重试：" : "") + ((item["error"] as? String) ?? "需要重新授权访问")
        }
        let count = (item["resources"] as? Int) ?? 0
        let complete = (item["complete"] as? Int) ?? 0
        if count > 0 && complete == count && item["state"] as? String == "queued" { return "所选资源已备份" }
        if let error = item["upload_error"] as? String {
            return ((item["originals_expected"] as? Int) ?? 0) > 0 && ((item["originals_complete"] as? Int) ?? 0) >= ((item["originals_expected"] as? Int) ?? 0) ? "原始资源已备份，关联资源待重试：\(error)" : "等待重试：\(error)"
        }
        return item["state"] as? String == "queued" ? "排队中 / 上传中" : "正在准备原始文件"
    }
    private var settings: some View {
        Form {
            TextField("HTTPS 服务器根地址", text: $coordinator.serverURL).textInputAutocapitalization(.never).keyboardType(.URL)
            TextField("备份账户", text: $coordinator.username).textInputAutocapitalization(.never)
            SecureField("密码", text: $coordinator.password)
            Toggle("自动备份", isOn: $coordinator.autoBackup)
            Toggle("仅 Wi-Fi 上传", isOn: $coordinator.wifiOnly)
            Toggle("后台仅充电时运行", isOn: $coordinator.chargingOnly)
            Button("授权并读取自动备份相册") { Task { await coordinator.refreshAlbums() } }
            ForEach(coordinator.albums) { album in
                Toggle("\(album.name)（\(album.count) 项）", isOn: Binding(
                    get: { coordinator.selectedAlbumIds.contains(album.id) },
                    set: { coordinator.setAlbum(album.id, enabled: $0) }))
            }
            Button("保存设置") { coordinator.saveSettings() }
            Stepper("图片磁盘缓存：\(cacheLimit) MiB", value: $cacheLimit, in: 64...1024, step: 64)
            Button("清空浏览图片缓存") { Task { do { try await RemoteImageCache.shared.clear(); coordinator.status = "浏览缓存已清空" } catch { coordinator.status = error.localizedDescription } } }
            Text("关闭相册不会删除云端内容。手动选择不受自动相册限制。图片内存缓存上限：24 MiB。")
                .font(.caption)
            Text(coordinator.status)
        }
    }
}
