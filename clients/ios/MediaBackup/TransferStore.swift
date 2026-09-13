import Foundation
import CryptoKit

func provisionalProfileKey(server: String, authorizationCode: String) -> String {
    let normalized = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return SHA256.hash(data: Data("media-backup-unpaired-v1\n\(normalized)\n\(authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines))".utf8))
        .map { String(format: "%02x", $0) }.joined()
}

func instanceProfileKey(server: String, deviceId: UUID) -> String {
    let normalized = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return SHA256.hash(data: Data("media-backup-instance-v1\n\(normalized)\n\(deviceId.uuidString.lowercased())".utf8))
        .map { String(format: "%02x", $0) }.joined()
}

struct TransferBatch: Identifiable {
    let id: String
    let count: Int
    let complete: Int
    let cancelled: Bool
    let items: [[String: Any]]
}

final class TransferStore: @unchecked Sendable {
    static func bindAccount(server: String, authorizationCode: String, accountId: UUID, deviceId: UUID,
                            open: (String) throws -> TransferStore = { try TransferStore(profile: $0) }) throws -> (profile: String, store: TransferStore) {
        guard !authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientFailure.message("实例授权码不能为空")
        }
        let profile = instanceProfileKey(server: server, deviceId: deviceId)
        let target = try open(profile)
        let binding: [String: Any]?
        do { binding = try target.client.transfer(["op": "binding"]) as? [String: Any] }
        catch { throw ClientFailure.message("读取本地账户绑定失败：\(error.localizedDescription)") }
        let matches = binding == nil || ((binding?["server"] as? String) == server &&
            (binding?["account_id"] as? String).flatMap(UUID.init(uuidString:)) == accountId &&
            (binding?["device_id"] as? String).flatMap(UUID.init(uuidString:)) == deviceId)
        guard matches else { throw ClientFailure.message("服务器实例身份已改变；旧备份队列已保留") }
        do {
            try target.client.transfer(["op": "bind", "server": server,
                "account_id": accountId.uuidString, "device_id": deviceId.uuidString])
        } catch { throw ClientFailure.message("服务器认证成功，但本地绑定失败：\(error.localizedDescription)") }
        return (profile, target)
    }

    let client: RustClient
    let staging: URL
    init(profile: String) throws {
        let systemSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let support = try BackupDirectory.canonicalSystemDirectory(systemSupport)
            .appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        do { client = try RustClient(databasePath: support.appendingPathComponent(MobileContractV02.databaseFilename).path) }
        catch { throw ClientFailure.message("打开手机备份数据库失败：\(error.localizedDescription)") }
        staging = support.appendingPathComponent(MobileContractV02.stagingDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("sources"), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
    @discardableResult
    func gallery(_ command: [String: Any]) throws -> Any {
        try client.transfer(["op": "gallery", "command": command])
    }
    func batches() throws -> [TransferBatch] {
        let rows = try client.transfer(["op": "batches"]) as? [[String: Any]] ?? []
        return try rows.map { row in
            let id = row["id"] as! String
            let items = try client.transfer(["op": "items", "batch_id": id]) as? [[String: Any]] ?? []
            return TransferBatch(id: id, count: (row["items"] as? Int) ?? 0, complete: (row["complete"] as? Int) ?? 0,
                cancelled: (row["cancelled"] as? Bool) ?? false, items: items)
        }
    }
    func setItem(batch: String, item: String, state: String, error: String? = nil) throws {
        try client.transfer(["op": "set_item", "batch_id": batch, "item_id": item,
            "state": state, "error": error as Any? ?? NSNull()])
    }
    func link(batch: String?, item: String?, asset: String, resource: String, modified: Int64) throws -> Bool {
        guard let batch, let item else { return !(try client.needs(asset: asset, resource: resource, modifiedMs: modified)) }
        return (try client.transfer(["op": "link_resource", "batch_id": batch, "item_id": item,
            "asset": asset, "resource": resource, "modified_ms": modified]) as? Bool) ?? false
    }
    func source(batch: String, item: String, descriptor: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: descriptor)
        try client.transfer(["op": "set_source", "batch_id": batch, "item_id": item, "source": String(decoding: data, as: UTF8.self)])
    }
}
