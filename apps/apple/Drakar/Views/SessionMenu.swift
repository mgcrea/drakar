import AppKit
import DrakarKit
import SwiftUI

/// A tab's context menu: what can be done to its session, and closing it or the tabs beside
/// it. Right-clicked among several marked tabs, what to do to them all.
struct SessionMenu: View {
  let item: ProjectSession
  let project: Project

  var body: some View {
    if project.sendsToMarked, project.marked.contains(item.id) {
      markedMenu
    } else {
      menu
    }
  }

  @ViewBuilder private var menu: some View {
    if item.closingAsk != nil {
      Button("Dismiss") { project.dismissAsk(item) }
      Divider()
    }
    Button("Rename…") { RenameSessionPrompt.run(for: item) }
      .disabled(!project.canRename(item))
    // Hidden for an agent that cannot fork (Codex), disabled while a turn runs.
    if item.session.features.forks, !item.session.isOnRunner,
      (item.session.resuming ?? item.session.savedTarget) != nil
    {
      Button("Fork a Copy") { project.fork(item) }
        .disabled(!project.canFork(item))
    }
    Divider()
    if item.session.isProcessRunning {
      Button("End Session") { Self.confirmEnding([item]) { project.end(item) } }
    }
    Button("Close Tab") { TabClosing.request(item, in: project) }
    Button("Close Other Tabs") { project.closeOthers(than: item) }
      .disabled(project.tabs.count < 2)
    Button("Close Tabs to the Right") { project.closeToTheRight(of: item) }
      .disabled(project.tabs.last?.id == item.id)
    if let candidate = SessionMoves.candidate(for: item) {
      let others = SessionMoves.destinations(from: candidate.account)
      if !others.isEmpty {
        Divider()
        Menu("Move to") {
          ForEach(others, id: \.key) { account in
            Button(AccountStore.shared.profile(for: account).name) {
              SessionMoves.moveOne(candidate, to: account)
            }
          }
        }
      }
    }
    if item.sessionID != nil || item.session.savedTarget != nil { Divider() }
    if let id = item.sessionID {
      Button("Copy Session ID") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
      }
    }
    if let file = item.session.savedTarget?.transcriptFile, !item.session.isOnRunner {
      Button("Show Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }
  }

  /// What a right-click on one of several marked tabs does to them all.
  @ViewBuilder private var markedMenu: some View {
    let marked = project.markedSessions
    if marked.contains(where: \.session.isProcessRunning) {
      Button("End \(marked.count) Sessions") {
        Self.confirmEnding(marked) { project.stopMarked() }
      }
    }
    Button("Remove \(marked.count) Sessions from Window") {
      Self.confirmIfRunning(marked) { project.removeMarked() }
    }
    Divider()
    Button("Unmark All") { project.clearMarks() }
  }

  /// End Session: a runner's sessions are asked about every time, nothing resuming them
  /// once ended; this Mac's only mid-turn, as any stop is.
  static func confirmEnding(_ items: [ProjectSession], then action: @escaping () -> Void) {
    let onRunner = items.filter { $0.session.isOnRunner && $0.session.isProcessRunning }
    guard !onRunner.isEmpty else {
      if items.count == 1 { return confirmIfRunning(items[0], then: action) }
      return confirmIfRunning(items, then: action)
    }
    let alert = EndingOnRunner.alert(titles: onRunner.map(\.displayTitle))
    if alert.runModal() == .alertFirstButtonReturn { action() }
  }

  /// As for one tab, once for the marked tabs still working. A runner's is let go, not
  /// stopped, by any stop but End Session's, so it does not count.
  static func confirmIfRunning(_ items: [ProjectSession], then action: @escaping () -> Void) {
    let working = items.filter { $0.session.status.isRunning && !$0.session.isOnRunner }
      .count
    guard working > 0 else { return action() }
    let alert = NSAlert()
    alert.messageText =
      working == 1
      ? String(localized: "1 session is still working.")
      : String(localized: "\(working) sessions are still working.")
    alert.informativeText = String(localized: "Stopping them now ends their turns part-way.")
    alert.addButton(withTitle: String(localized: "Stop"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    if alert.runModal() == .alertFirstButtonReturn { action() }
  }

  /// Mid-turn, stopping loses the turn: ask first. A runner's is let go instead, as above.
  static func confirmIfRunning(_ item: ProjectSession, then action: @escaping () -> Void) {
    guard item.session.status.isRunning, !item.session.isOnRunner else { return action() }
    if stopsTurnAlert(for: item).runModal() == .alertFirstButtonReturn { action() }
  }

  /// "Still working": stopping `item` now would end its turn part-way.
  static func stopsTurnAlert(for item: ProjectSession) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = String(localized: "“\(item.displayTitle)” is still working.")
    alert.informativeText = String(localized: "Stopping it now ends the turn part-way.")
    alert.addButton(withTitle: String(localized: "Stop"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    return alert
  }
}

/// Closing one tab, from its × or Close Tab: at once, unless closing would lose something
/// (`Project.closeAsk(for:)`), which is asked about first. A draft is asked about before a
/// turn, and a tab with both asks both.
@MainActor enum TabClosing {
  static func request(_ item: ProjectSession, in project: Project) {
    var ask = project.closeAsk(for: item)
    if ask == .unsentDraft {
      let alert = NSAlert()
      alert.messageText = String(
        localized: "Close “\(item.displayTitle)”? Its unsent message will be lost.")
      alert.addButton(withTitle: String(localized: "Close"))
      alert.addButton(withTitle: String(localized: "Cancel"))
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      ask = project.closeAsk(for: item, draftConfirmed: true)
    }
    if ask == .stopsTurn {
      guard SessionMenu.stopsTurnAlert(for: item).runModal() == .alertFirstButtonReturn else {
        return
      }
    }
    project.closeTab(item)
  }
}
