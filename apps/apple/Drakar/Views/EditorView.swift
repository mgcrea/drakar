import AppKit
import DrakarKit
import SwiftUI

/// The open files as tabs over a plain-text editor.
struct EditorView: View {
  let workspace: Workspace
  @State private var closing: EditorDocument?

  var body: some View {
    VStack(spacing: 0) {
      TabStrip(workspace: workspace) { document in
        if document.isDirty { closing = document } else { workspace.close(document) }
      }
      Divider()
      if let document = workspace.active {
        DiskBanner(document: document)
        CodeTextView(document: document) { workspace.selectionMoved() }
          .id(document.id)
      } else {
        Spacer()
      }
    }
    .confirmationDialog(
      "Save changes to \(closing?.name ?? "")?", isPresented: isClosing, presenting: closing
    ) { document in
      Button("Save") {
        workspace.save(document)
        if !document.isDirty { workspace.close(document) }
      }
      Button("Don’t Save", role: .destructive) { workspace.close(document) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Your changes will be lost if you don’t save them.")
    }
    .alert(
      "Drakar could not do that", isPresented: hasProblem, presenting: workspace.problem
    ) { _ in
      Button("OK") {}
    } message: { problem in
      Text(problem)
    }
  }

  private var isClosing: Binding<Bool> {
    Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })
  }

  private var hasProblem: Binding<Bool> {
    Binding(get: { workspace.problem != nil }, set: { if !$0 { workspace.problem = nil } })
  }
}

private struct TabStrip: View {
  let workspace: Workspace
  let close: (EditorDocument) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 0) {
        ForEach(workspace.documents) { document in
          Tab(
            document: document, isActive: document.id == workspace.activeID,
            select: { workspace.activate(document) }, close: { close(document) })
          Divider()
        }
      }
    }
    .frame(height: 30)
    .background(.background.secondary)
  }
}

private struct Tab: View {
  let document: EditorDocument
  let isActive: Bool
  let select: () -> Void
  let close: () -> Void
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 6) {
      Text(document.name)
        .lineLimit(1)
        .foregroundStyle(isActive ? .primary : .secondary)
      Button(action: close) {
        // A dot while unsaved, a cross to close on hover, as in Xcode and VS Code.
        Image(systemName: document.isDirty && !isHovering ? "circle.fill" : "xmark")
          .font(.system(size: document.isDirty && !isHovering ? 7 : 9, weight: .bold))
          .frame(width: 14, height: 14)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Close")
      .accessibilityLabel("Close \(document.name)")
      .accessibilityIdentifier("editor.close.\(document.name)")
    }
    .font(.callout)
    .padding(.horizontal, 10)
    .frame(maxHeight: .infinity)
    .background(isActive ? AnyShapeStyle(.background) : AnyShapeStyle(.clear))
    .contentShape(Rectangle())
    .onTapGesture(perform: select)
    .onHover { isHovering = $0 }
    .help(ContentView.abbreviated(document.url))
    // A tap gesture is no press to accessibility: the tab says it is one, and does it.
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { select() }
    .accessibilityIdentifier("editor.tab.\(document.name)")
  }
}

/// The file changed or vanished on disk under the user's own edits.
private struct DiskBanner: View {
  let document: EditorDocument

  var body: some View {
    if document.conflict != nil {
      banner("\(document.name) changed on disk.") {
        Button("Use the Disk’s Version") { document.reloadFromDisk() }
        Button("Keep Mine") { document.keepMine() }
      }
    } else if document.isDeleted {
      banner("\(document.name) was deleted. Saving writes it again.") {}
    }
  }

  private func banner(_ message: LocalizedStringKey, @ViewBuilder actions: () -> some View)
    -> some View
  {
    HStack(spacing: 10) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Spacer()
      actions()
    }
    .font(.callout)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.orange.opacity(0.08))
  }
}

/// An `NSTextView` over the document's own text storage: plain text, monospaced, no
/// wrapping and none of the substitutions meant for prose.
struct CodeTextView: NSViewRepresentable {
  let document: EditorDocument
  let selectionMoved: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(document: document, selectionMoved: selectionMoved)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let layoutManager = NSLayoutManager()
    layoutManager.allowsNonContiguousLayout = true
    document.storage.addLayoutManager(layoutManager)
    let container = NSTextContainer(
      size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
    container.widthTracksTextView = false
    layoutManager.addTextContainer(container)

    let textView = NSTextView(frame: .zero, textContainer: container)
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.smartInsertDeleteEnabled = false
    textView.font = EditorDocument.font
    textView.typingAttributes = EditorDocument.attributes
    textView.textContainerInset = NSSize(width: 4, height: 6)
    textView.isHorizontallyResizable = true
    textView.isVerticallyResizable = true
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    textView.autoresizingMask = [.width, .height]
    textView.delegate = context.coordinator
    textView.setAccessibilityIdentifier("editor.text")

    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = textView
    context.coordinator.layoutManager = layoutManager

    let range = NSIntersectionRange(
      document.selectedRange, NSRange(location: 0, length: document.storage.length))
    textView.setSelectedRange(range)
    DispatchQueue.main.async {
      textView.scrollRangeToVisible(range)
      textView.window?.makeFirstResponder(textView)
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {}

  /// Any size it is offered. Left to itself SwiftUI measures the scroll view's current
  /// frame and keeps it as a minimum, so the pane would not narrow with the window and the
  /// split pushed the sidebar off the window's edge instead.
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context)
    -> CGSize?
  {
    proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    // A storage keeps every layout manager added to it, and lays each one out on every edit.
    if let layoutManager = coordinator.layoutManager {
      coordinator.document.storage.removeLayoutManager(layoutManager)
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    let document: EditorDocument
    let selectionMoved: () -> Void
    var layoutManager: NSLayoutManager?

    init(document: EditorDocument, selectionMoved: @escaping () -> Void) {
      self.document = document
      self.selectionMoved = selectionMoved
    }

    func textDidChange(_ notification: Notification) {
      document.edited()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      document.selectionDidChange(textView.selectedRange())
      selectionMoved()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
      document.undoManager
    }
  }
}
