import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

private enum MediaSheet: Identifiable {
    case picker
    case confirmation(UUID, [PHPickerResult])
    var id: String {
        switch self {
        case .picker: return "picker"
        case .confirmation(let id, _): return id.uuidString
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var coordinator: BackupCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var mediaSheet: MediaSheet?
    @State private var pendingMediaSheet: MediaSheet?
    @State private var account = false
    @AppStorage("gallery_cache_mib") private var cacheLimit = 256
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                LocalGalleryScreen(onSubmitted: { tab = 2 }, onSystemPicker: { pendingMediaSheet = nil; mediaSheet = .picker }, onLogin: { account = true })
                    .id(coordinator.profile).navigationTitle("本地图库")
                    .toolbar { accountToolbar }
            }.tabItem { Label("本地", systemImage: "photo.on.rectangle") }.tag(0)
            NavigationStack {
                Group {
                    if coordinator.serverURL.isEmpty || coordinator.authorizationCode.isEmpty {
                        VStack {
                            GalleryEmptyState(title: "登录后查看云端照片", message: "随时浏览、收藏和下载已备份的媒体。", icon: "cloud")
                            Button("登录账户") { account = true }.buttonStyle(.borderedProminent)
                        }
                    } else { CloudGalleryScreen().id(coordinator.profile) }
                }.navigationTitle("云端图库").toolbar { accountToolbar }
            }.tabItem { Label("云端", systemImage: "cloud") }.tag(1)
            NavigationStack { transfers.navigationTitle("传输").toolbar { accountToolbar } }
                .tabItem { Label("传输", systemImage: "arrow.up.arrow.down") }.tag(2)
            NavigationStack { settings.navigationTitle("设置").toolbar { accountToolbar } }
                .tabItem { Label("设置", systemImage: "gear") }.tag(3)
        }
        .sheet(isPresented: $account, onDismiss: {
            if tab == 1, coordinator.library != nil { Task { await coordinator.refreshLibrary() } }
        }) { AccountScreen() }
        .sheet(item: $mediaSheet, onDismiss: {
            // Present the next sheet only after UIKit has dismissed the picker.
            // The confirmation owns an immutable copy of the selected results.
            if let next = pendingMediaSheet { pendingMediaSheet = nil; mediaSheet = next }
        }) { sheet in
            switch sheet {
            case .picker:
                SelectedMediaPicker { results in
                    pendingMediaSheet = results.isEmpty ? nil : .confirmation(UUID(), results)
                    mediaSheet = nil
                }
            case .confirmation(_, let results): selectionConfirmation(results)
            }
        }
        .onChange(of: coordinator.profile) { _, _ in pendingMediaSheet = nil; mediaSheet = nil }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { coordinator.refreshTransfers() }
        }
    }
    @ToolbarContentBuilder private var accountToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(coordinator.authorizationCode.isEmpty ? "配对" : "实例") { account = true }
                .accessibilityIdentifier("account.open")
        }
    }
    private func selectionConfirmation(_ selection: [PHPickerResult]) -> some View {
        let selectedVideos = selection.filter { $0.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }.count
        return VStack(alignment: .leading, spacing: 16) {
            Text("选择要备份的媒体").font(.title.bold())
            Text("在系统照片网格中预览并勾选，确认后只备份所选项目。")
            Button("取消本次选择") { mediaSheet = nil }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(selection.indices, id: \.self) { index in
                        PickerSelectionThumbnail(result: selection[index], index: index)
                    }
                }
            }
            Text("已选择 \(selection.count - selectedVideos) 张照片、\(selectedVideos) 个视频；原始大小将在准备文件时确认。")
            Text("可访问 PhotoKit 原始资源时备份完整资产，否则保存选择器交付的导入副本。")
                .font(.caption).foregroundStyle(.secondary)
            Button("备份所选 \(selection.count) 项") {
                let results = selection; mediaSheet = nil; tab = 2
                Task { await coordinator.runBackup(selection: results) }
            }
            .disabled(selection.isEmpty || coordinator.running || coordinator.serverURL.isEmpty || coordinator.authorizationCode.isEmpty)
            .buttonStyle(.borderedProminent)
        }.padding()
    }
    private var transfers: some View {
        List {
            Section {
                Label(coordinator.status, systemImage: coordinator.running ? "arrow.triangle.2.circlepath" : "tray")
                    .font(.subheadline)
                Button("继续待处理任务") { Task { await coordinator.runBackup() } }
                    .disabled(coordinator.running || coordinator.authorizationCode.isEmpty)
            }
            Section("上传 · \(coordinator.batches.count) 个批次") {
                if coordinator.batches.isEmpty { Text("还没有上传任务，在本地图库选择照片开始备份。").foregroundStyle(.secondary) }
                ForEach(coordinator.batches) { batch in
                    DisclosureGroup {
                        ForEach(batch.items.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(itemName(batch.items[index])).lineLimit(2)
                                Text(itemStatus(batch.items[index])).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                        HStack {
                            Button("重试批次") { Task { await coordinator.changeBatch(batch.id, retry: true) } }
                            Spacer()
                            Button("取消上传", role: .destructive) { Task { await coordinator.changeBatch(batch.id, retry: false) } }
                                .disabled(batch.cancelled)
                        }.buttonStyle(.borderless)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(batch.cancelled ? "已取消的批次" : "照片备份").font(.headline)
                            ProgressView(value: Double(batch.complete), total: Double(max(1, batch.count)))
                            Text("\(batch.complete) / \(batch.count) 项完成").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }
            }
            Section("下载") {
                if coordinator.downloads.isEmpty { Text("暂无下载任务").foregroundStyle(.secondary) }
                ForEach(coordinator.downloads) { download in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(download.name).lineLimit(2)
                        Text("\(download.phase) · \(download.bytes / 1048576) / \(download.total / 1048576) MiB")
                            .font(.caption).foregroundStyle(.secondary)
                        if download.total > 0 { ProgressView(value: Double(download.bytes), total: Double(download.total)) }
                    }
                }
            }
        }
        .task { while !Task.isCancelled { coordinator.refreshTransfers(); do { try await Task.sleep(for: .seconds(2)) } catch { break } } }
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
            Section("账户") {
                Label(coordinator.authorizationCode.isEmpty ? "尚未配对" : "备份实例已配对", systemImage: "person.crop.circle.fill")
                    .font(.headline)
                if !coordinator.serverURL.isEmpty { Text(coordinator.serverURL).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Button("登录 / 切换账户") { account = true }.accessibilityIdentifier("settings.login")
            }
            Section("备份偏好") {
                Toggle("自动备份", isOn: $coordinator.autoBackup)
                Toggle("仅 Wi-Fi 上传", isOn: $coordinator.wifiOnly)
                Toggle("后台仅充电时运行", isOn: $coordinator.chargingOnly)
                Button("保存备份偏好") { coordinator.saveSettings() }
            }
            Section {
                DisclosureGroup("自动备份相册") {
                    Button("选择可访问的相册") { Task { await coordinator.refreshAlbums() } }
                    ForEach(coordinator.albums) { album in
                        Toggle("\(album.name)（\(album.count) 项）", isOn: Binding(
                            get: { coordinator.selectedAlbumIds.contains(album.id) },
                            set: { coordinator.setAlbum(album.id, enabled: $0) }))
                    }
                }
            } footer: { Text("手动选择不受自动相册限制。关闭相册不会删除云端照片。") }
            Section("浏览缓存") {
                Stepper("磁盘缓存：\(cacheLimit) MiB", value: $cacheLimit, in: 64...1024, step: 64)
                Button("清空浏览缓存") { Task {
                    do { try await RemoteImageCache.shared.clear(); coordinator.status = "浏览缓存已清空" }
                    catch { coordinator.status = error.localizedDescription }
                } }
            }
            Section { Text(coordinator.status).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}
