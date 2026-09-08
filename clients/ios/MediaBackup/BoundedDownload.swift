import Foundation

/// Browser downloads have a byte budget during transfer, including unknown-length responses.
final class BoundedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let maximum: Int64
    private let progress: ((Int64) -> Void)?
    private var reported: Int64 = 0
    private let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var file: FileHandle?
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var finished = false
    private var cancelled = false
    private var count: Int64 = 0
    private var expected: Int64 = -1
    init(maximum: Int64, progress: ((Int64) -> Void)?) { self.maximum = maximum; self.progress = progress }
    static func fetch(_ request: URLRequest, maximum: Int64, progress: ((Int64) -> Void)? = nil) async throws -> URL {
        let download = BoundedDownload(maximum: maximum, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in download.start(request, continuation: continuation) }
        } onCancel: { download.cancel() }
    }
    private func start(_ request: URLRequest, continuation: CheckedContinuation<URL, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
        if cancelled { finish(CancellationError()); return }
        do {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CoordinatorFailure.message("无法创建浏览缓存")
            }
            file = try FileHandle(forWritingTo: destination)
            let configuration = URLSessionConfiguration.ephemeral; configuration.urlCache = nil
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session; session.dataTask(with: request).resume()
        } catch { finish(error) }
    }
    private func cancel() {
        lock.lock(); defer { lock.unlock() }; cancelled = true
        if continuation != nil { finish(CancellationError()) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, let http = response as? HTTPURLResponse, http.statusCode == 200,
            response.expectedContentLength <= maximum else {
            completionHandler(.cancel); finish(CoordinatorFailure.message("图片请求失败或超过缓存预算")); return
        }
        expected = response.expectedContentLength; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }; guard !finished else { return }
        do {
            count += Int64(data.count)
            guard count <= maximum else { throw CoordinatorFailure.message("图片超过缓存预算") }
            try file?.write(contentsOf: data)
            if count - reported >= 256 * 1024 { progress?(count); reported = count }
        } catch { finish(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); defer { lock.unlock() }
        finish(error ?? (expected >= 0 && expected != count ? CoordinatorFailure.message("图片下载不完整") : nil))
    }
    private func finish(_ error: Error?) {
        guard !finished else { return }; finished = true
        var failure = error
        do { try file?.close() } catch { failure = failure ?? error }; file = nil
        session?.invalidateAndCancel(); session = nil
        if let failure { try? FileManager.default.removeItem(at: destination); continuation?.resume(throwing: failure) }
        else { progress?(count); continuation?.resume(returning: destination) }
        continuation = nil
    }
}
