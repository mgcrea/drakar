import DrakarKit
import SwiftUI

/// An attachment at a glance: an image's thumbnail, or a document's icon and name.
struct AttachmentBadge: View {
  let preview: AttachmentPreview
  var size: CGFloat = 28

  var body: some View {
    switch preview.kind {
    case .image:
      Group {
        if let data = preview.thumbnail, let image = NSImage(data: data) {
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Image(systemName: "photo").foregroundStyle(.secondary)
        }
      }
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .help(preview.name ?? String(localized: "Image"))
      .accessibilityLabel(preview.name ?? String(localized: "Image"))
    case .pdf, .text:
      Label(
        preview.name ?? String(localized: "Document"),
        systemImage: preview.kind == .pdf ? "doc.richtext" : "doc.plaintext"
      )
      .font(.caption)
      .lineLimit(1)
      .padding(.horizontal, 4)
    }
  }
}

/// A prompt's attachments, in a row above its text.
struct AttachmentRow: View {
  let previews: [AttachmentPreview]
  var size: CGFloat = 64

  var body: some View {
    HStack(spacing: 6) {
      ForEach(Array(previews.enumerated()), id: \.offset) { _, preview in
        AttachmentBadge(preview: preview, size: size)
          .padding(preview.kind == .image ? 0 : 4)
          .background(
            preview.kind == .image
              ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary.opacity(0.6)),
            in: RoundedRectangle(cornerRadius: 6))
      }
    }
    .accessibilityIdentifier("prompt.attachments")
  }
}
