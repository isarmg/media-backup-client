import Foundation
import UIKit
import ImageIO
import CryptoKit

actor RemoteImageCache {
    static let shared = RemoteImageCache()
    private let memory = NSCache<NSString, UIImage>()
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var budget: Int { max(64, min(1024, (UserDefaults.standard.object(forKey: "gallery_cache_mib") as? Int) ?? 256)) * 1024 * 1024 }
    func clear() throws {
        memory.removeAllObjects()
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("remote-images")
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    init() { memory.totalCostLimit = 24 * 1024 * 1024 }
    private func acquire() async {
        if active < 3 { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    private func release() {
        if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
    }
    func image(library: RemoteLibrary, profile: String, resource: RemoteResource, preview: Bool) async throws -> UIImage? {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let key = "\(profile)-\(resource.id)-\(preview)" as NSString
        if let image = memory.object(forKey: key) { return image }
        let limit = preview ? budget : 8 * 1024 * 1024
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("remote-images", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("\(profile)-\(resource.id)-\(preview ? "preview-v1" : "thumbnail")")
        if !FileManager.default.fileExists(atPath: file.path) {
            let downloaded: URL
            let derived = preview ? (try? await library.previewFile(resource)) : nil
            if let derived { downloaded = derived } else {
                try Task.checkCancellation()
                guard resource.contentSize <= limit else { throw CoordinatorFailure.message("原件过大，请使用保存到手机") }
                downloaded = try await library.imageFile(resource, maximum: Int64(limit))
            }
            defer { try? FileManager.default.removeItem(at: downloaded) }
            let size = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= limit else { throw CoordinatorFailure.message("图片超过缓存上限") }
            if !FileManager.default.fileExists(atPath: file.path) { try FileManager.default.moveItem(at: downloaded, to: file) }
        }
        try Task.checkCancellation()
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: preview ? 2048 : 512
            ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: decoded)
        memory.setObject(image, forKey: key, cost: decoded.bytesPerRow * decoded.height)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .map { ($0, try $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])) }
            .sorted { ($0.1.contentModificationDate ?? .distantPast) < ($1.1.contentModificationDate ?? .distantPast) }
        var bytes = files.reduce(0) { $0 + ($1.1.fileSize ?? 0) }
        for (old, values) in files where bytes > budget && old != file {
            try? FileManager.default.removeItem(at: old); bytes -= values.fileSize ?? 0
        }
        return image
    }
}
