import AppKit
import DrakarKit
import SupportKitUI
import SwiftUI
import UserNotifications

@main
struct DrakarApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate

  var body: some Scene {
    // One window per project, keyed by its route: a window opened without one shows the
    // session picker, and SwiftUI reopens each project's window at the next launch.
    WindowGroup(for: WindowRoute.self) { $route in
      ContentView(route: $route)
        .themed()
    }
    .commands {
      SupportCommands(app: Support.app, preferIssueTracker: Support.preferIssueTracker)
      CommandGroup(replacing: .newItem) { NewWindowCommand() }
      CommandMenu("Session") { SessionCommands() }
      // Replacing the save group takes File > Close with it, so both closes come back here.
      CommandGroup(replacing: .saveItem) {
        CloseCommands()
        SaveCommand()
      }
      CommandGroup(after: .textEditing) { MentionCommands() }
      CommandGroup(after: .sidebar) {
        FilesCommand()
        InspectorCommand()
        EditorSideCommand()
      }
      // ⌘P, as in VS Code and Zed: Drakar prints nothing.
      CommandGroup(replacing: .printItem) { QuickOpenCommand() }
      CommandGroup(before: .windowList) { SkillsCommand() }
    }

    // A real Settings scene: Drakar is a windowed app with a Dock icon and menus, unlike
    // the fleet's three other Developer ID apps, which are LSUIElement agents and have to
    // open their settings through HostedWindow instead.
    Settings {
      SettingsView()
        .themed()
    }

    // The Skills window: one for the app, opened from Window › Skills or the inspector's
    // Manage…, on the project of the window it came from. Its own menu item is replaced by
    // `SkillsCommand`, which knows that project; it is not reopened at launch.
    Window("Skills", id: SkillsManager.windowID) {
      SkillsWindow(manager: .shared)
        .themed()
    }
    .defaultSize(width: 1040, height: 640)
    .restorationBehavior(.disabled)
    .commandsRemoved()
  }
}

/// File > New Tab (⌘T) and New Window (⇧⌘N) open home; ⌘N belongs to New Session.
/// Open Project… (⌘O) tracks a folder and opens it in a new tab; Close Project (⇧⌘H)
/// goes back to home in this window.
private struct NewWindowCommand: View {
  @Environment(\.openWindow) private var openWindow
  @FocusedValue(\.closeProject) private var closeProject

  var body: some View {
    Button("New Tab") {
      WindowTabs.openWindow = WindowTabs.openWindow ?? openWindow
      WindowTabs.open(.picker(), asTab: true)
    }
    .keyboardShortcut("t")
    Button("New Window") { openWindow(value: WindowRoute.picker()) }
      .keyboardShortcut("n", modifiers: [.command, .shift])
    Divider()
    Button("Open Project…") { openProject() }
      .keyboardShortcut("o")
    Button("Close Project") { closeProject?() }
      .keyboardShortcut("h", modifiers: [.command, .shift])
      .disabled(closeProject == nil)
  }

  private func openProject() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = String(localized: "Open")
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    ProjectList.shared.track(folder)
    WindowTabs.openWindow = WindowTabs.openWindow ?? openWindow
    WindowTabs.open(.project(folder), asTab: NSApp.keyWindow != nil)
  }
}

/// View › Hide Files (⇧⌘E, VS Code's Explorer key): folds the focused window's file tree
/// away, or brings it back.
private struct FilesCommand: View {
  @FocusedBinding(\.filesCollapsed) private var filesCollapsed

  var body: some View {
    Button(filesCollapsed == true ? "Show Files" : "Hide Files") {
      withAnimation(.snappy(duration: 0.2)) { filesCollapsed?.toggle() }
    }
    .keyboardShortcut("e", modifiers: [.command, .shift])
    .disabled(filesCollapsed == nil)
  }
}

/// View › Move Editor to the Left (⌥⌘E): the editor's side of the session, in every window,
/// as Settings › General › Files open sets it.
private struct EditorSideCommand: View {
  @AppStorage(PreferenceKey.editorLeads) private var editorLeads = false

  var body: some View {
    Button(editorLeads ? "Move Editor to the Right" : "Move Editor to the Left") {
      editorLeads.toggle()
    }
    .keyboardShortcut("e", modifiers: [.command, .option])
  }
}

/// View › Show Inspector (⌥⌘0, the inspector key of Xcode and Finder): the focused window's
/// skills and MCP servers.
private struct InspectorCommand: View {
  @FocusedBinding(\.inspectorShown) private var inspectorShown

  var body: some View {
    Button(inspectorShown == true ? "Hide Inspector" : "Show Inspector") {
      inspectorShown?.toggle()
    }
    .keyboardShortcut("0", modifiers: [.command, .option])
    .disabled(inspectorShown == nil)
  }
}

/// The Session menu: what acts on the focused project's sessions.
private struct SessionCommands: View {
  @FocusedValue(\.project) private var project
  @AppStorage(PreferenceKey.defaultAgent) private var defaultAgentRaw = AgentKind.claude.rawValue
  private var otherAgent: AgentKind { (AgentKind(rawValue: defaultAgentRaw) ?? .claude).other }

  var body: some View {
    Button("New Session") { project?.newSession() }
      .keyboardShortcut("n")
      .disabled(project == nil)
    Button("New \(otherAgent.name) Session") {
      project?.newSession(agent: otherAgent)
    }
    .keyboardShortcut("n", modifiers: [.command, .control])
    .disabled(project == nil)
    ForkSessionCommand(project: project)
    OpenPlanCommand(project: project)
    Button("Run Skill in Subfolders…") { project?.fanOutRequest = FanOutRequest() }
      .disabled(project == nil)
    Button("Rename Session…") {
      if let selected = project?.selected { RenameSessionPrompt.run(for: selected) }
    }
    .disabled(project?.canRenameSelected != true)
    // From anywhere in the window, the composer included, which keeps the arrow keys.
    Button("Previous Session") { project?.step(-1, wrapping: true) }
      .keyboardShortcut(.upArrow, modifiers: [.command, .option])
      .disabled(project == nil)
    Button("Next Session") { project?.step(1, wrapping: true) }
      .keyboardShortcut(.downArrow, modifiers: [.command, .option])
      .disabled(project == nil)
    Button("Next Session Needing You") {
      if let project, let next = project.nextNeedingAttention() { project.show(next) }
    }
    .keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
    .disabled(project?.nextNeedingAttention() == nil)
    // A reply to the shown session goes on to the next one wanting the person.
    Toggle(
      "Next After Replying",
      isOn: Binding(
        get: { project?.movesOnAfterReply ?? false },
        set: { project?.movesOnAfterReply = $0 })
    )
    .disabled(project == nil)
    // The sidebar's own ⌘A needs the list focused, and a click on a row gives the composer the
    // keys, where ⌘A selects the draft: this one reaches the marks from anywhere.
    Button("Mark All Sessions") { project?.markAll() }
      .keyboardShortcut("a", modifiers: [.command, .option])
      .disabled(project == nil)
    Button("Dismiss") { project?.dismissSelected() }
      .keyboardShortcut("d", modifiers: [.command, .option, .shift])
      .disabled(project?.canDismissSelected != true)
    AnswerCommands(project: project)
  }
}

/// Session > Answer Yes (⌥⌘Y) and Answer No (⌥⌘N), apart so that only they redraw as the
/// shown session's transcript streams.
private struct AnswerCommands: View {
  let project: Project?

  var body: some View {
    let answerable = project?.yesOrNoSelected != nil
    Button("Answer Yes") { project?.answerYesSelected() }
      .keyboardShortcut("y", modifiers: [.command, .option])
      .disabled(!answerable)
    Button("Answer No") { project?.answerNoSelected() }
      .keyboardShortcut("n", modifiers: [.command, .option])
      .disabled(!answerable)
  }
}

/// Session > Fork Session (⇧⌘D), apart so that only it redraws as the shown session's
/// transcript streams.
private struct ForkSessionCommand: View {
  let project: Project?

  var body: some View {
    Button("Fork Session") { project?.forkSelected() }
      .keyboardShortcut("d", modifiers: [.command, .shift])
      .disabled(project?.canForkSelected != true)
  }
}

/// Session > Open Plan (⌥⌘P), apart for `ForkSessionCommand`'s reason.
private struct OpenPlanCommand: View {
  let project: Project?

  var body: some View {
    Button("Open Plan") {
      guard let project else { return }
      Task { await project.openPlanSelected() }
    }
    .keyboardShortcut("p", modifiers: [.command, .option])
    .disabled(project?.canOpenPlanSelected != true)
  }
}

/// Starts the editor bridge at launch, through the licence gate, and takes its lock files
/// down at quit: a lock left behind beside a live one stops `claude --ide` from connecting
/// to either.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Before any view reads `Changelog.hasUnseen`, or a fresh install draws the
    // What's New count on its very first launch.
    Changelog.markSeenIfUnset()
    // Starts the editor bridge when entitled, as armada starts its watchers here; while
    // nothing is sold that is always, exactly as before the gate.
    EntitlementMonitor.shared.apply()
    // Set at launch, not at the first post: a click on a notification delivered before a
    // relaunch must still land. Setting it does not prompt.
    UNUserNotificationCenter.current().delegate = Attention.shared
    Task { await SessionMonitor.shared.start() }
    Task { await AccountStore.shared.start() }
    Task { await HeldWindows.shared.list(from: .shared) }
    // Builds nothing unless the person has said yes, and nothing at all in a development
    // build (`UpdateController.isDevelopmentBuild`). DIVERGES from armada, which has no
    // hosted tests: the test host runs under the app's bundle id, and so would find the
    // owner's own yes and start checking from inside a test run.
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
      UpdateController.shared.startIfConsented()
    }
  }

  /// Every window's sessions are stopped, not left to the windows closing: a `claude` must
  /// not outlive the app that was working with it, unless the session host keeps it at work
  /// for the next launch.
  func applicationWillTerminate(_ notification: Notification) {
    AppLifecycle.isTerminating = true
    // Before the sessions stop: the windows on screen, for a launch macOS restores none.
    if ReopenedWindows.isEnabled { ReopenedWindows.shared.record() }
    for project in OpenSessions.shared.projects.values { project.stopAll() }
    // What the stops asked of the host goes before the app does.
    SessionHost.shared.flush()
    IDEBridge.shared.stop()
  }

  /// Quitting with unsaved tabs in any window asks first, once for all of them.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Not when the app hosts the tests: their tabs are not the user's, and the quit that
    // reaches the host is usually `make run` relaunching Drakar from another checkout.
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
      return .terminateNow
    }
    let workspaces = Workspace.all.filter { !$0.unsavedDocuments.isEmpty }
    // The session host keeps its sessions working: only the app's own children stop.
    let running = OpenSessions.shared.stoppedByQuitting
    if workspaces.isEmpty {
      guard running > 0 else { return .terminateNow }
      return RunningSessions.alert(count: running, action: .quit).runModal()
        == .alertFirstButtonReturn
        ? .terminateNow : .terminateCancel
    }
    let alert = UnsavedChanges.alert(for: workspaces.flatMap(\.unsavedDocuments))
    if running > 0 {
      alert.informativeText += "\n\n" + RunningSessions.note(count: running, action: .quit)
    }
    switch UnsavedChanges.choice(alert.runModal())
    {
    case .save:
      for workspace in workspaces { workspace.saveAll() }
      return workspaces.allSatisfy { $0.unsavedDocuments.isEmpty }
        ? .terminateNow : .terminateCancel
    case .discard: return .terminateNow
    case .cancel: return .terminateCancel
    }
  }
}

/// File > Save: the focused window's active tab.
private struct SaveCommand: View {
  @FocusedValue(\.workspace) private var workspace

  var body: some View {
    Button("Save") {
      if let workspace, let document = workspace.active { workspace.save(document) }
    }
    .keyboardShortcut("s")
    .disabled(workspace?.active?.isDirty != true)
  }
}

/// File > Open Quickly: a file of the focused window's folder, by name.
private struct QuickOpenCommand: View {
  @FocusedValue(\.workspace) private var workspace

  var body: some View {
    Button("Open Quickly…") { workspace?.showQuickOpen() }
      .keyboardShortcut("p")
      .disabled(workspace == nil)
    Button("Search in Folder…") { workspace?.showSearch() }
      .keyboardShortcut("f", modifiers: [.command, .shift])
      .disabled(workspace == nil)
  }
}

/// Window › Skills: the Skills window, on the focused window's project.
private struct SkillsCommand: View {
  @Environment(\.openWindow) private var openWindow
  @FocusedValue(\.project) private var project

  var body: some View {
    Button("Skills") {
      SkillsManager.shared.show(project: project?.folder) { openWindow(id: $0) }
    }
    Divider()
  }
}

/// ⌘W closes the active tab, then the window once no tab is left, as in Xcode and VS Code;
/// ⇧⌘W closes the window whatever it holds. Both go through the questions about unsaved
/// work: the tab's, and the window's guard.
private struct CloseCommands: View {
  @FocusedValue(\.workspace) private var workspace

  var body: some View {
    Button(workspace?.active == nil ? "Close" : "Close Tab") {
      if let workspace, let document = workspace.active {
        workspace.requestClose(document)
      } else {
        NSApp.keyWindow?.performClose(nil)
      }
    }
    .keyboardShortcut("w")
    Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
      .keyboardShortcut("w", modifiers: [.command, .shift])
  }
}

/// ⌥K keeps the selection for the next prompt here, beside the live one; ⌘⌥K, as in the
/// extension, puts a reference to it into a terminal `claude`'s prompt.
private struct MentionCommands: View {
  @FocusedValue(\.workspace) private var workspace

  private var title: String {
    guard let workspace else { return String(localized: "Mention in Terminal Session") }
    let connected = IDEBridge.shared.connectedPIDs
    let summary = SessionMonitor.shared.connectedSession(
      under: workspace.folder.path(percentEncoded: false))
    return MentionTitle.make(connected: connected, session: summary)
  }

  var body: some View {
    Divider()
    Button("Pin Selection to Prompt") { workspace?.pinSelection() }
      .keyboardShortcut("k", modifiers: .option)
      .disabled(workspace?.active == nil)
    Button(title) {
      guard let workspace, !workspace.mentionInTerminal() else { return }
      workspace.problem = String(
        localized:
          "No Claude Code in a terminal is connected to Drakar. Run claude --ide in \(workspace.folder.lastPathComponent), or /ide in a running session, then try again."
      )
    }
    .keyboardShortcut("k", modifiers: [.command, .option])
    .disabled(workspace?.active == nil)
  }
}

/// Helper to compute the ⌘⌥K menu item title.
struct MentionTitle {
  /// Shows session name only when exactly one terminal is connected and it's this session's.
  nonisolated static func make(connected: Set<Int32>, session: SessionSummary?) -> String {
    guard let session else { return String(localized: "Mention in Terminal Session") }
    // Show session name only when exactly one terminal is connected and it's this session's
    guard connected.count == 1, let pid = session.live?.pid, connected.contains(pid) else {
      return String(localized: "Mention in Terminal Session")
    }
    return String(localized: "Mention in \u{201C}\(session.displayTitle)\u{201D}")
  }
}

/// The project windows of the processes the session host holds for no app (those a quit
/// handed over at work, an idle one being forgotten once it ends), opened at launch
/// whether or not windows reopen (spec §3 Relaunch): each window then takes its processes
/// back (`Project.adoptHeld`). Opened once a first window is up, so that it is the one
/// `ReopenedWindows` begins with, and none of those it reopens is opened twice.
@MainActor final class HeldWindows {
  static let shared = HeldWindows()
  private let open: (WindowRoute) -> Void
  /// Listed, and not opened yet.
  private var folders: [String]?
  private var hasWindow = false
  private var isDone = false

  init(open: @escaping (WindowRoute) -> Void = { WindowTabs.open($0, asTab: false) }) {
    self.open = open
  }

  /// Asks the host what it holds, once at launch, without starting one.
  func list(from host: SessionHost) async {
    folders = Self.folders(of: await host.heldIfRunning())
    openIfReady()
  }

  /// A window is up, and has asked for the windows to reopen.
  func windowAppeared() {
    hasWindow = true
    openIfReady()
  }

  private func openIfReady() {
    guard hasWindow, !isDone, let folders else { return }
    isDone = true
    let shown = OpenSessions.shared.folders
    for folder in folders
    where !shown.contains(folder) && !ReopenedWindows.shared.willReopen(folder) {
      open(.project(folder: folder))
    }
  }

  /// The windows the processes no app is attached to belong to, each once.
  static func folders(of held: [HeldProcess]) -> [String] {
    var seen: Set<String> = []
    return held.compactMap { process in
      guard process.attachedApp == nil,
        let meta = try? JSONDecoder().decode(SessionMeta.self, from: process.meta)
      else { return nil }
      let folder = ProjectPath.normalize(meta.windowFolder)
      return seen.insert(folder).inserted ? folder : nil
    }
  }
}
