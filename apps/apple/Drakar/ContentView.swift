import AppKit
import DrakarKit
import SwiftUI

/// A window: the session list until a route is chosen, then that session beside its
/// folder's files and the editor.
struct ContentView: View {
  @Binding var route: SessionRoute?
  @State private var session: ClaudeSession?
  @State private var workspace: Workspace?
  /// Names this window to `OpenSessions`, which keeps each window's folder.
  @State private var windowID = UUID()
  @Environment(\.appearsActive) private var appearsActive
  /// The editor's share of the window beside the session, kept per window.
  @SceneStorage("drakar.editorFraction") private var editorFraction = 0.5

  var body: some View {
    Group {
      if let session, let workspace {
        NavigationSplitView {
          FileTreeView(workspace: workspace)
            .navigationSplitViewColumnWidth(220)
        } detail: {
          // The editor appears with the first open file. The session's view must survive
          // it appearing, which is why the session is stopped by this window closing and
          // not by its own view going away.
          SplitPanes(fraction: $editorFraction, showsLeading: !workspace.documents.isEmpty) {
            EditorView(workspace: workspace)
          } trailing: {
            SessionView(session: session, workspace: workspace)
          }
        }
        .background(
          WindowReader { window in
            workspace.window = window
            WindowCloseGuard.install(on: window, for: workspace)
          }
        )
        // The dot in the close button, as in every document window.
        .onChange(of: workspace.unsavedDocuments.isEmpty, initial: true) { _, clean in
          workspace.window?.isDocumentEdited = !clean
        }
        .focusedSceneValue(\.workspace, workspace)
        .sheet(isPresented: quickOpenShown(workspace)) { QuickOpenView(workspace: workspace) }
        .onChange(of: appearsActive, initial: true) { _, active in
          if active { workspace.becameActive() }
        }
      } else {
        SessionsView { route = $0 }
      }
    }
    .frame(minWidth: 560, minHeight: 440)
    .navigationTitle(windowTitle)
    // Short, because the title bar does not truncate it: a long path widened the detail
    // column past the window and pushed the sidebar off its leading edge.
    .navigationSubtitle(session.map { Self.shortened($0.folder) } ?? "")
    .onChange(of: route, initial: true) { show(route) }
    // A new session becomes a resumable one once it has an id and a transcript, so that
    // reopening the app resumes it instead of starting over in its folder.
    .onChange(of: session?.sessionID) { promoteToResume() }
    .onChange(of: registration, initial: true) { old, new in
      if let id = old?.id { OpenSessions.shared.unregister(id) }
      if let new { OpenSessions.shared.register(new.route, for: new.id) }
    }
    .onChange(of: session?.folder, initial: true) { _, folder in
      OpenSessions.shared.setFolder(folder, forWindow: windowID)
    }
    .onDisappear {
      session?.stop()
      if let id = registration?.id { OpenSessions.shared.unregister(id) }
      OpenSessions.shared.setFolder(nil, forWindow: windowID)
    }
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

  private func quickOpenShown(_ workspace: Workspace) -> Binding<Bool> {
    Binding(get: { workspace.isQuickOpenShown }, set: { workspace.isQuickOpenShown = $0 })
  }

  private var windowTitle: String {
    guard let session else { return "Drakar" }
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
    if workspace?.folder != session.folder { workspace = Workspace(folder: session.folder) }
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

  /// The folder's path as `abbreviated` writes it, or only its last two folders when
  /// that is long: `…/scratchpad/editor-probe`.
  static func shortened(_ url: URL) -> String {
    let path = abbreviated(url)
    guard path.count > 40 else { return path }
    return "…/" + url.pathComponents.suffix(2).joined(separator: "/")
  }

  /// `~/Projects` rather than `/Users/me/Projects`, as the Finder and the shell write it.
  static func abbreviated(_ url: URL) -> String {
    let path = url.path(percentEncoded: false)
    let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
  }

  /// `make run ARGS='-drakar.debugFolder <path> -drakar.debugPrompt <text>'` opens a
  /// session and sends a first prompt with no clicks, which is how the app is checked
  /// end to end without typing into it. `-drakar.debugResume <session id>` resumes one
  /// from the index instead, through the same route a double-click takes.
  /// `-drakar.debugModel <id>` picks a cheap model for a new session, and
  /// `-drakar.debugSettingSources project` keeps the user's own permission rules and
  /// hooks out of one that needs a permission prompt to appear. `-drakar.debugOpen
  /// <path>` opens a file of the folder in the editor, and `-drakar.debugQuickOpen
  /// <query>` shows quick open with that query typed. Values, not flags:
  /// UserDefaults reads a value starting with `-` as the next key and drops it.
  /// Debug builds only: a shipped binary takes no instructions from its launch arguments.
  private func openFromLaunchArguments() {
    #if DEBUG
      let defaults = UserDefaults.standard
      guard session == nil, route == nil else { return }
      let prompt = defaults.string(forKey: "drakar.debugPrompt")
      if let id = defaults.string(forKey: "drakar.debugResume") {
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
      guard let path = defaults.string(forKey: "drakar.debugFolder") else { return }
      let command = ClaudeCommand(
        model: defaults.string(forKey: "drakar.debugModel"),
        extraArguments: defaults.string(forKey: "drakar.debugSettingSources").map {
          ["--setting-sources", $0]
        } ?? [])
      let folder = URL(filePath: path, directoryHint: .isDirectory)
      start(ClaudeSession(folder: folder), command: command)
      if let file = defaults.string(forKey: "drakar.debugOpen") {
        workspace?.open(URL(filePath: file, relativeTo: folder))
      }
      if let query = defaults.string(forKey: "drakar.debugQuickOpen") {
        workspace?.showQuickOpen(query: query)
      }
      if let prompt { Task { await send(prompt) } }
    #endif
  }

  #if DEBUG
    /// Waits for whichever session this window ends up with to be ready, then sends, with
    /// the editor's context attached as the composer would.
    private func send(_ prompt: String) async {
      while session == nil || session?.phase == .starting || session?.phase == .idle {
        try? await Task.sleep(for: .milliseconds(100))
      }
      session?.send(prompt, context: workspace?.active?.selection)
    }
  #endif
}

/// Hands over the window a view is in, once it is in one.
private struct WindowReader: NSViewRepresentable {
  let found: (NSWindow) -> Void

  func makeNSView(context: Context) -> NSView { WindowView(found: found) }
  func updateNSView(_ view: NSView, context: Context) {}

  private final class WindowView: NSView {
    let found: (NSWindow) -> Void

    init(found: @escaping (NSWindow) -> Void) {
      self.found = found
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { found(window) }
    }
  }
}
