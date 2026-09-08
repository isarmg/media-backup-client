import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
import AVFoundation
import ImageIO

struct SelectedMediaPicker: UIViewControllerRepresentable {
    let selected: ([PHPickerResult]) -> Void
    func makeCoordinator() -> Delegate { Delegate(selected: selected) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 1000
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    final class Delegate: NSObject, PHPickerViewControllerDelegate {
        let selected: ([PHPickerResult]) -> Void
        init(selected: @escaping ([PHPickerResult]) -> Void) { self.selected = selected }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) { selected(results) }
    }
}

enum SelectedMedia {
    static func descriptor(_ result: PHPickerResult) -> [String: Any] {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if (authorization == .authorized || authorization == .limited), let id = result.assetIdentifier,
            PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject != nil {
            return ["kind": "photokit", "id": id, "name": result.itemProvider.suggestedName ?? "所选原始资产"]
        }
        return ["kind": "picker", "name": result.itemProvider.suggestedName ?? "媒体",
            "message": "导入副本；选择器交付的文件不代表完整 Live Photo、RAW 配对或编辑资源"]
    }

    static func importFile(_ result: PHPickerResult, store: TransferStore) async throws -> [String: Any] {
        let provider = result.itemProvider
        guard let type = provider.registeredTypeIdentifiers.first(where: {
            guard let value = UTType($0) else { return false }
            return value.conforms(to: .image) || value.conforms(to: .movie)
        }), let contentType = UTType(type) else { throw CoordinatorFailure.message("选择器没有交付可导入的媒体文件") }
        let destination = store.staging.appendingPathComponent("sources/\(UUID().uuidString)")
        let budget = min(Int64(2 * 1024 * 1024 * 1024),
            ((try FileManager.default.attributesOfFileSystem(forPath: store.staging.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0) / 2 - 128 * 1024 * 1024)
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw CoordinatorFailure.message("需要重新选择媒体") }
                    let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                    guard budget > 0, size > 0, size <= budget else { throw CoordinatorFailure.message("暂存空间不足或文件超过 2 GiB 上限") }
                    let input = try FileHandle(forReadingFrom: url)
                    defer { try? input.close() }
                    FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    let output = try FileHandle(forWritingTo: destination)
                    defer { try? output.close() }
                    var hash = SHA256()
                    var copied = 0
                    while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
                        copied += data.count
                        guard copied <= budget else { throw CoordinatorFailure.message("媒体超过暂存预算") }
                        hash.update(data: data)
                        try output.write(contentsOf: data)
                    }
                    try output.synchronize()
                    let identity = "ios-import:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
                    continuation.resume(returning: ["kind": "import", "path": destination.path, "source_id": identity,
                        "name": url.lastPathComponent, "mime": contentType.preferredMIMEType ?? "application/octet-stream",
                        "video": contentType.conforms(to: .movie), "size": copied,
                        "created_ms": Int64(Date().timeIntervalSince1970 * 1000), "import_copy": true])
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func prepare(_ descriptor: [String: Any], store: TransferStore, batch: String, item: String,
        drain: () async throws -> Void) async throws {
        if descriptor["kind"] as? String == "photokit", let id = descriptor["id"] as? String {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                throw CoordinatorFailure.message("需要重新授权访问此资产")
            }
            _ = try await PhotoScanner().enqueue(asset: asset, store: store, batch: batch, item: item, drain: drain)
        } else if descriptor["kind"] as? String == "import", let source = descriptor["source_id"] as? String,
            let path = descriptor["path"] as? String {
            try store.gallery(["op": "declare_resources", "source_id": source, "modified_ms": 0, "originals": 1])
            if try !store.link(batch: batch, item: item, asset: source, resource: source, modified: 0) {
                try store.client.enqueue(EnqueueInput(product: MobileContractV02.product,
                    applicationVersion: MobileContractV02.applicationVersion, revision: MobileContractV02.revision,
                    stateEpoch: MobileContractV02.stateEpoch, sourceAssetId: source, sourceResourceId: source,
                    mediaKind: descriptor["video"] as? Bool == true ? "video" : "photo", role: "primary", filePath: path,
                    filename: descriptor["name"] as? String ?? "media", mimeType: descriptor["mime"] as? String ?? "application/octet-stream",
                    sourceCreatedAtMs: (descriptor["created_ms"] as? NSNumber)?.int64Value ?? 0, modifiedMs: 0,
                    sourceSize: (descriptor["size"] as? NSNumber)?.uint64Value ?? 0,
                    metadataJson: "{\"import_copy\":true}", removeSourceAfterPrepare: true, batchId: batch, batchItemId: item))
            }
            let thumbnailId = source + "#thumbnail-v1"
            let needsThumbnail = try !store.link(batch: batch, item: item, asset: source, resource: thumbnailId, modified: 0)
            let thumbnailData = needsThumbnail ? (try await thumbnail(path: path, video: descriptor["video"] as? Bool == true)) : nil
            if let thumbnail = thumbnailData {
                let output = store.staging.appendingPathComponent("sources/\(UUID().uuidString).thumbnail.jpg")
                try thumbnail.write(to: output, options: .atomic)
                try store.client.enqueue(EnqueueInput(product: MobileContractV02.product,
                    applicationVersion: MobileContractV02.applicationVersion, revision: MobileContractV02.revision,
                    stateEpoch: MobileContractV02.stateEpoch, sourceAssetId: source, sourceResourceId: thumbnailId,
                    mediaKind: descriptor["video"] as? Bool == true ? "video" : "photo", role: "thumbnail", filePath: output.path,
                    filename: "thumbnail.jpg", mimeType: "image/jpeg",
                    sourceCreatedAtMs: (descriptor["created_ms"] as? NSNumber)?.int64Value ?? 0, modifiedMs: 0,
                    sourceSize: UInt64(thumbnail.count), metadataJson: nil, removeSourceAfterPrepare: true,
                    batchId: batch, batchItemId: item))
            }
            try await drain()
            let rows = try store.client.transfer(["op": "items", "batch_id": batch]) as? [[String: Any]] ?? []
            if let row = rows.first(where: { $0["id"] as? String == item }),
                let total = row["resources"] as? Int, total > 0, row["complete"] as? Int == total {
                let file = URL(fileURLWithPath: path)
                if file.deletingLastPathComponent().standardizedFileURL == store.staging.appendingPathComponent("sources").standardizedFileURL {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        } else {
            throw CoordinatorFailure.message("选择器文件尚未导入，请重新选择；该项目未宣称备份成功")
        }
        try store.setItem(batch: batch, item: item, state: "queued")
    }
    private static func thumbnail(path: String, video: Bool) async throws -> Data? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let image: CGImage?
        if video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            image = try await generator.image(at: .zero).image
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary)
        } else { image = nil }
        return image.flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.82) }
    }

}
