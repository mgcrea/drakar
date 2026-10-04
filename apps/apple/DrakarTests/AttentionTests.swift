import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("What needs the person")
struct AttentionTests {

  private func project() throws -> Project {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-attention-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return Project(folder: folder)
  }

  /// Unread rows after the selected one, wrapping, the selected one never.
  @Test func nextGoesToUnreadRowsInOrder() throws {
    let project = try project()
    let c = project.newSession()
    let b = project.newSession()
    let a = project.newSession()  // rows: a, b, c; a selected
    c.isUnread = true
    #expect(project.nextNeedingAttention()?.id == c.id)
    b.isUnread = true
    #expect(project.nextNeedingAttention()?.id == b.id)
    project.select(b)
    #expect(project.nextNeedingAttention()?.id == c.id)
    c.isUnread = false
    #expect(project.nextNeedingAttention() == nil)
    _ = a
  }

  @Test func theBadgeCountsNothingWhenNothingWaits() throws {
    let project = try project()
    _ = project.newSession()
    let window = UUID()
    OpenSessions.shared.register(project, window: window)
    defer { OpenSessions.shared.unregister(window: window) }
    #expect(Attention.shared.waitingCount == 0)
  }
}

@MainActor
@Suite("The badge follows the windows")
struct AttentionBadgeTests {
  /// A stand-in `claude` that asks for a permission as soon as it starts: the hook fires when
  /// the request arrives, and again when the process goes away with it still waiting.
  @Test func aRequestAppearingAndGoingWithTheProcessBothTellTheBadge() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-attention-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fake = folder.appending(path: "claude")
    let request =
      #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"touch a.txt"},"tool_use_id":"toolu_1"}}"#
    try Data("#!/bin/sh\necho '\(request)'\ncat > /dev/null\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

    let session = ClaudeSession(folder: folder)
    session.executableOverride = fake
    var changes = 0
    session.onPermissionsChanged = { changes += 1 }
    session.send("hi")
    for _ in 0..<50 where session.transcript.pendingPermissions.isEmpty {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(session.transcript.pendingPermissions.count == 1)
    #expect(changes == 1)
    session.stop()
    #expect(session.transcript.pendingPermissions.isEmpty)
    #expect(changes == 2)
  }

  /// A window that goes away stops counting.
  @Test func aWindowThatClosesStopsCounting() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-attention-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = Project(folder: folder)
    let window = UUID()
    OpenSessions.shared.register(project, window: window)
    OpenSessions.shared.unregister(window: window)
    #expect(OpenSessions.shared.projects[window] == nil)
    #expect(Attention.shared.waitingCount == 0)
  }
}
