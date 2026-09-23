import SwiftUI

struct GallerySelectionButton: View {
    let selected: Bool
    let name: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 25, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(selected ? Color.accentColor : .white, .white)
                .padding(3).background(.black.opacity(0.35), in: Circle())
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(selected ? "取消选择" : "选择") \(name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("media.select.\(name)")
    }
}

struct GalleryEmptyState: View {
    let title: String
    let message: String
    let icon: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(32)
    }
}

struct GalleryGridSizeControl: View {
    @Binding var columns: Int
    var body: some View {
        Menu {
            Button("放大缩略图") { columns = max(2, columns - 1) }
                .disabled(columns <= 2)
            Button("缩小缩略图") { columns = min(5, columns + 1) }
                .disabled(columns >= 5)
        } label: {
            Image(systemName: "square.grid.3x3")
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("调整缩略图大小")
    }
}
