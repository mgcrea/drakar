import AppKit
import DrakarKit
import Foundation
import Observation

/// What a window shows: a project, or the session picker until one is chosen.
///
/// A window's value, so SwiftUI restores it at launch and `openWindow(value:)` brings
/// forward the window already showing a project instead of opening a second: two windows
/// on one folder would be two editors, and could be two writers on one transcript.
enum WindowRoute: Codable, Hashable {
  case project(folder: String)
  /// `token` keeps two picker windows apart.
  case picker(token: UUID)

  static func project(_ url: URL) -> WindowRoute {
    .project(folder: ProjectPath.normalize(url))
  }

  static func picker() -> WindowRoute { .picker(token: UUID()) }

  var folder: URL? {
    if case .project(let folder) = self {
      return URL(filePath: folder, directoryHint: .isDirectory)
    }
    return nil
  }
}

struct ResumeTarget: Codable, Hashable {
  var sessionID: String
  var cwd: String
  var file: String
  var accountDirectory: String
  var accountIsDefault: Bool
  /// Continue a copy under a new id: the session is open in another process. Optional so
  /// that a target stored before the field existed still decodes.
  var forks: Bool?
  /// The agent that writes it. Optional so that a target stored before Codex arrived still
  /// decodes, as Claude Code's.
  var agent: AgentKind?

  init(
    sessionID: String, cwd: String, file: String, accountDirectory: String,
    accountIsDefault: Bool, forks: Bool? = nil, agent: AgentKind? = nil
  ) {
    self.sessionID = sessionID
    self.cwd = cwd
    self.file = file
    self.accountDirectory = accountDirectory
    self.accountIsDefault = accountIsDefault
    self.forks = forks
    self.agent = agent
  }

  init?(_ summary: SessionSummary, forking: Bool = false) {
    guard let cwd = summary.cwd else { return nil }
    self.init(
      sessionID: summary.sessionID, cwd: cwd, file: summary.file.path(percentEncoded: false),
      accountDirectory: summary.account.directory.path(percentEncoded: false),
      accountIsDefault: summary.account.isDefault, forks: forking ? true : nil)
  }

  var account: ClaudeAccount {
    ClaudeAccount(
      directory: URL(filePath: accountDirectory, directoryHint: .isDirectory),
      isDefault: accountIsDefault)
  }

  var agentKind: AgentKind { agent ?? .claude }

  var transcriptFile: URL { URL(filePath: file) }
}

/// Every project window Drakar has open, and through them every session it holds: so a
/// window knows a session is open in another, the global list knows where to send a pick,
/// and the bridge knows which folders to claim.
@Observable
final class OpenSessions {
  static let shared = OpenSessions()

  private(set) var projects: [UUID: Project] = [:]
  /// Sessions picked before their project's window existed, by folder.
  @ObservationIgnored private var pending: [String: [ResumeTarget]] = [:]

  func register(_ project: Project, window: UUID) {
    projects[window] = project
    // A window restored while a terminal has one of its sessions open locks it at once.
    if SessionMonitor.shared.hasReadRegistries { liveChanged(SessionMonitor.shared.liveIDs) }
    IDEBridge.shared.refreshFolders()
  }

  func unregister(window: UUID) {
    projects[window] = nil
    Attention.shared.refresh()
    IDEBridge.shared.refreshFolders()
  }

  /// The open projects' folders, which Drakar is the editor for by default. As the lock
  /// file lists them: no trailing slash.
  var folders: [String] {
    Array(
      Set(
        projects.values.map { ProjectPath.normalize($0.folder) }))
  }

  /// The window holding `sessionID` as one of its own rows; one only watching it does not
  /// count.
  func locate(_ sessionID: String) -> (Project, ProjectSession)? {
    for project in projects.values {
      if let session = project.session(withID: sessionID), !session.isWatching {
        return (project, session)
      }
    }
    return nil
  }

  /// The open or tracked project that would own `cwd` (a linked worktree's by its main
  /// checkout), or `cwd` itself for a new window.
  func ownerFolder(forCwd cwd: String) -> String {
    let path = SessionMonitor.shared.checkout(of: cwd)
    return ProjectPath.owner(of: path, among: folders + ProjectList.shared.tracked.paths)
      ?? ProjectPath.normalize(cwd)
  }

  /// The window showing the project at `folder`, as `normalize` writes it.
  func window(forFolder folder: String) -> NSWindow? {
    projects.values.first {
      ProjectPath.normalize($0.folder) == folder
    }?.workspace.window
  }

  func requestAttach(_ target: ResumeTarget, in folder: String) {
    pending[ProjectPath.normalize(folder), default: []].append(target)
  }

  func takePending(for folder: String) -> [ResumeTarget] {
    pending.removeValue(forKey: ProjectPath.normalize(folder)) ?? []
  }

  /// A transcript changed on disk: a read-only session following it catches up, and its
  /// rows, in every window holding or watching it, take the new summary (its last activity;
  /// its title and gauge until its history is read).
  func transcriptWritten(_ summary: SessionSummary) {
    for project in projects.values {
      guard let item = project.session(withID: summary.sessionID) else { continue }
      item.session.catchUp()
      item.preview = summary
    }
    Attention.shared.refresh()
  }

  /// The ids live in other processes now. A session listed here that another process has
  /// open is read-only: two writers on one transcript must never happen. One running here
  /// gives way, since someone took it up there, typically in an editor's panel after a move,
  /// which resumes the same id without a word. One whose process went away catches up and
  /// can be resumed here. One whose process another Drakar holds stays read-only whatever
  /// the registry says, until that app lets it go.
  func liveChanged(_ live: Set<String>) {
    for project in projects.values {
      for item in project.sessions {
        guard let id = item.sessionID, item.session.heldElsewhere == nil else { continue }
        if live.contains(id) {
          if item.session.isProcessRunning { project.gaveWay(item) }
          item.session.isReadOnly = true
        } else if item.session.isReadOnly {
          item.session.catchUp()
          item.session.isReadOnly = false
        }
      }
    }
    Attention.shared.refresh()
  }

  /// The sessions this app's own rows run in the session host: under the host, those are
  /// this app's, where every other process there is another Drakar's.
  var hostedHere: Set<String> {
    Set(projects.values.flatMap(\.sessions).filter(\.session.isHosted).compactMap(\.sessionID))
  }

  /// Sessions mid-turn across every window that quitting stops, for the quit question.
  var stoppedByQuitting: Int {
    RunningSessions.stoppedByQuitting(projects.values.flatMap { $0.sessions.map(\.session) })
  }
}
