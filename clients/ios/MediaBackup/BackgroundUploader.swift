import Foundation
import UIKit

private struct CreateUploadResponse: Decodable {
    let disposition: String
    let uploadId: String?
    let resourceId: String?
    let missingParts: [UInt32]
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
        let configuration = URLSessionConfiguration.background(withIdentifier: MobileContractV02.uploadSession + "." + profile)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = !wifiOnly
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func submit(_ job: PreparedJob) async throws {
        var request = authorized(path: "/v2/uploads", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(job.request)
        let (data, response) = try await SecureSession.shared.data(for: request)
        try requireSuccess(response, data: data)
        let created = try decoder.decode(CreateUploadResponse.self, from: data)
        if created.disposition == "complete" {
            guard let resource = created.resourceId else { throw UploadFailure.invalidResponse }
            let (manifest, response) = try await SecureSession.shared.data(for: authorized(path: "/v2/resources/\(resource)", method: "GET"))
            try requireSuccess(response, data: manifest)
            try saveReceipt(jobId: job.jobId, data: manifest, hash: job.request.contentBlake3)
            return
        }
        guard let uploadId = created.uploadId else { throw UploadFailure.invalidResponse }
        try client.markUpload(job: job.jobId, upload: uploadId)
        let localParts = Dictionary(uniqueKeysWithValues: job.localParts.map { ($0.index, $0.path) })
        if created.missingParts.isEmpty {
            try await finish(jobId: job.jobId, uploadId: uploadId, hash: job.request.contentBlake3)
            return
        }
        for index in created.missingParts {
            guard let path = localParts[index] else { throw UploadFailure.missingPart(index) }
            var partRequest = authorized(path: "/v2/uploads/\(uploadId)/parts/\(index)", method: "PUT")
            partRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let task = session.uploadTask(with: partRequest, fromFile: URL(fileURLWithPath: path))
            task.taskDescription = "\(job.jobId)|\(uploadId)|\(index)"
            try Task.checkCancellation()
            guard try client.transfer(["op": "active", "job_id": job.jobId]) as? Bool == true else {
                throw CoordinatorFailure.message("本次上传已取消")
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock(); completions[task.taskIdentifier] = continuation; lock.unlock()
                task.resume()
            }
            try client.markPart(job: job.jobId, index: index)
        }
        try await finish(jobId: job.jobId, uploadId: uploadId, hash: job.request.contentBlake3)
    }

    func syncAlbum(id: String, name: String, assetIds: Set<String>) async throws {
        var request = authorized(path: "/v2/albums", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "source_album_id": id,
            "name": name,
            "source_asset_ids": Array(assetIds),
            "replace_members": false,
        ])
        let (data, response) = try await SecureSession.shared.data(for: request)
        try requireSuccess(response, data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let completion = completions.removeValue(forKey: task.taskIdentifier); lock.unlock()
        if let error { completion?.resume(throwing: error); return }
        guard let response = task.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            completion?.resume(throwing: UploadFailure.invalidResponse); return
        }
        completion?.resume()
        // After process termination, durable Rust work is recovered by querying server missing parts.
    }

    private func finish(jobId: String, uploadId: String, hash: String) async throws {
        var request = authorized(path: "/v2/uploads/\(uploadId)/complete", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await SecureSession.shared.data(for: request)
        try requireSuccess(response, data: data)
        try saveReceipt(jobId: jobId, data: data, hash: hash)
    }

    private func saveReceipt(jobId: String, data: Data, hash: String) throws {
        guard let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let asset = receipt["asset_id"] as? String, let resource = receipt["resource_id"] as? String else {
            throw UploadFailure.invalidResponse
        }
        try client.transfer(["op": "receipt", "job_id": jobId, "asset_id": asset,
            "resource_id": resource, "content_blake3": hash])
        try client.markComplete(job: jobId)
    }

    private func authorized(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: serverURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func requireSuccess(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UploadFailure.server(String(decoding: data, as: UTF8.self))
        }
    }

    static func bootstrap(serverURL: URL, username: String, password: String) async throws -> BootstrapResponse {
        let deviceName = await MainActor.run { UIDevice.current.name }
        var request = URLRequest(url: serverURL.appending(path: "/v2/auth/bootstrap"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
            "device_name": deviceName,
            "platform": "ios",
        ])
        let (data, response) = try await SecureSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UploadFailure.server(String(decoding: data, as: UTF8.self))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(BootstrapResponse.self, from: data)
    }
}

enum UploadFailure: Error {
    case invalidResponse
    case missingPart(UInt32)
    case server(String)
}
