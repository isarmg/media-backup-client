import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

/// Render the selected media preview, never the provider's opaque suggested name.
struct PickerSelectionThumbnail: View {
    let result: PHPickerResult
    let index: Int
    @State private var image: UIImage?
    @State private var loaded = false
    private var video: Bool { result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }

    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    Group {
                        if let image { Image(uiImage: image).resizable().scaledToFill() }
                        else if !loaded { ProgressView() }
                        else {
                            VStack(spacing: 6) {
                                Image(systemName: video ? "video" : "photo")
                                Text("预览暂不可用").font(.caption)
                            }.foregroundStyle(.secondary)
                        }
                    }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
                    .padding(7).background(Color.accentColor, in: Circle()).padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                if video { Image(systemName: "video.fill").foregroundStyle(.white).padding(6)
                    .background(.black.opacity(0.45), in: Capsule()).padding(6) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("所选\(video ? "视频" : "照片")，第 \(index + 1) 项")
            .accessibilityIdentifier("selection.preview.\(index)")
            .accessibilityValue(image != nil ? "已加载缩略图" : (loaded ? "预览暂不可用" : "正在加载缩略图"))
            .task(id: ObjectIdentifier(result.itemProvider)) {
                image = nil; loaded = false
                let value = await PickerPreview.load(result)
                guard !Task.isCancelled else { return }
                image = value
                loaded = true
            }
    }
}

enum PickerPreview {
    static func load(_ result: PHPickerResult) async -> UIImage? {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if (access == .authorized || access == .limited), let id = result.assetIdentifier,
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
           let image = await photoLibraryImage(asset) { return image }
        guard !Task.isCancelled else { return nil }
        return await loadProvider(result.itemProvider)
    }

    private static func photoLibraryImage(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 320, height: 320),
                contentMode: .aspectFit, options: options) { value, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                continuation.resume(returning: value)
            }
        }
    }

    static func loadProvider(_ provider: NSItemProvider) async -> UIImage? {
        // PHPicker grants access to its file representation independently of
        // PhotoKit library permission. A suggested name or absent preview is not
        // evidence that the selected image itself cannot be read.
        let types = provider.registeredTypeIdentifiers.filter { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie)
        }
        for type in types {
            guard !Task.isCancelled else { return nil }
            if let image = await fileImage(provider, type: type) { return image }
        }
        guard !Task.isCancelled else { return nil }
        let preview = try? await provider.loadPreviewImage(options: [
            NSItemProviderPreferredImageSizeKey: NSValue(cgSize: CGSize(width: 320, height: 320))
        ])
        if let image = preview.flatMap(image) { return image }
        guard !Task.isCancelled, provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: (object as? UIImage).flatMap { image($0) })
            }
        }
    }

    private static func fileImage(_ provider: NSItemProvider, type: String) async -> UIImage? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                // Provider URLs expire when this callback returns. Decode here;
                // never retain the URL for a later asynchronous task.
                guard let url, url.isFileURL else { continuation.resume(returning: nil); return }
                if UTType(type)?.conforms(to: .movie) == true {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 320, height: 320)
                    let frame = try? generator.copyCGImage(at: .zero, actualTime: nil)
                    continuation.resume(returning: frame.map { UIImage(cgImage: $0) })
                } else {
                    continuation.resume(returning: image(url as NSURL))
                }
            }
        }
    }

    static func image(_ preview: any NSSecureCoding) -> UIImage? {
        if let image = preview as? UIImage {
            let dimension = max(image.size.width, image.size.height)
            guard dimension > 320 else { return image }
            let ratio = 320 / dimension
            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        let source: CGImageSource?
        if let data = preview as? Data, data.count <= 12 * 1024 * 1024 {
            source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else if let url = preview as? URL, url.isFileURL {
            source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else { return nil }
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320
        ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
