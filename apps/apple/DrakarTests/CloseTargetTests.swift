import Foundation
import Testing

@testable import Drakar

/// What ⌘W closes: the editor's file while the editor has the keys, else the tab shown, else
/// the window; and ⌘1–⌘9, which pick a tab by its place.
@MainActor
@Suite("⌘W and the tab keys")
struct CloseTargetTests {

  @Test func theEditorsFileWhenTheEditorHasTheKeys() {
    #expect(
      CloseTarget.resolve(focusedPane: .editor, hasActiveDocument: true, hasSelectedTab: true)
        == .document)
  }

  @Test func theTabOtherwise() {
    #expect(
      CloseTarget.resolve(focusedPane: .composer, hasActiveDocument: true, hasSelectedTab: true)
        == .tab)
    #expect(
      CloseTarget.resolve(focusedPane: .editor, hasActiveDocument: false, hasSelectedTab: true)
        == .tab)
    #expect(
      CloseTarget.resolve(focusedPane: nil, hasActiveDocument: false, hasSelectedTab: true)
        == .tab)
  }

  @Test func theWindowWithNoTab() {
    #expect(
      CloseTarget.resolve(focusedPane: .composer, hasActiveDocument: false, hasSelectedTab: false)
        == .window)
  }

  /// ⌘1–⌘8 pick the tab at that place, ⌘9 the last; past the tabs, nothing changes.
  @Test func selectTabByNumber() throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-close-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let project = Project(folder: folder)
    let a = project.newSession()
    let b = project.newSession()
    let c = project.newSession()
    try #require(project.tabs.map(\.id) == [a.id, b.id, c.id])
    project.selectTab(at: 1)
    #expect(project.selectedID == b.id)
    project.selectTab(at: 8)
    #expect(project.selectedID == c.id)
    project.selectTab(at: 5)
    #expect(project.selectedID == c.id)
  }
}
