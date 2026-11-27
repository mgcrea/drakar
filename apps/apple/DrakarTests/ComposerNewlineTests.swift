import AppKit
import Testing

@testable import Drakar

/// Shift-Return starts a line in the prompt. Return still sends, and Option-Return is left
/// to the field editor, which already starts a line for it.
@MainActor
@Suite("Shift-Return in the composer")
struct ComposerNewlineTests {

  private func key(_ flags: NSEvent.ModifierFlags, code: UInt16) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: code))
  }

  @Test func shiftReturnAndShiftEnterStartALine() throws {
    #expect(PasteMonitor.insertsNewline(try key(.shift, code: PasteMonitor.returnKey)))
    #expect(
      PasteMonitor.insertsNewline(try key([.shift, .capsLock], code: PasteMonitor.returnKey)))
    #expect(PasteMonitor.insertsNewline(try key(.shift, code: PasteMonitor.keypadEnter)))
  }

  @Test func returnAloneStillSends() throws {
    #expect(!PasteMonitor.insertsNewline(try key([], code: PasteMonitor.returnKey)))
    #expect(!PasteMonitor.insertsNewline(try key(.option, code: PasteMonitor.returnKey)))
    #expect(
      !PasteMonitor.insertsNewline(try key([.shift, .command], code: PasteMonitor.returnKey)))
    #expect(!PasteMonitor.insertsNewline(try key(.control, code: PasteMonitor.keypadEnter)))
    #expect(!PasteMonitor.insertsNewline(try key(.shift, code: 40)))
  }

  /// The field editor's own `insertNewline:` ends editing. The call the monitor makes
  /// inserts at the caret instead.
  @Test func theLineStartsAtTheCaret() {
    let textView = NSTextView()
    textView.isFieldEditor = true
    textView.string = "ac"
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    textView.insertNewlineIgnoringFieldEditor(nil)
    #expect(textView.string == "a\nc")
    #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
  }
}
