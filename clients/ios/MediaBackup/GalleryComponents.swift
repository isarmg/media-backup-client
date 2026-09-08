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
