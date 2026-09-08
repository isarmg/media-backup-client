import Foundation
import Photos

enum StorageEncoding: String, Codable {
    case plainV1 = "plain-v1"
}

struct RemoteResource: Decodable, Identifiable {
    let resourceId: UUID
    let role: String
    let filename: String
    let mimeType: String
    let contentSize: UInt64
    let storageEncoding: StorageEncoding
    let contentPath: String
    let metadata: JSONValue?

    var id: UUID { resourceId }
}

struct RemoteAsset: Decodable, Identifiable {
    let assetId: UUID
    let sourceAssetId: String
    let mediaKind: String
    let sourceCreatedAtMs: Int64
    let favorite: Bool
    let archived: Bool
    let trashedAtMs: Int64?
    let tagNames: [String]
    let resources: [RemoteResource]

    var id: UUID { assetId }
    var isTrashed: Bool { trashedAtMs != nil }
    var primary: RemoteResource? {
        resources.first(where: { $0.role == "primary" })
            ?? resources.first(where: { $0.role != "thumbnail" })
    }
    var thumbnail: RemoteResource? { resources.first(where: { $0.role == "thumbnail" }) }
}

struct TimelinePage: Decodable {
    let items: [RemoteAsset]
    let nextCursor: String?
    var cached = false
    enum CodingKeys: String, CodingKey { case items, nextCursor }
}

struct RemoteLibrary {
    let serverURL: URL
    let token: String

    private let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.keyDecodingStrategy = .convertFromSnakeCase
        return value
    }()

    func loadTimelinePage(cursor: String? = nil, trashed: Bool = false, favorite: Bool = false, albumId: UUID? = nil, filters: CloudFilters = CloudFilters(), store: TransferStore? = nil) async throws -> TimelinePage {
        var components = URLComponents(url: serverURL.appending(path: "/v2/timeline"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "trashed", value: trashed ? "true" : "false"),
            URLQueryItem(name: "limit", value: "100"), cursor.map { URLQueryItem(name: "cursor", value: $0) },
            favorite ? URLQueryItem(name: "favorite", value: "true") : nil,
            albumId.map { URLQueryItem(name: "album_id", value: $0.uuidString) }].compactMap { $0 }
        components?.queryItems?.append(contentsOf: filters.queryItems)
        let key = components?.queryItems?.filter { $0.name != "cursor" }.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&") ?? ""
        guard let url = components?.url else { throw RemoteLibraryError.invalidURL }
        do {
            let (data, response) = try await SecureSession.shared.data(for: authorized(url: url, method: "GET"))
            try requireSuccess(response, data: data)
            let raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let page = try decoder.decode(TimelinePage.self, from: data)
            guard page.nextCursor == nil || page.nextCursor != cursor else { throw RemoteLibraryError.invalidCursor }
            try store?.gallery(["op": "save_page", "query_key": key, "cursor": cursor as Any? ?? NSNull(),
                "items": raw["items"]!, "next_cursor": raw["next_cursor"] ?? NSNull()])
            return page
        } catch {
            try Task.checkCancellation()
            guard let raw = try store?.gallery(["op": "read_page", "query_key": key, "cursor": cursor as Any? ?? NSNull()]) as? [String: Any] else { throw error }
            var page = try decoder.decode(TimelinePage.self, from: JSONSerialization.data(withJSONObject: raw))
            page.cached = true
            return page
        }
    }

    func json(_ path: String, allowMissing: Bool = false) async throws -> Any? {
        let (data, response) = try await SecureSession.shared.data(for: authorized(url: SecureSession.resolve(path, base: serverURL), method: "GET"))
        if allowMissing, (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try requireSuccess(response, data: data)
        return try JSONSerialization.jsonObject(with: data)
    }
    func previewFile(_ resource: RemoteResource) async throws -> URL {
        let request = try authorized(url: SecureSession.resolve("/v2/resources/\(resource.id)/preview", base: serverURL), method: "GET")
        return try await BoundedDownload.fetch(request, maximum: 8 * 1024 * 1024)
    }

    func albums() async throws -> [RemoteAlbum] {
        let (data, response) = try await SecureSession.shared.data(for: authorized(url: serverURL.appending(path: "/v2/albums"), method: "GET"))
        try requireSuccess(response, data: data)
        return try decoder.decode([RemoteAlbum].self, from: data)
    }

    func imageFile(_ resource: RemoteResource, maximum: Int64) async throws -> URL {
        let request = try authorized(url: SecureSession.resolve(resource.contentPath, base: serverURL), method: "GET")
        return try await BoundedDownload.fetch(request, maximum: maximum)
    }

    func setFavorite(asset: RemoteAsset, value: Bool) async throws {
        try await sendJSON(path: "/v2/assets/\(asset.assetId)", method: "PATCH", body: ["favorite": value])
    }

    func setArchived(asset: RemoteAsset, value: Bool) async throws {
        try await sendJSON(path: "/v2/assets/\(asset.assetId)", method: "PATCH", body: ["archived": value])
    }

    func addTag(named rawName: String, to asset: RemoteAsset) async throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let (listData, listResponse) = try await SecureSession.shared.data(for: authorized(
            url: serverURL.appending(path: "/v2/tags"),
            method: "GET"
        ))
        try requireSuccess(listResponse, data: listData)
        let tags = try decoder.decode([RemoteTag].self, from: listData)
        let tag: RemoteTag
        if let existing = tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            tag = existing
        } else {
            var request = try authorized(url: serverURL.appending(path: "/v2/tags"), method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
            let (data, response) = try await SecureSession.shared.data(for: request)
            try requireSuccess(response, data: data)
            tag = try decoder.decode(RemoteTag.self, from: data)
        }
        try await send(path: "/v2/tags/\(tag.tagId)/assets/\(asset.assetId)", method: "POST")
    }

    func duplicateGroupCount() async throws -> Int {
        let (data, response) = try await SecureSession.shared.data(for: authorized(
            url: serverURL.appending(path: "/v2/duplicates"),
            method: "GET"
        ))
        try requireSuccess(response, data: data)
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []).count
    }

    func thumbnailData(for asset: RemoteAsset) async throws -> Data? {
        guard let thumbnail = asset.thumbnail else { return nil }
        let (data, response) = try await SecureSession.shared.data(for: authorized(
            url: SecureSession.resolve(thumbnail.contentPath, base: serverURL),
            method: "GET"
        ))
        try requireSuccess(response, data: data)
        return data
    }

    func trash(asset: RemoteAsset) async throws {
        try await send(path: "/v2/assets/\(asset.assetId)/trash", method: "POST")
    }

    func restoreFromTrash(asset: RemoteAsset) async throws {
        try await send(path: "/v2/assets/\(asset.assetId)/restore", method: "POST")
    }

    func restoreToPhotos(asset: RemoteAsset, progress: ((Int64) -> Void)? = nil) async throws -> String {
        guard let resource = asset.primary else { throw RemoteLibraryError.noPrimaryResource }
        let suffix = URL(fileURLWithPath: resource.filename).pathExtension
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(suffix.isEmpty ? "bin" : suffix)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let downloaded = try await BoundedDownload.fetch(authorized(
            url: SecureSession.resolve(resource.contentPath, base: serverURL), method: "GET"),
            maximum: Int64(resource.contentSize), progress: progress)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let actual = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard UInt64(actual) == resource.contentSize else { throw CoordinatorFailure.message("原件下载长度不匹配") }
        try FileManager.default.moveItem(at: downloaded, to: temporary)
        try await PHPhotoLibrary.shared().performChanges {
            if resource.mimeType.hasPrefix("video/") {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: temporary)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: temporary)
            }
        }
        return resource.filename
    }

    private func send(path: String, method: String) async throws {
        var request = try authorized(url: serverURL.appending(path: path), method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await SecureSession.shared.data(for: request)
        try requireSuccess(response, data: data)
    }

    private func sendJSON(path: String, method: String, body: [String: Any]) async throws {
        var request = try authorized(url: serverURL.appending(path: path), method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await SecureSession.shared.data(for: request)
        try requireSuccess(response, data: data)
    }

    private func authorized(url: URL, method: String) throws -> URLRequest {
        _ = try SecureSession.resolve(url.absoluteString, base: serverURL)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func requireSuccess(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteLibraryError.server(String(decoding: data, as: UTF8.self))
        }
    }
}

private struct RemoteTag: Decodable {
    let tagId: UUID
    let name: String
}

enum RemoteLibraryError: LocalizedError {
    case invalidURL
    case noPrimaryResource
    case invalidCursor
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "服务器地址无效"
        case .noPrimaryResource: "该资产没有可恢复的原始资源"
        case .invalidCursor: "服务器返回了无效的分页游标"
        case .server(let message): message.isEmpty ? "服务器请求失败" : message
        }
    }
}

struct RemoteAlbum: Decodable, Identifiable {
    let albumId: UUID
    let name: String
    var id: UUID { albumId }
}
