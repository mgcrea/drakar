import AmiralKit
import SwiftUI

/// A window: the session list until a route is chosen, then that session.
struct ContentView: View {
  @Binding var route: SessionRoute?
  @State private var session: ClaudeSession?

  var body: some View {
    Group {
      if let session {
        SessionView(session: session)
      } else {
        SessionsView { route = $0 }
      }
    }
    .frame(minWidth: 560, minHeight: 440)
    .navigationTitle(windowTitle)
    .navigationSubtitle(session.map { Self.abbreviated($0.folder) } ?? "")
    .onChange(of: route, initial: true) { show(route) }
    // A new session becomes a resumable one once it has an id and a transcript, so that
    // reopening the app resumes it instead of starting over in its folder.
    .onChange(of: session?.sessionID) { promoteToResume() }
    .onChange(of: registration, initial: true) { old, new in
      if let id = old?.id { OpenSessions.shared.unregister(id) }
      if let new { OpenSessions.shared.register(new.route, for: new.id) }
    }
    .onDisappear { if let id = registration?.id { OpenSessions.shared.unregister(id) } }
    .task { openFromLaunchArguments() }
  }

  /// What this window tells `OpenSessions`: its session's id and the route it holds.
  private var registration: Registration? {
    guard let route, let id = session?.sessionID else { return nil }
    return Registration(id: id, route: route)
  }

  private struct Registration: Equatable {
    var id: String
    var route: SessionRoute
  }

  private var windowTitle: String {
    guard let session else { return "Amiral" }
    return session.title ?? session.folder.lastPathComponent
  }

  private func show(_ route: SessionRoute?) {
    guard let route else { return }
    // Already showing it: the route moved from new to resume for the same session.
    if let session, let id = route.sessionID, session.sessionID == id { return }
    let target: ResumeTarget? =
      if case .resume(let target) = route { target } else { nil }
    start(ClaudeSession(folder: route.folder, resuming: target))
  }

  private func start(_ session: ClaudeSession, command: ClaudeCommand = ClaudeCommand()) {
    self.session?.stop()
    self.session = session
    Task { await session.start(command: command) }
  }

  /// The transcript lands under whichever account the shell selected; look for it in
  /// each. It exists from the first prompt on, which is when `system/init` gave the id.
  private func promoteToResume() {
    guard let route, let session, let id = session.sessionID else { return }
    // A new session, or a fork that now has its own id: either way the route still names
    // something else, and reopening the app would start it over or fork it again.
    switch route {
    case .new: break
    case .resume(let target) where target.forks == true && target.sessionID != id: break
    case .resume: return
    }
    for account in ClaudeAccount.discover() {
      let projects = account.directory.appending(path: "projects")
      let folders =
        (try? FileManager.default.contentsOfDirectory(atPath: projects.path(percentEncoded: false)))
        ?? []
      for folder in folders {
        let file = projects.appending(path: "\(folder)/\(id).jsonl")
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
          continue
        }
        self.route = .resume(
          ResumeTarget(
            sessionID: id,
            cwd: session.transcript.session?.cwd ?? session.folder.path(percentEncoded: false),
            file: file.path(percentEncoded: false),
            accountDirectory: account.directory.path(percentEncoded: false),
            accountIsDefault: account.isDefault))
        return
      }
    }
  }

  /// `~/Projects` rather than `/Users/me/Projects`, as the Finder and the shell write it.
  static func abbreviated(_ url: URL) -> String {
    let path = url.path(percentEncoded: false)
    let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
  }

  /// `make run ARGS='-amiral.debugFolder <path> -amiral.debugPrompt <text>'` opens a
  /// session and sends a first prompt with no clicks, which is how the app is checked
  /// end to end without typing into it. `-amiral.debugResume <session id>` resumes one
  /// from the index instead, through the same route a double-click takes.
  /// `-amiral.debugModel <id>` picks a cheap model for a new session, and
  /// `-amiral.debugSettingSources project` keeps the user's own permission rules and
  /// hooks out of one that needs a permission prompt to appear. Values, not flags:
  /// UserDefaults reads a value starting with `-` as the next key and drops it.
  /// Debug builds only: a shipped binary takes no instructions from its launch arguments.
  private func openFromLaunchArguments() {
    #if DEBUG
      let defaults = UserDefaults.standard
      guard session == nil, route == nil else { return }
      let prompt = defaults.string(forKey: "amiral.debugPrompt")
      if let id = defaults.string(forKey: "amiral.debugResume") {
        Task {
          let summaries = await Task.detached {
            SessionIndex.list(accounts: ClaudeAccount.discover())
          }.value
          guard let summary = summaries.first(where: { $0.sessionID == id }) else { return }
          route = SessionRoute.resume(summary)
          if let prompt { await send(prompt) }
        }
        return
      }
      guard let path = defaults.string(forKey: "amiral.debugFolder") else { return }
      let command = ClaudeCommand(
        model: defaults.string(forKey: "amiral.debugModel"),
        extraArguments: defaults.string(forKey: "amiral.debugSettingSources").map {
          ["--setting-sources", $0]
        } ?? [])
      start(
        ClaudeSession(folder: URL(filePath: path, directoryHint: .isDirectory)), command: command)
      if let prompt { Task { await send(prompt) } }
    #endif
  }

  #if DEBUG
    /// Waits for whichever session this window ends up with to be ready, then sends.
    private func send(_ prompt: String) async {
      while session == nil || session?.phase == .starting || session?.phase == .idle {
        try? await Task.sleep(for: .milliseconds(100))
      }
      session?.send(prompt)
    }
  #endif
}
