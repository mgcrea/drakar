import AppKit
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Attaching from the clipboard and the disk")
struct AttachmentIntakeTests {

  private let folder: URL
  private let pasteboard = NSPasteboard(name: .init("drakar-test-\(UUID().uuidString)"))

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-intake-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  /// A 2×2 PNG, red.
  private var png: Data {
    let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
      NSColor.red.setFill()
      rect.fill()
      return true
    }
    let tiff = image.tiffRepresentation!
    return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
  }

  @Test func aScreenshotOnTheClipboardIsAttached() {
    pasteboard.clearContents()
    pasteboard.setData(png, forType: .png)
    #expect(AttachmentIntake.sources(in: pasteboard) == [.image(png, name: nil)])
  }

  @Test func copiedFilesAreAttachedButNotFolders() throws {
    let file = folder.appending(path: "notes.txt")
    try Data("hi".utf8).write(to: file)
    pasteboard.clearContents()
    pasteboard.writeObjects([file as NSURL, folder as NSURL])
    #expect(AttachmentIntake.sources(in: pasteboard) == [.file(file)])
  }

  /// Text pastes as text, even when it carries an image (rich text from a document).
  @Test func textPastesAsText() {
    pasteboard.clearContents()
    pasteboard.setString("hello", forType: .string)
    #expect(AttachmentIntake.sources(in: pasteboard) == nil)
    pasteboard.setData(png, forType: .png)
    #expect(AttachmentIntake.sources(in: pasteboard) == nil)
  }

  @Test func whatCannotBeReadIsSaidSo() async throws {
    let good = folder.appending(path: "a.txt")
    try Data("hi".utf8).write(to: good)
    let empty = folder.appending(path: "empty.txt")
    try Data().write(to: empty)
    let (attachments, notes) = await AttachmentIntake.load([.file(good), .file(empty)])
    #expect(attachments.map(\.preview.name) == ["a.txt"])
    #expect(notes == ["Empty file skipped: empty.txt"])
  }

  /// A prompt of an image alone: the image block, no text.
  @Test func anImageAloneIsSent() async throws {
    let script = folder.appending(path: "claude")
    try Data("#!/bin/sh\ncat >> \"$0.stdin\"\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let session = ClaudeSession(folder: folder)
    session.executableOverride = script
    let image = try Attachment.image(png, name: "red.png")
    session.send("", attachments: [image])
    defer { session.stop() }
    #expect(session.transcript.entries.last?.attachments == [image.preview])
    var line: String?
    for _ in 0..<50 where line == nil {
      let text =
        (try? String(contentsOf: script.appendingPathExtension("stdin"), encoding: .utf8)) ?? ""
      line = text.split(separator: "\n").map(String.init).first { $0.contains(#""type":"user""#) }
      if line == nil { try await Task.sleep(for: .milliseconds(100)) }
    }
    #expect(line?.contains(#""type":"image""#) == true)
    #expect(line?.contains(#""type":"text""#) == false)
  }
}
