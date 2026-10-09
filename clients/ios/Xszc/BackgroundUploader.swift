import Foundation
import UIKit

private struct CreateUploadResponse: Decodable {
    let disposition: String
    let uploadId: String?
    let resourceId: String?
    let missingParts: [UInt32]
}

private struct UploadReceiptManifest: Decodable {
    let resourceId: UUID
    let assetId: UUID
    let sourceAssetId: String
    let sourceResourceId: String
    let contentSize: UInt64
    let contentBlake3: String
    let storageEncoding: StorageEncoding
}

struct BootstrapResponse: Decodable {
    let bearerToken: String
    let accountId: UUID
    let deviceId: UUID
}

final class BackgroundUploader: NSObject, URLSessionTaskDelegate {
    private let client: RustClient
    private let serverURL: URL
    private let token: String
    private var session: URLSession!
    private let lock = NSLock()
    private var completions: [Int: CheckedContinuation<Void, Error>] = [:]
    private var progressHandlers: [Int: (Int64) -> Void] = [:]
    private var lastProgressUpdates: [Int: TimeInterval] = [:]

    func cancel() { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    private let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.keyDecodingStrategy = .convertFromSnakeCase
        return value
    }()
    private let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.keyEncodingStrategy = .convertToSnakeCase
        return value
    }()

    init(client: RustClient, serverURL: URL, token: String, profile: String, wifiOnly: Bool) {
        self.client = client
        self.serverURL = serverURL
        self.token = token
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: MobileContractV1.uploadSession + "." + profile)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = !wifiOnly
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func submit(_ job: PreparedJob, transferredBytes: @escaping (Int64) -> Void = { _ in },
        progress: @escaping (Double) -> Void = { _ in }) async throws {
        progress(0)
        try ensureActive(jobId: job.jobId)
        var request = authorized(path: "/v1/uploads", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(job.request)
        let (data, response) = try await SecureSession.shared.data(for: request)
        try requireSuccess(response)
        let created = try decoder.decode(CreateUploadResponse.self, from: data)
        try ensureActive(jobId: job.jobId)
        if created.disposition == "complete" {
            guard let resource = created.resourceId else { throw UploadFailure.invalidResponse }
            let (manifest, response) = try await SecureSession.shared.data(for: authorized(path: "/v1/resources/\(resource)", method: "GET"))
            try requireSuccess(response)
            try saveReceipt(job: job, data: manifest, expectedResourceId: resource)
            progress(1)
            return
        }
        guard created.disposition == "upload" else { throw UploadFailure.invalidResponse }
        guard let uploadId = created.uploadId else { throw UploadFailure.invalidResponse }
        try client.markUpload(job: job.jobId, upload: uploadId)
        let localParts = Dictionary(uniqueKeysWithValues: job.localParts.map { ($0.index, $0.path) })
        if created.missingParts.isEmpty {
            try await finish(job: job, uploadId: uploadId)
            progress(1)
            return
        }
        let missing = Set(created.missingParts)
        var confirmedBytes = job.request.parts.filter { !missing.contains($0.index) }.reduce(0.0) { $0 + Double($1.size) }
        let total = max(1, Double(job.request.contentSize))
        progress(min(0.99, confirmedBytes / total))
        for index in created.missingParts {
            guard let path = localParts[index] else { throw UploadFailure.missingPart(index) }
            try ensureActive(jobId: job.jobId)
            var partRequest = authorized(path: "/v1/uploads/\(uploadId)/parts/\(index)", method: "PUT")
            partRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let task = session.uploadTask(with: partRequest, fromFile: URL(fileURLWithPath: path))
            task.taskDescription = "\(job.jobId)|\(uploadId)|\(index)"
            let baseline = confirmedBytes
            var lastSent: Int64 = 0
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                completions[task.taskIdentifier] = continuation
                progressHandlers[task.taskIdentifier] = { sent in
                    let current = max(0, sent)
                    let delta = current >= lastSent ? current - lastSent : current
                    lastSent = current
                    transferredBytes(delta)
                    progress(min(0.99, (baseline + Double(current)) / total))
                }
                lock.unlock()
                task.resume()
            }
            try client.markPart(job: job.jobId, index: index)
            confirmedBytes += Double(job.request.parts.first(where: { $0.index == index })?.size ?? 0)
        }
        try await finish(job: job, uploadId: uploadId)
        progress(1)
    }

    private func ensureActive(jobId: String) throws {
        try Task.checkCancellation()
        guard try client.transfer(["op": "active", "job_id": jobId]) as? Bool == true else {
            throw CoordinatorFailure.message("本次上传已取消")
        }
    }

    func syncAlbum(id: String, name: String, assetIds: Set<String>, replaceMembers: Bool) async throws {
        let ordered = assetIds.sorted()
        var start = 0
        repeat {
            let end = min(start + 10_000, ordered.count)
            var request = authorized(path: "/v1/albums", method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "source_album_id": id,
                "name": name,
                "source_asset_ids": Array(ordered[start..<end]),
                "replace_members": replaceMembers && start == 0,
            ])
            let (_, response) = try await SecureSession.shared.data(for: request)
            try requireSuccess(response)
            start = end
        } while start < ordered.count
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let completion = completions.removeValue(forKey: task.taskIdentifier)
        progressHandlers.removeValue(forKey: task.taskIdentifier)
        lastProgressUpdates.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let error { completion?.resume(throwing: error); return }
        guard let response = task.response as? HTTPURLResponse else {
            completion?.resume(throwing: UploadFailure.invalidResponse); return
        }
        guard (200..<300).contains(response.statusCode) else {
            completion?.resume(throwing: UploadFailure.server(response.statusCode)); return
        }
        completion?.resume()
        // After process termination, durable Rust work is recovered by querying server missing parts.
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let shouldUpdate = now - (lastProgressUpdates[task.taskIdentifier] ?? 0) >= 0.1 ||
            (totalBytesExpectedToSend > 0 && totalBytesSent >= totalBytesExpectedToSend)
        let handler = shouldUpdate ? progressHandlers[task.taskIdentifier] : nil
        if handler != nil { lastProgressUpdates[task.taskIdentifier] = now }
        lock.unlock()
        handler?(totalBytesSent)
    }

    private func finish(job: PreparedJob, uploadId: String) async throws {
        try ensureActive(jobId: job.jobId)
        var request = authorized(path: "/v1/uploads/\(uploadId)/complete", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await SecureSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 409,
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            body["code"] as? String == "upload_superseded" {
            throw UploadFailure.superseded
        }
        try requireSuccess(response)
        guard let completed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let resource = completed["resource_id"] as? String,
            let asset = completed["asset_id"] as? String else { throw UploadFailure.invalidResponse }
        let (manifest, manifestResponse) = try await SecureSession.shared.data(for: authorized(
            path: "/v1/resources/\(resource)", method: "GET"))
        try requireSuccess(manifestResponse)
        try saveReceipt(job: job, data: manifest, expectedResourceId: resource, expectedAssetId: asset)
    }

    private func saveReceipt(job: PreparedJob, data: Data, expectedResourceId: String,
        expectedAssetId: String? = nil) throws {
        let receipt = try decoder.decode(UploadReceiptManifest.self, from: data)
        let matchesAsset = expectedAssetId.map { UUID(uuidString: $0) == receipt.assetId } ?? true
        guard receipt.resourceId == UUID(uuidString: expectedResourceId),
            matchesAsset,
            receipt.sourceAssetId == job.request.sourceAssetId,
            receipt.sourceResourceId == job.request.sourceResourceId,
            receipt.contentSize == job.request.contentSize,
            receipt.contentBlake3 == job.request.contentBlake3,
            receipt.storageEncoding == job.request.storageEncoding else {
            throw UploadFailure.invalidResponse
        }
        try ensureActive(jobId: job.jobId)
        try client.transfer(["op": "receipt", "job_id": job.jobId, "asset_id": receipt.assetId.uuidString,
            "resource_id": receipt.resourceId.uuidString, "content_blake3": job.request.contentBlake3])
        try client.markComplete(job: job.jobId)
    }

    private func authorized(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: serverURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw UploadFailure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw UploadFailure.server(http.statusCode) }
    }

    static func validateSession(serverURL: URL, token: String) async throws {
        var request = URLRequest(url: serverURL.appending(path: "/v1/sync/head"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await SecureSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UploadFailure.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw CoordinatorFailure.message("本机配对凭据已失效，请在服务器实例详情更换授权码后使用新授权码重新配对")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CoordinatorFailure.message("验证配对状态失败（HTTP \(http.statusCode)），请稍后重试")
        }
    }

    static func bootstrap(serverURL: URL, authorizationCode: String) async throws -> BootstrapResponse {
        let deviceName = await MainActor.run { UIDevice.current.name }
        var request = URLRequest(url: serverURL.appending(path: "/v1/auth/bootstrap"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "authorization_code": authorizationCode,
            "device_name": deviceName,
            "platform": "ios",
        ])
        let (data, response) = try await SecureSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UploadFailure.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw CoordinatorFailure.message("实例授权码无效，或该实例已经配对。如需重新配对，请在服务器实例详情更换授权码后使用新授权码")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CoordinatorFailure.message("配对失败（HTTP \(http.statusCode)），请稍后重试")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(BootstrapResponse.self, from: data)
    }
}

enum UploadFailure: LocalizedError {
    case invalidResponse
    case missingPart(UInt32)
    case server(Int)
    case superseded

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "服务器返回无效响应"
        case .missingPart(let index): "服务器要求的分块不存在（编号 \(index)）"
        case .server(let status): "服务器请求失败（HTTP \(status)）"
        case .superseded: "旧上传已被较新版本取代"
        }
    }
}
