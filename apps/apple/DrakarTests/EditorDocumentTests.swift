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
}
