import BackgroundTasks
import Foundation
import Photos
import PhotosUI

struct DownloadTransfer: Identifiable { let id: UUID; let name: String; let total: Int64; var bytes: Int64; var phase: String }

@MainActor
final class BackupCoordinator: ObservableObject {
    static let shared = BackupCoordinator()
    @Published var serverURL = MobileContractV02.preferences.string(forKey: "server_url") ?? "" {
        didSet { if oldValue != serverURL { credentialsChanged() } }
    }
    @Published var username = KeychainStore.load("username") ?? "" {
        didSet { if oldValue != username { credentialsChanged() } }
    }
    @Published var password = KeychainStore.load("password") ?? "" {
        didSet { if oldValue != password { credentialsChanged() } }
    }
    @Published var status = "请配置备份账户，或选择要备份的媒体"
    @Published var running = false
    @Published var autoBackup = MobileContractV02.preferences.bool(forKey: "auto_backup")
    @Published var wifiOnly = (MobileContractV02.preferences.object(forKey: "wifi_only") as? Bool) ?? true
    @Published var chargingOnly = MobileContractV02.preferences.bool(forKey: "charging_only")
    @Published var albums: [PhotoAlbum] = []
    @Published var selectedAlbumIds = Set(MobileContractV02.preferences.stringArray(forKey: "selected_album_ids") ?? [])
    @Published var remoteAssets: [RemoteAsset] = []
    @Published var showingTrash = false
    @Published var remoteAlbums: [RemoteAlbum] = []
    @Published var selectedRemoteAlbum: UUID?
    @Published var newTagName = ""
    @Published var cloudFilters = CloudFilters()
    @Published var remoteDevices: [RemoteDevice] = []
    @Published var favoritesOnly = false
    @Published var libraryLoading = false
    @Published var nextCursor: String?
    @Published var downloads: [DownloadTransfer] = []
    @Published var batches: [TransferBatch] = []
    @Published var library: RemoteLibrary?
    private var libraryGeneration = 0
    private var seenCursors = Set<String>()
    private var uploader: BackgroundUploader?
    private var stores: [String: TransferStore] = [:]
    private var credentialGeneration = 0
    var profile: String { profileKey(server: serverURL, username: username) }

    private func credentialsChanged() {
        credentialGeneration += 1
        libraryGeneration += 1
        uploader?.cancel(); uploader = nil
        downloads = []; library = nil; remoteAssets = []; remoteAlbums = []; selectedRemoteAlbum = nil; nextCursor = nil; batches = []; libraryLoading = false
    }
    func stopTransfers() { uploader?.cancel(); uploader = nil }
    func store() throws -> TransferStore {
        if let existing = stores[profile] { return existing }
        let value = try TransferStore(profile: profile)
        stores[profile] = value
        return value
    }
    func saveSettings() {
        do {
            guard let url = URL(string: serverURL), url.scheme == "https", url.host != nil,
                url.user == nil, url.password == nil, url.path.isEmpty || url.path == "/",
                url.query == nil, url.fragment == nil, !username.isEmpty, !password.isEmpty else {
                throw CoordinatorFailure.message("请输入 HTTPS 根地址、备份账户和密码")
            }
            let changed = MobileContractV02.preferences.string(forKey: "server_url") != serverURL
                || KeychainStore.load("username") != username || KeychainStore.load("password") != password
            if changed { KeychainStore.delete(MobileContractV02.tokenKey) }
            MobileContractV02.preferences.set(serverURL, forKey: "server_url")
            try KeychainStore.save(username, for: "username"); try KeychainStore.save(password, for: "password")
            MobileContractV02.preferences.set(autoBackup, forKey: "auto_backup")
            MobileContractV02.preferences.set(wifiOnly, forKey: "wifi_only")
            MobileContractV02.preferences.set(chargingOnly, forKey: "charging_only")
            status = "设置已保存"
            if autoBackup { scheduleBackgroundRun() }
        } catch { status = error.localizedDescription }
    }
    func login(server: String, username user: String, password secret: String) async throws {
        let credentials = try AccountLogin(server: server, username: user, password: secret)
        let generation = credentialGeneration
        let response = try await credentials.authenticate()
        try Task.checkCancellation()
        guard generation == credentialGeneration else { throw CancellationError() }
        let address = credentials.server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let newProfile = profileKey(server: address, username: credentials.username)
        let targetStore = try TransferStore(profile: newProfile)
        try targetStore.client.transfer(["op": "bind", "server": address,
            "account_id": response.accountId.uuidString, "device_id": response.deviceId.uuidString])
        // No stored account or active transfer is changed until authentication and binding succeed.
        credentialsChanged()
        KeychainStore.delete(MobileContractV02.tokenKey)
        try KeychainStore.save(credentials.username, for: "username")
        try KeychainStore.save(credentials.password, for: "password")
        try KeychainStore.save(response.accountId.uuidString, for: "account_id_v04")
        try KeychainStore.save(response.deviceId.uuidString, for: "device_id_v04")
        try KeychainStore.save(response.bearerToken, for: MobileContractV02.tokenKey)
        MobileContractV02.preferences.set(address, forKey: "server_url")
        serverURL = address; username = credentials.username; password = credentials.password
        stores[newProfile] = targetStore
        library = RemoteLibrary(serverURL: credentials.server, token: response.bearerToken)
        status = "已登录：\(username)"
        if autoBackup { scheduleBackgroundRun() }
    }
    func refreshAlbums() async {
        let authorization = await PhotoScanner().requestAccess()
        guard authorization == .authorized || authorization == .limited else {
            status = "需要重新授权才能扫描本地相册；云端浏览仍可使用"; return
        }
        albums = PhotoScanner().albums()
    }
    func setAlbum(_ id: String, enabled: Bool) {
        if enabled { selectedAlbumIds.insert(id) } else { selectedAlbumIds.remove(id) }
        MobileContractV02.preferences.set(Array(selectedAlbumIds), forKey: "selected_album_ids")
    }
    func refreshTransfers() {
        do { batches = try store().batches() }
        catch { status = error.localizedDescription }
    }
    func changeBatch(_ id: String, retry: Bool) async {
        do {
            try store().client.transfer(["op": retry ? "retry_batch" : "cancel_batch", "batch_id": id])
            refreshTransfers()
            if retry { await runBackup() }
        } catch { status = error.localizedDescription }
    }

    func refreshLibrary(trashed: Bool? = nil) async {
        libraryGeneration += 1
        if let trashed { showingTrash = trashed }
        remoteAssets = []; nextCursor = nil; seenCursors = []
        await loadLibraryPage(first: true)
    }
    func loadLibraryPage(first: Bool = false) async {
        guard first || (!libraryLoading && nextCursor != nil) else { return }
        let generation = libraryGeneration
        let identity = profile
        let cursor = first ? nil : nextCursor
        let trash = showingTrash
        let favorite = favoritesOnly
        let album = selectedRemoteAlbum
        let filters = cloudFilters
        let cacheStore = try? store()
        libraryLoading = true
        defer { if generation == libraryGeneration { libraryLoading = false } }
        do {
            let connection = try await remoteLibrary()
            let page = try await connection.loadTimelinePage(cursor: cursor, trashed: trash, favorite: favorite, albumId: album, filters: filters, store: cacheStore)
            let albums = first ? (try? await connection.albums()) : nil
            guard identity == profile, generation == libraryGeneration else { return }
            if let albums { remoteAlbums = albums }
            if let next = page.nextCursor, !seenCursors.insert(next).inserted { throw RemoteLibraryError.invalidCursor }
            var ids = Set(remoteAssets.map(\.id))
            remoteAssets.append(contentsOf: page.items.filter { ids.insert($0.id).inserted })
            nextCursor = page.nextCursor; library = connection
            status = "\(page.cached ? "离线缓存 · " : "")已加载 \(remoteAssets.count) 项云端媒体"
        } catch { if identity == profile && generation == libraryGeneration { status = error.localizedDescription } }
    }
    func synchronizeGallery() async {
        let identity = profile
        guard let connection = library, let cache = try? store() else { return }
        do {
            if let values = try await connection.json("/v2/devices") as? [[String: Any]], identity == profile {
                remoteDevices = values.compactMap { row in
                    guard let id = row["device_id"] as? String, let name = row["name"] as? String else { return nil }
                    return RemoteDevice(id: id, name: name)
                }
            }
            let changed = try await GallerySynchronizer.shared.synchronize(library: connection, store: cache, profile: identity)
            if changed && identity == profile && !libraryLoading { await refreshLibrary() }
        } catch { if !Task.isCancelled && identity == profile { status = "图库缓存待同步：\(error.localizedDescription)" } }
    }
    func enqueueLocal(_ descriptors: [String]) async {
        do {
            let cache = try store()
            for start in stride(from: 0, to: descriptors.count, by: 1000) {
                let items = descriptors[start..<min(start + 1000, descriptors.count)].map { ["id": UUID().uuidString, "source": $0] }
                try cache.client.transfer(["op": "create_batch", "id": UUID().uuidString, "items": items])
            }
            await runBackup()
        } catch { status = error.localizedDescription }
    }
    func restoreToPhone(_ asset: RemoteAsset) async {
        let id = UUID(); let identity = profile
        do {
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorization == .authorized || authorization == .limited else { throw CoordinatorFailure.message("需要保存到相册的权限") }
            guard identity == profile else { throw CancellationError() }
            let connection = try await remoteLibrary()
            downloads.insert(DownloadTransfer(id: id, name: asset.primary?.filename ?? "媒体", total: Int64(asset.primary?.contentSize ?? 0), bytes: 0, phase: "正在下载"), at: 0)
            let filename = try await connection.restoreToPhotos(asset: asset) { [weak self] bytes in
                Task { @MainActor in
                    guard let self, self.profile == identity, let index = self.downloads.firstIndex(where: { $0.id == id }) else { return }
                    self.downloads[index].bytes = bytes
                }
            }
            if identity == profile {
                status = "已保存到手机：\(filename)"
                if let index = downloads.firstIndex(where: { $0.id == id }) { downloads[index].phase = "已保存到手机" }
            }
        } catch {
            if identity == profile {
                status = "下载失败：\(error.localizedDescription)"
                if let index = downloads.firstIndex(where: { $0.id == id }) { downloads[index].phase = status }
            }
        }
    }
    func toggleFavorite(_ asset: RemoteAsset) async {
        do { try await remoteLibrary().setFavorite(asset: asset, value: !asset.favorite); await refreshLibrary() }
        catch { status = error.localizedDescription }
    }
    func toggleArchived(_ asset: RemoteAsset) async {
        do { try await remoteLibrary().setArchived(asset: asset, value: !asset.archived); await refreshLibrary() }
        catch { status = error.localizedDescription }
    }
    func addTag(_ asset: RemoteAsset) async {
        do { try await remoteLibrary().addTag(named: newTagName, to: asset); await refreshLibrary() }
        catch { status = error.localizedDescription }
    }
    func toggleTrash(_ asset: RemoteAsset) async {
        do {
            let connection = try await remoteLibrary()
            if asset.isTrashed { try await connection.restoreFromTrash(asset: asset) }
            else { try await connection.trash(asset: asset) }
            await refreshLibrary()
        } catch { status = error.localizedDescription }
    }
    func runBackup(automatic: Bool = false, selection: [PHPickerResult] = []) async {
        guard !running else { return }
        running = true
        let identity = profile
        let generation = credentialGeneration
        defer { running = false; if profile == identity { refreshTransfers() } }
        do {
            let store = try store()
            var selectedBatch: String?
            var selectedItems: [(String, PHPickerResult, [String: Any])] = []
            if !selection.isEmpty {
                let batch = UUID().uuidString
                selectedBatch = batch
                selectedItems = selection.map { (UUID().uuidString, $0, SelectedMedia.descriptor($0)) }
                let items = try selectedItems.map { id, _, descriptor -> [String: Any] in
                    let data = try JSONSerialization.data(withJSONObject: descriptor)
                    return ["id": id, "source": String(decoding: data, as: UTF8.self)]
                }
                try store.client.transfer(["op": "create_batch", "id": batch, "items": items])
                refreshTransfers()
            }
            let connection = try await remoteLibrary()
            guard identity == profile, generation == credentialGeneration else { throw CancellationError() }
            try store.client.transfer(["op": "bind", "server": serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "account_id": KeychainStore.load("account_id_v04") ?? "",
                "device_id": KeychainStore.load("device_id_v04") ?? ""])
            let upload = uploader ?? BackgroundUploader(client: store.client, serverURL: connection.serverURL, token: connection.token,
                profile: identity, wifiOnly: wifiOnly)
            uploader = upload
            var processed = 0
            func checkCurrent() throws {
                try Task.checkCancellation()
                guard identity == profile, generation == credentialGeneration else { throw CancellationError() }
            }
            func drain() async throws {
                try checkCurrent()
                while true {
                    let next = try await Task.detached(priority: .utility) {
                        try store.client.next(stagingRoot: store.staging.path)
                    }.value
                    guard let job = next else { break }
                    try checkCurrent()
                    guard processed < 60 else { throw CoordinatorFailure.message("本轮处理完成，等待系统继续调度") }
                    status = "正在上传：\(job.request.filename)"
                    do { try await upload.submit(job) }
                    catch { store.client.markFailed(job: job.jobId, error: error.localizedDescription); throw error }
                    processed += 1
                    refreshTransfers()
                }
            }
            try await drain()
            if let batch = selectedBatch {
                for (item, result, descriptor) in selectedItems where descriptor["kind"] as? String == "picker" {
                    try checkCurrent()
                    do {
                        status = "正在准备选择器交付的导入副本"
                        let imported = try await SelectedMedia.importFile(result, store: store)
                        try store.source(batch: batch, item: item, descriptor: imported)
                        try await SelectedMedia.prepare(imported, store: store, batch: batch, item: item, drain: drain)
                    } catch {
                        try store.setItem(batch: batch, item: item, state: "blocked", error: error.localizedDescription)
                    }
                }
            }
            for batch in try store.batches() where !batch.cancelled {
                for item in batch.items where item["state"] as? String == "pending" {
                    try checkCurrent()
                    let id = item["id"] as! String
                    do {
                        let source = item["source"] as! String
                        let descriptor = try JSONSerialization.jsonObject(with: Data(source.utf8)) as! [String: Any]
                        try await SelectedMedia.prepare(descriptor, store: store, batch: batch.id, item: id, drain: drain)
                    } catch {
                        try store.setItem(batch: batch.id, item: id, state: "blocked", error: error.localizedDescription)
                    }
                }
            }
            if automatic && autoBackup {
                let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                guard access == .authorized || access == .limited else { throw CoordinatorFailure.message("自动扫描需要重新授权访问") }
                let scan = try await PhotoScanner().scan(store: store, selectedAlbumIds: selectedAlbumIds, drain: drain)
                for (id, album) in scan.albums { try await upload.syncAlbum(id: id, name: album.name, assetIds: album.assetIds) }
            }
            try await drain()
            status = "本轮处理结束；逐项结果见传输列表"
            scheduleBackgroundRun()
        } catch is CancellationError {
            status = "传输已中断，批次仍保留"
        } catch {
            if identity == profile { status = "等待处理：\(error.localizedDescription)"; scheduleBackgroundRun() }
        }
    }
    private func scheduleBackgroundRun() {
        let request = BGProcessingTaskRequest(identifier: MobileContractV02.processingTask)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = chargingOnly
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
    func remoteLibrary() async throws -> RemoteLibrary {
        guard let base = URL(string: serverURL), base.scheme == "https", base.host != nil,
            base.user == nil, base.password == nil, base.path.isEmpty || base.path == "/", base.query == nil,
            base.fragment == nil, !username.isEmpty, !password.isEmpty else { throw CoordinatorFailure.message("请先保存有效的 HTTPS 服务器和备份账户") }
        let generation = credentialGeneration
        let user = username, secret = password
        saveSettings()
        var bearer = KeychainStore.load(MobileContractV02.tokenKey)
        if bearer == nil {
            let credentials = try await BackgroundUploader.bootstrap(serverURL: base, username: user, password: secret)
            guard generation == credentialGeneration else { throw CancellationError() }
            bearer = credentials.bearerToken
            try KeychainStore.save(credentials.accountId.uuidString, for: "account_id_v04")
            try KeychainStore.save(credentials.deviceId.uuidString, for: "device_id_v04")
            try KeychainStore.save(bearer!, for: MobileContractV02.tokenKey)
        }
        try store().client.transfer(["op": "bind", "server": serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            "account_id": KeychainStore.load("account_id_v04") ?? "", "device_id": KeychainStore.load("device_id_v04") ?? ""])
        return RemoteLibrary(serverURL: base, token: bearer!)
    }
}

enum CoordinatorFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): value } }
}
