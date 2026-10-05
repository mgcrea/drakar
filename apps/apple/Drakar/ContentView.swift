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
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow
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
            // The split view's own edge is half a point to aim at.
            .background(SidebarSash())
        } detail: {
          SplitPanes(fraction: $editorFraction, showsLeading: !workspace.documents.isEmpty) {
            EditorView(workspace: workspace)
          } trailing: {
            SelectedSessionPane(project: project)
          }
        }
        // The window's closing, not this view's disappearing, stops the sessions: the editor
        // appearing with the first open file must not take the running ones with it.
        .background(
          WindowReader { window in
            workspace.window = window
            WindowCloseGuard.install(
              on: window, for: workspace, running: { [weak project] in project?.runningCount ?? 0 })
            if let next = ReopenedWindows.shared.arrived(window, folder: project.folder) {
              WindowTabs.open(next, asTab: false)
            }
          }
        )
        // The dot in the close button, as in every document window.
        .onChange(of: workspace.unsavedDocuments.isEmpty, initial: true) { _, clean in
          workspace.window?.isDocumentEdited = !clean
        }
        .focusedSceneValue(\.workspace, workspace)
        .focusedSceneValue(\.project, project)
        .focusedSceneValue(\.closeProject, closeProject)
        .sheet(isPresented: quickOpenShown(workspace)) { QuickOpenView(workspace: workspace) }
        .sheet(isPresented: searchShown(workspace)) { ProjectSearchView(workspace: workspace) }
        .onChange(of: appearsActive, initial: true) { _, active in
          if active { workspace.becameActive() }
        }
        .background(
          StoredProjectWriter(project: project) { stored in
            storedProject =
              (try? String(decoding: JSONEncoder().encode(stored), as: UTF8.self)) ?? ""
            ProjectMemory.remember(stored, for: project.folder)
          })
      } else {
        HomeView(pick: pick, enter: enter)
      }
    }
    .frame(minWidth: 680, minHeight: 440)
    .toolbar {
      if let project {
        ToolbarItem(placement: .navigation) {
          Button("Projects", systemImage: "square.grid.2x2") { closeProject() }
            .help("Close this project and go back to the projects (⇧⌘H)")
            .accessibilityIdentifier("window.closeProject")
        }
        ToolbarItem(placement: .primaryAction) {
          AccountToolbarItem(folder: project.folder)
        }
      }
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
    .background(WindowReader { WindowTabs.adopt($0) })
    .onAppear { WindowTabs.openWindow = openWindow }
    // The folder's name over its path, as the Files pane writes it. The path is shortened
    // because the title bar does not truncate: a long subtitle widened the detail column
    // past the window and pushed the sidebar off its leading edge.
    .navigationTitle(project?.folder.lastPathComponent ?? String(localized: "Projects"))
    .navigationSubtitle(project.map { Self.shortened($0.folder) } ?? "")
    .onChange(of: route, initial: true) { open(route) }
    .onDisappear {
      // The window is gone: no session outlives it.
      project?.stopAll()
      OpenSessions.shared.unregister(window: windowID)
    }
    .task {
      if ReopenedWindows.isEnabled, !Self.isDebugLaunch,
        let first = ReopenedWindows.shared.begin(launchRoute: route)
      {
        route = first
      }
      openFromLaunchArguments()
    }
  }

  /// Launched with a debug argument that opens its own project: nothing is reopened.
  private static var isDebugLaunch: Bool {
    #if DEBUG
      ["drakar.debugFolder", "drakar.debugResume"].contains {
        UserDefaults.standard.string(forKey: $0) != nil
      }
    #else
      false
    #endif
  }

  private func quickOpenShown(_ workspace: Workspace) -> Binding<Bool> {
    Binding(get: { workspace.isQuickOpenShown }, set: { workspace.isQuickOpenShown = $0 })
  }

  private func searchShown(_ workspace: Workspace) -> Binding<Bool> {
    Binding(get: { workspace.isSearchShown }, set: { workspace.isSearchShown = $0 })
  }

  /// The project for `route`, restored the first time from scene storage, or from what the
  /// app remembers of the folder when the window comes back without it.
  private func open(_ route: WindowRoute?) {
    guard let folder = route?.folder else { return }
    ProjectList.shared.track(folder)
    if project?.folder.standardizedFileURL != folder.standardizedFileURL {
      let stored =
        (try? JSONDecoder().decode(StoredProject.self, from: Data(storedProject.utf8)))
        ?? ProjectMemory.stored(for: folder)
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

  /// Back to home in this window: the questions a close asks (unsaved tabs, sessions mid-turn),
  /// then the project's sessions stop and the window shows the projects. Nothing reopens
  /// it but a click on home.
  private func closeProject() {
    guard let project else { return }
    let workspace = project.workspace
    let unsaved = workspace.unsavedDocuments
    let running = project.runningCount
    guard let window = workspace.window, !unsaved.isEmpty || running > 0 else {
      return leaveProject()
    }
    if unsaved.isEmpty {
      RunningSessions.alert(count: running, action: .closeProject).beginSheetModal(for: window) {
        if $0 == .alertFirstButtonReturn { leaveProject() }
      }
      return
    }
    let alert = UnsavedChanges.alert(for: unsaved)
    if running > 0 {
      alert.informativeText += "\n\n" + RunningSessions.note(count: running)
    }
    alert.beginSheetModal(for: window) { response in
      switch UnsavedChanges.choice(response) {
      case .save:
        workspace.saveAll()
        if workspace.unsavedDocuments.isEmpty { leaveProject() }
      case .discard: leaveProject()
      case .cancel: break
      }
    }
  }

  private func leaveProject() {
    project?.stopAll()
    project?.workspace.window?.isDocumentEdited = false
    OpenSessions.shared.unregister(window: windowID)
    // The next project this window opens must not restore this one's sessions.
    storedProject = ""
    project = nil
    route = .picker()
  }

  /// A project clicked on home: its open window comes forward, or this one becomes it.
  private func enter(_ folder: URL) {
    let path = ProjectPath.normalize(folder.path(percentEncoded: false))
    if let window = OpenSessions.shared.window(forFolder: path) {
      window.makeKeyAndOrderFront(nil)
      return
    }
    route = .project(folder)
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
  /// with the sessions attached, or with a new session when there are none to attach ("New
  /// Session in…"), this picker window closing; or this window becoming it.
  private func show(_ next: WindowRoute, attaching targets: [ResumeTarget]) {
    guard case .project(let folder) = next else { return }
    if let owner = OpenSessions.shared.projects.values.first(where: {
      ProjectPath.normalize($0.folder.path(percentEncoded: false)) == folder
    }) {
      if targets.isEmpty { owner.newSession() }
      for target in targets { owner.attach(target) }
      owner.workspace.window?.makeKeyAndOrderFront(nil)
      dismiss()  // this picker window, with or without a route
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
          open(route)  // now, not on the next update: the prompt needs the project
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
/// The selected session, or the way to start one. Its own view, so that a switch redraws
/// this pane alone and not the window's body.
///
/// A session whose history is still being read stays off screen until it is in, the last one
/// shown standing in: an empty transcript sits at the top, then jumps to the bottom when its
/// entries land, and the toolbar's scroll-edge blur went off and back on, a blink at every
/// switch.
private struct SelectedSessionPane: View {
  let project: Project
  @State private var shownID: ProjectSession.ID?

  var body: some View {
    Group {
      if let item = project.sessions.first(where: { $0.id == shownID }) ?? project.selected {
        SessionView(item: item, project: project).id(item.id)
      } else {
        ContentUnavailableView {
          Label("No session", systemImage: "bubble.left.and.text.bubble.right")
        } actions: {
          Button("New Session") { project.newSession() }
        }
      }
    }
    .task(id: project.selectedID) {
      guard let item = project.selected else { return shownID = nil }
      await item.session.loadHistory()
      if !Task.isCancelled { shownID = item.id }
    }
  }
}

/// Hands over what the window keeps of its project each time it changes. The selection is
/// part of it, so it is watched here rather than in `ContentView`, for the same reason as
/// `SelectedSessionPane`.
private struct StoredProjectWriter: View {
  let project: Project
  let write: (StoredProject) -> Void

  var body: some View {
    Color.clear.onChange(of: project.stored, initial: true) { _, stored in write(stored) }
  }
}

private struct WindowLevel: NSViewRepresentable {
  let floats: Bool

  func makeNSView(context: Context) -> LevelView { LevelView() }
  func updateNSView(_ view: LevelView, context: Context) { view.floats = floats }

  final class LevelView: NSView {
    /// Set on every update of the view: the level is only touched when it changes, since
    /// setting it orders the window again.
    var floats = false {
      didSet { if floats != oldValue { apply() } }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      apply()
    }

    private func apply() { window?.level = floats ? .floating : .normal }
  }
}

/// Windows opened as tabs of the key window.
@MainActor enum WindowTabs {
  /// The scene's action, handed over by the first window to appear: menus and rows open
  /// windows through it.
  static var openWindow: OpenWindowAction?
  /// The window the one being opened joins as a tab.
  private static weak var tabHost: NSWindow?
  /// The window `openWindow` built for `tabHost`, handed over by `adopt`.
  private static weak var opened: NSWindow?

  /// A window for `route`, as a tab of the key window when `asTab`. A project already
  /// open comes forward instead: one window per folder.
  static func open(_ route: WindowRoute, asTab: Bool) {
    if let folder = route.folder,
      let window = OpenSessions.shared.window(
        forFolder: ProjectPath.normalize(folder.path(percentEncoded: false)))
    {
      window.makeKeyAndOrderFront(nil)
      return
    }
    tabHost = asTab ? NSApp.keyWindow : nil
    openWindow?(value: route)
    // Joined only now: SwiftUI sizes the new window and cascades it from the key window
    // after its content is in it, still inside `openWindow`, and a window already in the
    // group takes the whole group to that size and place.
    if let host = tabHost, let window = opened { join(window, to: host) }
    tabHost = nil
    opened = nil
  }

  /// A Drakar window appeared: when `open` is building it as a tab, it is the one to join.
  static func adopt(_ window: NSWindow) {
    guard tabHost != nil, tabHost !== window else { return }
    opened = window
  }

  private static func join(_ window: NSWindow, to host: NSWindow) {
    if host.tabbedWindows?.contains(window) != true {
      // A tab group shows each tab at its own frame: a new window's default size would
      // resize the window the moment its tab is selected.
      window.setFrame(host.frame, display: false)
      host.addTabbedWindow(window, ordered: .above)
    }
    window.makeKeyAndOrderFront(nil)
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
