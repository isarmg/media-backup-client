import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

/// Render the selected media preview, never the provider's opaque suggested name.
struct PickerSelectionThumbnail: View {
    let result: PHPickerResult
    let index: Int
    @State private var image: UIImage?
    @State private var photoId: String?
    @State private var loaded = false
    private var video: Bool { result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }

    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    Group {
                        if let photoId { PhotoKitImage(id: photoId, preview: false) }
                        else if let image { Image(uiImage: image).resizable().scaledToFill() }
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
            .task(id: ObjectIdentifier(result.itemProvider)) {
                image = nil; photoId = nil; loaded = false
                let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if (access == .authorized || access == .limited), let id = result.assetIdentifier,
                   PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject != nil {
                    photoId = id; loaded = true; return
                }
                let preview = try? await result.itemProvider.loadPreviewImage(options: [
                    NSItemProviderPreferredImageSizeKey: NSValue(cgSize: CGSize(width: 320, height: 320))
                ])
                guard !Task.isCancelled else { return }
                image = preview.flatMap(PickerPreview.image)
                loaded = true
            }
    }
}

enum PickerPreview {
    static func image(_ preview: any NSSecureCoding) -> UIImage? {
        if let image = preview as? UIImage { return image }
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
