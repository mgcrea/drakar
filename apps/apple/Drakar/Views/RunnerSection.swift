import AppKit
import DrakarKit
import SwiftUI

/// A process the runner's host holds, as Home lists it under the runner (remote sessions
/// spec §4 "Closing, quitting, ending", §5 "What the Mac shows of sessions it does not hold").
struct RunnerRow: Identifiable, Equatable {
  var id: String
  /// The window it belongs to, a path on the runner.
  var folder: String
  /// The name it was given, from its meta.
  var name: String?
  var running: Bool
  var state: State

  enum State {
    /// This Mac's app holds it: its window shows it.
    case here
    /// This Mac's, and no app holds it: closed, quit, or brought back with no window to hear
    /// it. A click takes it back.
    case idle
    /// The runner's own Drakar's, or another Mac's: this Mac has no transcript of it, and
    /// opens no window for it.
    case onTheRunner
    /// This Mac's, its End Session waiting for the host to let it go: nothing takes it back.
    case ending
  }
}

/// What Home shows of a runner, from what its host lists.
enum RunnerSection {
  /// Every process `held` lists, sorted three ways by whether `mac` (this Mac's name) may take
  /// it (`SessionMeta.mayBeTaken`) and whether an app holds it, or as `ending` when its end is
  /// under way (`SessionHost.endsUnderWay`). A meta this app cannot read is no row.
  static func rows(held: [HeldProcess], mac: String, ending: Set<String> = []) -> [RunnerRow] {
    held.compactMap { process in
      guard let meta = try? JSONDecoder().decode(SessionMeta.self, from: process.meta) else {
        return nil
      }
      let state: RunnerRow.State =
        !meta.mayBeTaken(by: mac, onRunner: true)
        ? .onTheRunner
        : ending.contains(process.id) ? .ending : process.attachedApp == nil ? .idle : .here
      return RunnerRow(
        id: process.id, folder: ProjectPath.normalize(meta.windowFolder), name: meta.name,
        running: process.running, state: state)
    }
  }

  /// `held` less what this app is ending (`SessionHost.ended`): held by this app as the end
  /// goes, or ended. An end still waiting (`underWay`) is shown, as `ending`; one that runs on
  /// with nobody holding it and no end waiting is an end that missed it, and is shown, so that
  /// the person can take it back or end it again.
  static func shown(
    _ held: [HeldProcess], ended: Set<String>, underWay: Set<String> = []
  ) -> [HeldProcess] {
    held.filter {
      !ended.contains($0.id) || underWay.contains($0.id) || ($0.running && $0.attachedApp == nil)
    }
  }

  /// The folders the processes in `held` were started for, each once, in the order listed:
  /// New Session on Runner…'s recent folders.
  static func recentFolders(of held: [HeldProcess]) -> [String] {
    var seen: Set<String> = []
    return held.compactMap { process in
      guard let meta = try? JSONDecoder().decode(SessionMeta.self, from: process.meta) else {
        return nil
      }
      let folder = ProjectPath.normalize(meta.windowFolder)
      return seen.insert(folder).inserted ? folder : nil
    }
  }
}

/// Home's runner section: the runner set up, how it is reached, and what its host holds, read
/// again on each `refresh`. The connection itself is the app's to keep
/// (`SessionHost.keepRunnerConnected`); this only asks it.
@MainActor @Observable final class RunnerSectionModel {
  enum Link: Equatable {
    case connecting
    case connected
    /// Reached before, not now.
    case reconnecting
    /// Why the last attempt failed: ssh's, or "Update Drakar on …".
    case failed(String)
  }

  /// The runner's name; nil with no runner set up, and then no section.
  private(set) var name: String?
  private(set) var link = Link.connecting
  /// As last listed: kept while the runner is out of reach, so its windows still open.
  private(set) var rows: [RunnerRow] = []

  @ObservationIgnored private let host: () -> SessionHost?
  @ObservationIgnored private let project: (WindowRoute) -> Project?
  /// Ended from here, and when: not shown until gone from the list, or until `endingLimit`
  /// says the end did not take.
  @ObservationIgnored private var ending: [String: ContinuousClock.Instant] = [:]
  private static let endingLimit = Duration.seconds(10)

  /// `host`: the runner set up, none when the app hosts the tests, whose runner hosts are the
  /// tests' own; `project`: the open window a route names. Tests give their own.
  init(
    host: @escaping () -> SessionHost? = {
      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        ? SessionHost.runner : nil
    },
    project: @escaping (WindowRoute) -> Project? = { OpenSessions.shared.project(for: $0) }
  ) {
    self.host = host
    self.project = project
  }

  /// What End Idle Sessions… ends.
  var idleCount: Int { rows.count { $0.state == .idle } }

  /// The rows by folder, folders in the order first listed.
  var groups: [(folder: String, rows: [RunnerRow])] {
    var order: [String] = []
    var rows: [String: [RunnerRow]] = [:]
    for row in self.rows {
      if rows[row.folder] == nil { order.append(row.folder) }
      rows[row.folder, default: []].append(row)
    }
    return order.map { ($0, rows[$0] ?? []) }
  }

  /// The runner's host asked again.
  func refresh() async {
    guard let host = host() else {
      name = nil
      rows = []
      return
    }
    let listed = await host.listed()
    // Cleared or replaced meanwhile: what came back is of a runner no longer set up.
    guard self.host() === host else { return }
    name = host.runnerName
    link =
      if host.isAvailable { .connected } else if let failure = host.failure {
        .failed(failure.message)
      } else if host.facts != nil { .reconnecting } else { .connecting }
    guard let listed else {
      // Another runner now, or not reached yet: nothing listed before is of it.
      if host.facts == nil { rows = [] }
      return
    }
    let now = ContinuousClock.now
    ending = ending.filter { id, since in
      now - since < Self.endingLimit && listed.contains { $0.id == id }
    }
    let shown = RunnerSection.shown(listed, ended: host.ended, underWay: host.endsUnderWay)
      .filter { ending[$0.id] == nil }
    rows = RunnerSection.rows(held: shown, mac: ThisMac.name, ending: host.endsUnderWay)
  }

  /// A row clicked. This Mac's opens in its runner window (`enter`): one open already takes it
  /// back now, which it does not do by itself on a new connection (`Project.adoptHeld`).
  /// Another's opens nowhere here: what to say instead.
  func open(_ row: RunnerRow, enter: (WindowRoute) -> Void) async -> String? {
    guard let host = host(), let runner = host.runnerID else { return nil }
    switch row.state {
    case .onTheRunner:
      let name = host.runnerName ?? String(localized: "the runner")
      return String(localized: "Open it in Drakar on \(name)")
    case .ending: return nil
    case .idle, .here: break
    }
    if host.ended.contains(row.id) {
      // An end that missed it, as the host lists it now, not as the row was listed: running,
      // free, and no end under way, which only that end may clear.
      let now = await host.listed()?.first { $0.id == row.id }
      guard let now, now.running, now.attachedApp == nil, host.ended.contains(row.id),
        !host.endsUnderWay.contains(row.id)
      else { return nil }
      host.notEnding(row.id)
    }
    let route = WindowRoute.runnerProject(runner: runner, folder: row.folder)
    let window = project(route)
    enter(route)
    // A window opening takes back what it may (`takeBackHeld`).
    guard let window, let listed = await host.listed() else { return nil }
    await window.reopen(row.id, among: listed)
    return nil
  }

  /// The runner window of `folder`, as `enter` opens it.
  func route(for folder: String) -> WindowRoute? {
    host()?.runnerID.map { .runnerProject(runner: $0, folder: folder) }
  }

  /// End Idle Sessions…: each process this Mac left on the runner ends, and is forgotten.
  func endIdle() async {
    await end(rows.filter { $0.state == .idle }.map(\.id))
  }

  /// End Session… on a row this Mac left on the runner.
  func end(_ row: RunnerRow) async {
    await end([row.id])
  }

  /// Ends those of `ids` the host still lists as this Mac's and free: one a window took
  /// meanwhile is not ended under it.
  private func end(_ ids: [String]) async {
    guard let host = host(), let listed = await host.listed(), let client = await host.client()
    else { return }
    let shown = RunnerSection.shown(listed, ended: host.ended, underWay: host.endsUnderWay)
    let idle = Set(
      RunnerSection.rows(held: shown, mac: ThisMac.name, ending: host.endsUnderWay)
        .filter { $0.state == .idle }.map(\.id))
    for id in ids where idle.contains(id) {
      guard (try? client.send(.terminate(id: id, forget: true))) != nil else { continue }
      ending[id] = .now
    }
    await refresh()
  }
}

/// The question before End Idle Sessions…, in End Session's words (`EndingOnRunner`).
enum EndingIdleOnRunner {
  static func alert(count: Int, runner: String) -> NSAlert {
    let alert = NSAlert()
    if count == 1 {
      alert.messageText = String(localized: "End the idle session on \(runner)?")
      alert.informativeText = String(
        localized: "No window shows it. This conversation can't be resumed from this Mac.")
    } else {
      alert.messageText = String(localized: "End \(count) idle sessions on \(runner)?")
      alert.informativeText = String(
        localized: "No window shows them. These conversations can't be resumed from this Mac.")
    }
    alert.addButton(
      withTitle: count == 1 ? String(localized: "End Session") : String(localized: "End Sessions"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    return alert
  }
}

/// The runner's sessions in Home's list: a header with the runner and how it is reached, then
/// each folder with its sessions. Shown only while a runner is set up.
struct RunnerSectionView: View {
  let model: RunnerSectionModel
  /// Filters folders and names, as Home's search does projects.
  let query: String
  /// A runner window: its open one comes forward, or this one becomes it.
  let enter: (WindowRoute) -> Void

  var body: some View {
    if let name = model.name {
      Section {
        if groups.isEmpty {
          Text(
            query.isEmpty
              ? String(localized: "No sessions on \(name)")
              : String(localized: "No matching sessions on \(name)")
          )
          .foregroundStyle(.secondary)
        }
        ForEach(groups, id: \.folder) { group in
          folderRow(group.folder)
          ForEach(group.rows) { row in
            sessionRow(row, on: name)
          }
        }
      } header: {
        header(name)
      }
    }
  }

  private var groups: [(folder: String, rows: [RunnerRow])] {
    guard !query.isEmpty else { return model.groups }
    return model.groups.compactMap { group in
      if group.folder.localizedCaseInsensitiveContains(query) { return group }
      let rows = group.rows.filter { $0.name?.localizedCaseInsensitiveContains(query) == true }
      return rows.isEmpty ? nil : (group.folder, rows)
    }
  }

  private func header(_ name: String) -> some View {
    HStack(spacing: 8) {
      Text(name)
      Text(linkText)
        .font(.caption)
        .foregroundStyle(linkIsBad ? .red : .secondary)
        .lineLimit(2)
        .textCase(nil)
      Spacer()
      Button("New Session…") { NewRunnerSession.ask() }
        .buttonStyle(.link)
        .textCase(nil)
      Button(
        model.idleCount == 0
          ? String(localized: "End Idle Sessions…")
          : String(localized: "End \(model.idleCount) Idle Sessions…")
      ) { confirmEndIdle(on: name) }
      .buttonStyle(.link)
      .textCase(nil)
      .disabled(model.idleCount == 0 || model.link != .connected)
      .help("Ends the sessions this Mac left on \(name) that no window shows")
    }
  }

  private var linkText: String {
    switch model.link {
    case .connecting: String(localized: "Connecting…")
    case .connected: String(localized: "Connected")
    case .reconnecting: String(localized: "Reconnecting…")
    case .failed(let message): message
    }
  }

  private var linkIsBad: Bool {
    if case .failed = model.link { return true }
    return false
  }

  /// Opens the folder's runner window, which takes back what this Mac left there.
  private func folderRow(_ folder: String) -> some View {
    Button {
      if let route = model.route(for: folder) { enter(route) }
    } label: {
      folderLabel(folder)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("home.runner.folder.\(folder)")
  }

  private func folderLabel(_ folder: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "folder.fill")
        .foregroundStyle(Theme.accent)
        .font(.title3)
      VStack(alignment: .leading, spacing: 2) {
        Text(URL(filePath: folder).lastPathComponent).fontWeight(.medium)
        Text(folder)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  private func sessionRow(_ row: RunnerRow, on runner: String) -> some View {
    Button {
      Task {
        guard let notice = await model.open(row, enter: enter) else { return }
        let alert = NSAlert()
        alert.messageText = notice
        alert.informativeText = String(
          localized: "It isn't this Mac's now, and this Mac has no transcript of it to show.")
        ask(alert) {}
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: symbol(row))
          .foregroundStyle(.secondary)
          .frame(width: 18)
        Text(row.name ?? String(localized: "Untitled session"))
          .foregroundStyle(row.name == nil ? .secondary : .primary)
          .lineLimit(1)
        Spacer()
        Text(status(row, on: runner))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.leading, 28)
      .padding(.vertical, 2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(row.state == .ending)
    .contextMenu {
      if row.state == .idle {
        Button("End Session…") { confirmEnd(row) }
      }
    }
    .accessibilityIdentifier("home.runner.session.\(row.id)")
  }

  private func symbol(_ row: RunnerRow) -> String {
    switch row.state {
    case .here: "macwindow"
    case .idle: "tray.fill"
    case .onTheRunner: "desktopcomputer"
    case .ending: "xmark.circle"
    }
  }

  private func status(_ row: RunnerRow, on runner: String) -> String {
    let state =
      switch row.state {
      case .here: String(localized: "Open in Drakar")
      case .idle: String(localized: "No window")
      case .onTheRunner: String(localized: "On \(runner)")
      case .ending: String(localized: "Ending…")
      }
    return row.running ? state : String(localized: "Ended · \(state)")
  }

  private func confirmEndIdle(on runner: String) {
    let count = model.idleCount
    guard count > 0 else { return }
    ask(EndingIdleOnRunner.alert(count: count, runner: runner)) {
      Task { await model.endIdle() }
    }
  }

  private func confirmEnd(_ row: RunnerRow) {
    let title = row.name ?? String(localized: "Untitled session")
    ask(EndingOnRunner.alert(titles: [title])) {
      Task { await model.end(row) }
    }
  }

  /// `alert` as a sheet of the window in front, `then` on its first button.
  private func ask(_ alert: NSAlert, then: @escaping () -> Void) {
    guard let window = NSApp.keyWindow else {
      if alert.runModal() == .alertFirstButtonReturn { then() }
      return
    }
    alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { then() } }
  }
}
