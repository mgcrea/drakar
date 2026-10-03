import AppKit
import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// An open file against a disk the agent writes to. Typing is simulated by editing the text
/// storage as the text view does, then telling the document, as its delegate does:
/// accessibility cannot write into the text view, and synthetic keystrokes would land in
/// whatever the person at the Mac is using.
@MainActor
@Suite("An open file")
struct EditorDocumentTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-document-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func file(_ name: String, _ text: String) throws -> URL {
    let url = folder.appending(path: name)
    try text.write(to: url, atomically: false, encoding: .utf8)
    return url
  }

  private func type(_ text: String, into document: EditorDocument) {
    document.storage.replaceCharacters(
      in: NSRange(location: document.storage.length, length: 0), with: text)
    document.edited()
  }

  private func disk(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

  @Test func followsTheDiskWhileUntouched() throws {
    let url = try file("a.txt", "one\n")
    let document = EditorDocument(url: url, text: "one\n")
    try "two\n".write(to: url, atomically: true, encoding: .utf8)
    document.diskChanged()
    #expect(document.storage.string == "two\n")
    #expect(!document.isDirty)
    #expect(document.conflict == nil)
  }

  @Test func asksWhenBothChangedAndKeepsTheUsersChoice() throws {
    let url = try file("a.txt", "one\n")
    let document = EditorDocument(url: url, text: "one\n")
    type("mine\n", into: document)
    #expect(document.isDirty)
    try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
    document.diskChanged()
    #expect(document.conflict == "theirs\n")
    #expect(document.storage.string == "one\nmine\n")

    document.keepMine()
    #expect(document.conflict == nil)
    // Their version is now the one on record: the same change seen again asks nothing.
    document.diskChanged()
    #expect(document.conflict == nil)
    try document.save()
    #expect(try disk(url) == "one\nmine\n")
    #expect(!document.isDirty)
  }

  @Test func takesTheDisksVersionWhenAsked() throws {
    let url = try file("a.txt", "one\n")
    let document = EditorDocument(url: url, text: "one\n")
    type("mine\n", into: document)
    try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
    document.diskChanged()
    document.reloadFromDisk()
    #expect(document.storage.string == "theirs\n")
    #expect(!document.isDirty)
    // The undo history described the old text; it must not be replayed onto the new one.
    #expect(!document.undoManager.canUndo)
  }

  @Test func notesADeletionAndWritesItBackOnSave() throws {
    let url = try file("a.txt", "one\n")
    let document = EditorDocument(url: url, text: "one\n")
    try FileManager.default.removeItem(at: url)
    document.diskChanged()
    #expect(document.isDeleted)
    try document.save()
    #expect(try disk(url) == "one\n")
    #expect(!document.isDeleted)
  }

  /// In place, through the link: a script stays executable and a link stays a link.
  @Test func savesInPlaceThroughALink() throws {
    let target = try file("run.sh", "echo one\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    let link = folder.appending(path: "link.sh")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let document = EditorDocument(url: link, text: "echo one\n")
    type("echo two\n", into: document)
    try document.save()
    #expect(try disk(target) == "echo one\necho two\n")
    let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
    #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
    let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
    #expect(mode as? Int == 0o755)
  }

  @Test func reportsTheSelectionAsClaudeCountsIt() throws {
    let url = try file("a.txt", "alpha\nbeta\ngamma\n")
    let document = EditorDocument(url: url, text: "alpha\nbeta\ngamma\n")
    document.select(NSRange(location: 6, length: 10))
    #expect(document.selection.label == "a.txt:2–3")
    #expect(document.lineCount == 4)
  }

  @Test func opensOnceAndRefusesWhatIsNotText() throws {
    let workspace = Workspace(folder: folder)
    let url = try file("a.txt", "one\n")
    let first = workspace.open(url)
    let again = workspace.open(url)
    #expect(first != nil && first === again)
    #expect(workspace.documents.count == 1)
    let binary = folder.appending(path: "b.bin")
    try Data([0x00, 0x01]).write(to: binary)
    #expect(workspace.open(binary) == nil)
    #expect(workspace.problem == "b.bin is not a text file.")
  }

  @Test func pinsEachSelectionOnce() throws {
    let workspace = Workspace(folder: folder)
    let document = try #require(workspace.open(try file("a.txt", "alpha\nbeta\n")))
    document.select(NSRange(location: 0, length: 5))
    workspace.pinSelection()
    workspace.pinSelection()
    document.select(NSRange(location: 6, length: 4))
    workspace.pinSelection()
    #expect(workspace.pinned.map(\.label) == ["a.txt:1", "a.txt:2"])
  }
}

/// The guard in front of SwiftUI's window delegate: it must ask only when a tab is unsaved,
/// and pass everything else through untouched, or SwiftUI's own window handling breaks.
@MainActor
@Suite("Closing a window with unsaved tabs")
struct WindowCloseGuardTests {

  /// Stands in for SwiftUI's delegate.
  private final class Original: NSObject, NSWindowDelegate {
    var askedToClose = 0
    var resized = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool {
      askedToClose += 1
      return true
    }
    func windowDidResize(_ notification: Notification) { resized += 1 }
  }

  private func setUp() throws -> (NSWindow, Original, Workspace, URL) {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-close-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "a.txt")
    try "one\n".write(to: file, atomically: false, encoding: .utf8)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let original = Original()
    window.delegate = original
    let workspace = Workspace(folder: folder)
    WindowCloseGuard.install(on: window, for: workspace)
    return (window, original, workspace, file)
  }

  @Test func forwardsWhatItDoesNotHandle() throws {
    let (window, original, workspace, _) = try setUp()
    #expect(window.delegate is WindowCloseGuard)
    #expect(workspace.closeGuard != nil)
    let delegate = try #require(window.delegate)
    #expect(delegate.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))
    NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
    delegate.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))
    #expect(original.resized >= 1)
    // Installing twice must not stack a guard in front of the guard.
    WindowCloseGuard.install(on: window, for: workspace)
    #expect(delegate === window.delegate)
  }

  @Test func letsACleanWindowCloseAsSwiftUISays() throws {
    let (window, original, workspace, file) = try setUp()
    workspace.open(file)
    #expect(window.delegate?.windowShouldClose?(window) == true)
    #expect(original.askedToClose == 1)
  }

  @Test func holdsAWindowWithUnsavedTabsAndAsks() throws {
    let (window, original, workspace, file) = try setUp()
    let document = try #require(workspace.open(file))
    document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
    document.edited()
    #expect(window.delegate?.windowShouldClose?(window) == false)
    // Held back, and SwiftUI never asked. The sheet itself needs the window on screen,
    // which a test does not do.
    #expect(original.askedToClose == 0)
  }
}

/// ⌥K is caught by the editor, not left to the menu, which never sees an ⌥-only shortcut.
@MainActor
@Suite("⌥K in the editor")
struct PinKeyTests {

  private func key(_ flags: NSEvent.ModifierFlags, characters: String) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: "k",
        isARepeat: false, keyCode: CodeNSTextView.kKeyCode))
  }

  @Test func pinsOnOptionKWhateverItWouldType() throws {
    let textView = CodeNSTextView()
    var pins = 0
    textView.pin = { pins += 1 }
    // "È" is what ⌥K types on a French layout; the key's position is what counts.
    textView.keyDown(with: try key(.option, characters: "È"))
    #expect(pins == 1)
    #expect(textView.string.isEmpty)
    textView.keyDown(with: try key([.option, .shift], characters: "K"))
    #expect(pins == 1)
  }
}
