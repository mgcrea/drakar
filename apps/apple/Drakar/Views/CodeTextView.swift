import AppKit
import DrakarKit
import SwiftUI

/// An `NSTextView` over the document's own text storage: plain text, monospaced, no
/// wrapping and none of the substitutions meant for prose, with line numbers and colours.
struct CodeTextView: NSViewRepresentable {
  let document: EditorDocument
  /// ⌥K in this text view; nil where there is no prompt to mention into.
  var mention: (() -> Void)? = nil
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

    let textView = CodeNSTextView(frame: .zero, textContainer: container)
    textView.mention = mention
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
    // Views no longer clip by default, and the ruler's edge line would run on up through
    // the tab strip and the title bar.
    scrollView.clipsToBounds = true
    scrollView.documentView = textView
    let ruler = LineNumberRuler(textView: textView)
    scrollView.verticalRulerView = ruler
    scrollView.hasVerticalRuler = true
    scrollView.rulersVisible = true

    context.coordinator.attach(layoutManager: layoutManager, ruler: ruler)

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
  /// frame and keeps it as a minimum, so the pane would not narrow with the window.
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context)
    -> CGSize?
  {
    proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    coordinator.detach()
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    let document: EditorDocument
    let selectionMoved: () -> Void
    private var layoutManager: NSLayoutManager?
    private var ruler: LineNumberRuler?
    private var highlighting: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private let language: Syntax.Language?

    init(document: EditorDocument, selectionMoved: @escaping () -> Void) {
      self.document = document
      self.selectionMoved = selectionMoved
      language = Syntax.language(forFile: document.name)
    }

    func attach(layoutManager: NSLayoutManager, ruler: LineNumberRuler) {
      self.layoutManager = layoutManager
      self.ruler = ruler
      // Every change to the text, typed or reloaded from disk, recolours and renumbers.
      observer = NotificationCenter.default.addObserver(
        forName: NSTextStorage.didProcessEditingNotification, object: document.storage,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.textChanged(delay: .milliseconds(120)) }
      }
      textChanged(delay: .zero)
    }

    func detach() {
      highlighting?.cancel()
      if let observer { NotificationCenter.default.removeObserver(observer) }
      // A storage keeps every layout manager added to it, and lays each one out on edits.
      if let layoutManager { document.storage.removeLayoutManager(layoutManager) }
    }

    private func textChanged(delay: Duration) {
      ruler?.textChanged()
      guard let language else { return }
      highlighting?.cancel()
      let text = document.storage.string
      highlighting = Task { [weak self] in
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard !Task.isCancelled else { return }
        let tokens = await Task.detached { Syntax.tokens(in: text, language: language) }.value
        guard !Task.isCancelled, let self, self.document.storage.string == text else { return }
        self.apply(tokens, length: (text as NSString).length)
      }
    }

    /// As temporary attributes, which colour the layout without touching the text: no
    /// undo step, no unsaved dot, nothing written to disk.
    private func apply(_ tokens: [Syntax.Token], length: Int) {
      guard let layoutManager else { return }
      let all = NSRange(location: 0, length: min(length, document.storage.length))
      layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
      for token in tokens where token.range.upperBound <= all.length {
        layoutManager.addTemporaryAttribute(
          .foregroundColor, value: SyntaxColors.color(token.kind),
          forCharacterRange: NSRange(location: token.range.lowerBound, length: token.range.count))
      }
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

/// Xcode's default colours, light and dark.
enum SyntaxColors {
  static func color(_ kind: Syntax.Kind) -> NSColor {
    switch kind {
    case .keyword: keyword
    case .string: string
    case .comment: comment
    case .number: number
    case .type: type
    case .attribute: attribute
    }
  }

  private static func pair(_ light: UInt32, _ dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
      let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
  }

  static let keyword = pair(0x9B2393, 0xFC5FA3)
  static let string = pair(0xC41A16, 0xFC6A5D)
  static let comment = pair(0x5D6C79, 0x7F8C98)
  static let number = pair(0x1C00CF, 0xD0BF69)
  static let type = pair(0x703DAA, 0xD0A8FF)
  static let attribute = pair(0x643820, 0xBF8555)
}

/// Line numbers in the scroll view's vertical ruler, for the lines on screen only.
final class LineNumberRuler: NSRulerView {
  private weak var textView: NSTextView?
  private var lines: LineIndex?

  init(textView: NSTextView) {
    self.textView = textView
    super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
    clientView = textView
    ruleThickness = 36
  }

  required init(coder: NSCoder) { fatalError("not used from a nib") }

  private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

  func textChanged() {
    lines = nil
    needsDisplay = true
  }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let textView, let layoutManager = textView.layoutManager,
      let container = textView.textContainer
    else { return }
    let text = textView.string
    let lines = self.lines ?? LineIndex(text)
    self.lines = lines

    // Room for the widest number, so the ruler does not jump as the file grows.
    let digits = String(lines.count).count
    let thickness = CGFloat(max(digits, 2)) * 7 + 16
    if abs(ruleThickness - thickness) > 0.5 {
      ruleThickness = thickness
      return
    }

    let attributes: [NSAttributedString.Key: Any] = [
      .font: Self.font, .foregroundColor: NSColor.tertiaryLabelColor,
    ]
    let visible = textView.visibleRect
    let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
    let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    let inset = textView.textContainerInset.height
    let offset = convert(NSPoint.zero, from: textView).y
    var line = lines.line(containing: characters.location)
    let length = (text as NSString).length

    func draw(_ number: Int, at y: CGFloat, height: CGFloat) {
      let label = NSAttributedString(string: String(number), attributes: attributes)
      let size = label.size()
      label.draw(
        at: NSPoint(x: ruleThickness - size.width - 8, y: y + (height - size.height) / 2))
    }

    while line < lines.count {
      let start = lines.starts[line]
      if start > NSMaxRange(characters) { break }
      let fragment: NSRect
      if start < length {
        let glyph = layoutManager.glyphIndexForCharacter(at: start)
        fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      } else {
        // The empty last line after a final newline.
        fragment = layoutManager.extraLineFragmentRect
        if fragment.height == 0 { break }
      }
      draw(line + 1, at: fragment.minY + inset + offset, height: fragment.height)
      line += 1
    }
  }
}

/// Catches ⌥K by the key's position before it is typed. AppKit offers the menus only key
/// equivalents that include ⌘; an ⌥ shortcut reaches the text view as text (on a French
/// layout ⌥K types a character), so the menu's ⌥K never fires from the editor.
final class CodeNSTextView: NSTextView {
  var mention: (() -> Void)?

  /// The K key, wherever the layout puts its letter.
  static let kKeyCode: UInt16 = 40

  override func keyDown(with event: NSEvent) {
    if let mention, event.keyCode == Self.kKeyCode,
      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
    {
      mention()
      return
    }
    super.keyDown(with: event)
  }
}
