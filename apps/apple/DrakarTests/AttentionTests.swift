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
