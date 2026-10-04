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
      CommandGroup(after: .sidebar) { FilesCommand() }
      // ⌘P, as in VS Code and Zed: Drakar prints nothing.
      CommandGroup(replacing: .printItem) { QuickOpenCommand() }
    }

    // A real Settings scene: Drakar is a windowed app with a Dock icon and menus, unlike
    // the fleet's three other Developer ID apps, which are LSUIElement agents and have to
    // open their settings through HostedWindow instead.
    Settings {
      SettingsView()
    }
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

/// The Session menu: what acts on the focused project's sessions.
private struct SessionCommands: View {
  @FocusedValue(\.project) private var project

  var body: some View {
    Button("New Session") { project?.newSession() }
      .keyboardShortcut("n")
      .disabled(project == nil)
    Button("Next Session Needing You") {
      if let project, let next = project.nextNeedingAttention() { project.select(next) }
    }
    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
    .disabled(project?.nextNeedingAttention() == nil)
    Button("Dismiss") {
      if let project, let item = project.selected { project.dismissAsk(item) }
    }
    .keyboardShortcut("d", modifiers: [.command, .option])
    .disabled(project?.selected?.closingAsk == nil)
  }
}

/// Starts the editor bridge at launch and takes its lock files down at quit: a lock left
/// behind beside a live one stops `claude --ide` from connecting to either.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    IDEBridge.shared.start()
    // Set at launch, not at the first post: a click on a notification delivered before a
    // relaunch must still land. Setting it does not prompt.
    UNUserNotificationCenter.current().delegate = Attention.shared
    Task { await SessionMonitor.shared.start() }
    Task { await AccountStore.shared.start() }
  }

  /// Every window's sessions are stopped, not left to the windows closing: a `claude` must
  /// not outlive the app that was working with it.
  func applicationWillTerminate(_ notification: Notification) {
    for project in OpenSessions.shared.projects.values { project.stopAll() }
    IDEBridge.shared.stop()
  }

  /// Quitting with unsaved tabs in any window asks first, once for all of them.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let workspaces = Workspace.all.filter { !$0.unsavedDocuments.isEmpty }
    let running = OpenSessions.shared.runningCount
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
