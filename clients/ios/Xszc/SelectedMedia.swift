import Foundation
import Photos
import UIKit
import AVFoundation
import ImageIO

enum SelectedMedia {
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
                try store.client.enqueue(EnqueueInput(product: MobileContractV1.product,
                    applicationVersion: MobileContractV1.applicationVersion, revision: MobileContractV1.revision,
                    stateEpoch: MobileContractV1.stateEpoch, sourceAssetId: source, sourceResourceId: source,
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
                try store.client.enqueue(EnqueueInput(product: MobileContractV1.product,
                    applicationVersion: MobileContractV1.applicationVersion, revision: MobileContractV1.revision,
                    stateEpoch: MobileContractV1.stateEpoch, sourceAssetId: source, sourceResourceId: thumbnailId,
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
