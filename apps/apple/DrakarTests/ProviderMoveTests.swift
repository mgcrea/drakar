import AppKit
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Moving sessions between providers")
struct ProviderMoveTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-provider-move-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func cleanUp() {
    try? FileManager.default.removeItem(at: folder)
  }

  private func standIn(_ name: String, _ body: String) throws -> URL {
    let script = folder.appending(path: name)
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  @Test func unstartedSessionSwitchesInPlaceKeepingDraftTitleModeAndCompatibleAttachments()
    async throws
  {
    defer { cleanUp() }
    let project = Project(folder: folder)
    let item = project.newSession(agent: .claude)
    item.session.rename(to: "Scratchpad")
    item.session.setMode(.acceptEdits)
    item.draft = "Unsent draft"
    let pdfURL = folder.appending(path: "spec.pdf")
    try Data("%PDF-1.4".utf8).write(to: pdfURL)
    let pdf = try Attachment.file(at: pdfURL)
    let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
      NSColor.red.setFill()
      rect.fill()
      return true
    }
    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!
      .representation(using: .png, properties: [:])!
    let shot = try Attachment.image(png, name: "shot.png")
    item.attachments = [pdf, shot]

    let moved = await project.moveProvider(item, to: .codex)
    #expect(moved)
    #expect(project.tabs.count == 1)
    let replacement = try #require(project.selected)
    #expect(replacement.id != item.id)
    #expect(replacement.session.agent == .codex)
    #expect(replacement.session.name == "Scratchpad")
    #expect(replacement.session.modePick == .acceptEdits)
    #expect(replacement.draft == "Unsent draft")
    #expect(replacement.attachments.map(\.preview.name) == ["shot.png"])
    #expect(replacement.attachmentNote?.contains("spec.pdf") == true)
    #expect(!replacement.session.status.hasEntries)
  }

  @Test func startedIdleSessionStopsProcessAndSendsHandoverToNewProvider() async throws {
    defer { cleanUp() }
    _ = await AgentSession.environment.value
    let claude = try standIn("claude", "cat > /dev/null")
    let project = Project(folder: folder)
    defer { project.stopAll() }
    project.executableOverride = claude

    let transcriptFile = folder.appending(path: "s1.jsonl")
    try Data(
      [
        #"{"type":"user","cwd":"/tmp","message":{"role":"user","content":"Audit the auth layer"}}"#,
        #"{"type":"assistant","message":{"id":"m1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"I checked Auth.swift and found two issues."}],"stop_reason":"end_turn"}}"#,
        #"{"type":"custom-title","customTitle":"Auth audit","sessionId":"s1"}"#,
      ].joined(separator: "\n").appending("\n").utf8
    ).write(to: transcriptFile)

    let target = ResumeTarget(
      sessionID: "s1", cwd: folder.path(percentEncoded: false),
      file: transcriptFile.path(percentEncoded: false),
      accountDirectory: folder.path(percentEncoded: false), accountIsDefault: false)
    let item = project.attach(target)
    await item.session.loadHistory()
    await item.session.spawn()
    try #require(item.session.isProcessRunning)

    item.draft = "Now fix issue #2"
    let moved = await project.moveProvider(item, to: .codex)
    #expect(moved)
    #expect(!item.session.isProcessRunning)
    #expect(project.tabs.count == 1)

    let replacement = try #require(project.selected)
    #expect(replacement.session.agent == .codex)
    #expect(replacement.session.name == "Auth audit")
    #expect(replacement.draft == "Now fix issue #2")
    let sent = try #require(replacement.session.transcript.lastPrompt)
    guard case .prompt(let promptText) = sent.kind else {
      Issue.record("Expected handover prompt")
      return
    }
    #expect(promptText.contains("Claude Code to Codex"))
    #expect(promptText.contains("Title: Auth audit"))
    #expect(promptText.contains("Audit the auth layer"))
    #expect(promptText.contains("I checked Auth.swift and found two issues."))
  }

  @Test func resumedSessionWithoutLoadedHistoryLoadsBeforeHandover() async throws {
    defer { cleanUp() }
    let project = Project(folder: folder)
    defer { project.stopAll() }
    project.executableOverride = try standIn("codex", "cat > /dev/null")

    let transcriptFile = folder.appending(path: "s2.jsonl")
    try Data(
      #"{"type":"user","cwd":"/tmp","message":{"role":"user","content":"Summarize the migration"}}"#
        .appending("\n").utf8
    ).write(to: transcriptFile)

    let target = ResumeTarget(
      sessionID: "s2", cwd: folder.path(percentEncoded: false),
      file: transcriptFile.path(percentEncoded: false),
      accountDirectory: folder.path(percentEncoded: false), accountIsDefault: false)
    let item = project.attach(target, watching: true)
    #expect(!item.session.hasLoadedHistory)

    let moved = await project.moveProvider(item, to: .codex)
    #expect(moved)
    let replacement = try #require(project.selected)
    #expect(!replacement.isWatching)
    #expect(replacement.session.agent == .codex)
    let sent = try #require(replacement.session.transcript.lastPrompt)
    guard case .prompt(let text) = sent.kind else {
      Issue.record("Expected handover prompt")
      return
    }
    #expect(text.contains("Summarize the migration"))
  }

  @Test func refusesWhileRunningReadOnlyOrOnRunner() async throws {
    defer { cleanUp() }
    let project = Project(folder: folder)
    defer { project.stopAll() }
    project.executableOverride = try standIn("claude", "cat > /dev/null")

    let busy = project.newSession(agent: .claude)
    busy.session.send("working")
    #expect(!project.canMoveProvider(busy))
    #expect(project.providerMoveRefusal(for: busy) != nil)
    #expect(await project.moveProvider(busy, to: .codex) == false)
    #expect(project.tabs.first?.session.agent == .claude)

    let readOnlyTarget = ResumeTarget(
      sessionID: "ro", cwd: folder.path(percentEncoded: false),
      file: folder.appending(path: "ro.jsonl").path(percentEncoded: false),
      accountDirectory: folder.path(percentEncoded: false), accountIsDefault: false)
    let readOnly = project.attach(readOnlyTarget, watching: true, readOnly: true)
    #expect(!project.offersProviderMove(for: readOnly))
    #expect(!project.canMoveProvider(readOnly))
    #expect(await project.moveProvider(readOnly, to: .codex) == false)

    let runnerProject = Project(folder: folder, runner: "remote-1")
    let runnerItem = runnerProject.newSession()
    #expect(!runnerProject.offersProviderMove(for: runnerItem))
    #expect(!runnerProject.canMoveProvider(runnerItem))
    #expect(await runnerProject.moveProvider(runnerItem, to: .codex) == false)
  }

  @Test func incompatibleModeDropsToTargetDefault() async throws {
    defer { cleanUp() }
    let project = Project(folder: folder)
    let item = project.newSession(agent: .claude)
    item.session.setMode(.plan)
    #expect(await project.moveProvider(item, to: .codex))
    #expect(project.selected?.session.modePick == nil)
  }

  @Test func movingBackgroundTabPreservesSelectionAndMark() async throws {
    defer { cleanUp() }
    let project = Project(folder: folder)
    let a = project.newSession(agent: .claude)
    let b = project.newSession(agent: .claude)
    project.click(a, .plain)
    project.click(b, .toggle)
    project.select(b)
    #expect(project.selectedID == b.id)

    let moved = await project.moveProvider(a, to: .agy)
    #expect(moved)
    #expect(project.selectedID == b.id)
    #expect(project.tabs[0].session.agent == .agy)
    #expect(project.marked.contains(project.tabs[0].id))
    #expect(project.marked.contains(b.id))
  }
}
