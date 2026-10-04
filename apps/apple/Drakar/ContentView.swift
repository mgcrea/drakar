import AppKit
import DrakarKit
import SwiftUI

/// A window: the session picker until a project is chosen, then the project's sessions
/// over its files in the sidebar, the editor, and the selected session.
struct ContentView: View {
  @Binding var route: WindowRoute?
  @State private var project: Project?
  /// Names this window to `OpenSessions`.
  @State private var windowID = UUID()
  @Environment(\.appearsActive) private var appearsActive
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  /// The editor's share of the window beside the session, kept per window.
  @SceneStorage("drakar.editorFraction") private var editorFraction = 0.5
  /// Whether this window floats above other apps' windows, kept per window.
  @SceneStorage("drakar.keepsOnTop") private var keepsOnTop = false
  /// The attached sessions and the one shown, as JSON (`StoredProject`).
  @SceneStorage("drakar.project") private var storedProject = ""

  var body: some View {
    Group {
      if let project {
        let workspace = project.workspace
        NavigationSplitView {
          ProjectSidebar(project: project)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
          SplitPanes(fraction: $editorFraction, showsLeading: !workspace.documents.isEmpty) {
            EditorView(workspace: workspace)
          } trailing: {
            if let item = project.selected {
              SessionView(item: item, project: project).id(item.id)
            } else {
              ContentUnavailableView {
                Label("No session", systemImage: "bubble.left.and.text.bubble.right")
              } actions: {
                Button("New Session") { project.newSession() }
              }
            }
          }
        }
        .background(
          WindowReader { window in
            workspace.window = window
            WindowCloseGuard.install(on: window, for: workspace)
          }
        )
        .onChange(of: workspace.unsavedDocuments.isEmpty, initial: true) { _, clean in
          workspace.window?.isDocumentEdited = !clean
        }
        .focusedSceneValue(\.workspace, workspace)
        .focusedSceneValue(\.project, project)
        .sheet(isPresented: quickOpenShown(workspace)) { QuickOpenView(workspace: workspace) }
        .sheet(isPresented: searchShown(workspace)) { ProjectSearchView(workspace: workspace) }
        .onChange(of: appearsActive, initial: true) { _, active in
          if active { workspace.becameActive() }
        }
        .onChange(of: project.stored, initial: true) { _, stored in
          storedProject = (try? String(decoding: JSONEncoder().encode(stored), as: UTF8.self)) ?? ""
        }
      } else {
        SessionsView(
          pick: pick,
          openFolder: { folder in
            show(.project(folder), attaching: [])
          })
      }
    }
    .frame(minWidth: 680, minHeight: 440)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Toggle(isOn: $keepsOnTop) {
          Label("Keep on Top", systemImage: keepsOnTop ? "pin.fill" : "pin")
        }
        .toggleStyle(.button)
        .help(keepsOnTop ? "Stop keeping this window on top" : "Keep this window on top")
        .accessibilityIdentifier("window.keepOnTop")
      }
    }
    .background(WindowLevel(floats: keepsOnTop))
    .navigationTitle(windowTitle)
    .navigationSubtitle(project?.selected?.displayTitle ?? "")
    .onChange(of: route, initial: true) { open(route) }
    .onDisappear {
      project?.stopAll()
      OpenSessions.shared.unregister(window: windowID)
    }
    .task { openFromLaunchArguments() }
  }

  private var windowTitle: String {
    project.map { Self.shortened($0.folder) } ?? "Drakar"
  }

  private func quickOpenShown(_ workspace: Workspace) -> Binding<Bool> {
    Binding(get: { workspace.isQuickOpenShown }, set: { workspace.isQuickOpenShown = $0 })
  }

  private func searchShown(_ workspace: Workspace) -> Binding<Bool> {
    Binding(get: { workspace.isSearchShown }, set: { workspace.isSearchShown = $0 })
  }

  /// The project for `route`, restored from scene storage the first time.
  private func open(_ route: WindowRoute?) {
    guard let folder = route?.folder else { return }
    if project?.folder.standardizedFileURL != folder.standardizedFileURL {
      let stored = try? JSONDecoder().decode(StoredProject.self, from: Data(storedProject.utf8))
      let project = Project(folder: folder, restoring: stored)
      self.project = project
      OpenSessions.shared.register(project, window: windowID)
    }
    guard let project else { return }
    for target in OpenSessions.shared.takePending(for: folder.path(percentEncoded: false)) {
      project.attach(target)
    }
    if project.sessions.isEmpty { project.newSession() }
  }

  /// A session picked in this picker window: shown where it already is, or in the project
  /// window that owns its folder, this one becoming it when none is open.
  private func pick(_ summary: SessionSummary, forking: Bool) {
    if !forking, let (owner, item) = OpenSessions.shared.locate(summary.sessionID) {
      owner.select(item)
      owner.workspace.window?.makeKeyAndOrderFront(nil)
      return
    }
    guard let cwd = summary.cwd, let target = ResumeTarget(summary, forking: forking) else {
      return
    }
    let folder = OpenSessions.shared.ownerFolder(forCwd: cwd)
    show(.project(folder: folder), attaching: [target])
  }

  /// The project window for `next`: the one already open on that folder, brought forward
  /// with the sessions attached (this picker window closing), or this window becoming it.
  private func show(_ next: WindowRoute, attaching targets: [ResumeTarget]) {
    guard case .project(let folder) = next else { return }
    if let owner = OpenSessions.shared.projects.values.first(where: {
      ProjectPath.normalize($0.folder.path(percentEncoded: false)) == folder
    }) {
      for target in targets { owner.attach(target) }
      owner.workspace.window?.makeKeyAndOrderFront(nil)
      if let current = route { dismissWindow(value: current) }
      return
    }
    for target in targets { OpenSessions.shared.requestAttach(target, in: folder) }
    route = next
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
  /// project with a new session and sends it a first prompt with no clicks.
  /// `-drakar.debugResume <session id>` attaches one from the index instead.
  /// `-drakar.debugModel <id>` picks a cheap model for the new session, and
  /// `-drakar.debugSettingSources project` keeps the user's own permission rules and hooks
  /// out of one that needs a permission prompt to appear. `-drakar.debugOpen <path>`,
  /// `-drakar.debugQuickOpen <query>` and `-drakar.debugSearch <query>` drive the editor.
  /// Values, not flags: UserDefaults reads a value starting with `-` as the next key.
  /// Debug builds only.
  private func openFromLaunchArguments() {
    #if DEBUG
      let defaults = UserDefaults.standard
      guard project == nil, route?.folder == nil else { return }
      let prompt = defaults.string(forKey: "drakar.debugPrompt")
      if let id = defaults.string(forKey: "drakar.debugResume") {
        Task {
          let summaries = await Task.detached {
            SessionIndex.list(accounts: ClaudeAccount.discover())
          }.value
          guard let summary = summaries.first(where: { $0.sessionID == id }) else { return }
          pick(summary, forking: false)
          if let prompt { project?.selected?.session.send(prompt) }
        }
        return
      }
      guard let path = defaults.string(forKey: "drakar.debugFolder") else { return }
      route = .project(URL(filePath: path, directoryHint: .isDirectory))
      open(route)  // now, not on the next update: the rest needs the project
      guard let project, let item = project.selected else { return }
      item.session.command = ClaudeCommand(
        model: defaults.string(forKey: "drakar.debugModel"),
        extraArguments: defaults.string(forKey: "drakar.debugSettingSources").map {
          ["--setting-sources", $0]
        } ?? [])
      let workspace = project.workspace
      if let file = defaults.string(forKey: "drakar.debugOpen") {
        workspace.open(URL(filePath: file, relativeTo: project.folder))
      }
      if let query = defaults.string(forKey: "drakar.debugQuickOpen") {
        workspace.showQuickOpen(query: query)
      }
      if let query = defaults.string(forKey: "drakar.debugSearch") {
        workspace.showSearch(query: query)
      }
      if let prompt {
        item.session.send(prompt, context: workspace.active.map { [$0.selection] } ?? [])
      }
    #endif
  }
}

/// Floats the window a view is in above other apps' windows, or puts it back among them.
/// Applied again once the view lands in a window, since a restored window has its level
/// asked for before it has one.
private struct WindowLevel: NSViewRepresentable {
  let floats: Bool

  func makeNSView(context: Context) -> LevelView { LevelView() }
  func updateNSView(_ view: LevelView, context: Context) { view.floats = floats }

  final class LevelView: NSView {
    var floats = false {
      didSet { apply() }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      apply()
    }

    private func apply() { window?.level = floats ? .floating : .normal }
  }
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
