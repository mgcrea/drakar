import AppKit
import DrakarKit
import SwiftUI

/// Inline Markdown that holds a link, in a text view: AppKit shows the pointing hand over a
/// link, which SwiftUI's `Text` does not on the Mac. A click goes to the environment's
/// `openURL`, where `opensFileLinks()` takes the agents' file links.
struct LinkText: NSViewRepresentable {
  let text: AttributedString
  var isSecondary = false

  static func holdsLink(_ text: AttributedString) -> Bool {
    text.runs.contains { $0.link != nil }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSTextView {
    let view = NSTextView(usingTextLayoutManager: false)
    view.isEditable = false
    view.isSelectable = true
    view.drawsBackground = false
    view.isRichText = true
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = true
    view.isVerticallyResizable = false
    view.isHorizontallyResizable = false
    view.linkTextAttributes = [
      .foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand,
    ]
    view.delegate = context.coordinator
    return view
  }

  func updateNSView(_ view: NSTextView, context: Context) {
    context.coordinator.openURL = context.environment.openURL
    let string = Self.styled(text, color: isSecondary ? .secondaryLabelColor : .labelColor)
    guard let storage = view.textStorage, !storage.isEqual(to: string) else { return }
    storage.setAttributedString(string)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context)
    -> CGSize?
  {
    guard let container = nsView.textContainer, let layout = nsView.layoutManager else {
      return nil
    }
    let proposed = proposal.width.flatMap { $0.isFinite ? $0 : nil }
    container.size = NSSize(
      width: proposed ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    layout.ensureLayout(for: container)
    let used = layout.usedRect(for: container)
    return CGSize(width: proposed ?? ceil(used.width), height: ceil(used.height))
  }

  /// SwiftUI's styling of inline Markdown, in AppKit's attributes: the body font, bold,
  /// italic, code spans and strikethrough, and the links.
  static func styled(_ text: AttributedString, color: NSColor) -> NSAttributedString {
    let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let result = NSMutableAttributedString()
    for run in text.runs {
      let intent = run.inlinePresentationIntent ?? []
      var font = base
      if intent.contains(.code) {
        font = .monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
      }
      if intent.contains(.stronglyEmphasized) {
        font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
      }
      if intent.contains(.emphasized) {
        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
      }
      var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
      if intent.contains(.strikethrough) {
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
      if let link = run.link { attributes[.link] = link }
      result.append(
        NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
    }
    return result
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var openURL: OpenURLAction?

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      guard let openURL else { return false }
      let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
      guard let url else { return false }
      openURL(url)
      return true
    }
  }
}

extension View {
  /// Links that name a file open in this window's editor at their line, as the extension's
  /// do; elsewhere (the review window) in the file's own app. Others go to the system.
  func opensFileLinks() -> some View { modifier(OpensFileLinks()) }
}

private struct OpensFileLinks: ViewModifier {
  @Environment(\.sessionFolder) private var folder
  @Environment(\.openInEditor) private var openInEditor

  func body(content: Content) -> some View {
    content.environment(
      \.openURL,
      OpenURLAction { url in
        guard let link = FileLink(url, relativeTo: folder) else { return .systemAction }
        let file = URL(filePath: link.path)
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: link.path, isDirectory: &isFolder),
          isFolder.boolValue
        {
          NSWorkspace.shared.activateFileViewerSelecting([file])
        } else if let openInEditor {
          openInEditor(link)
        } else {
          NSWorkspace.shared.open(file)
        }
        return .handled
      })
  }
}
