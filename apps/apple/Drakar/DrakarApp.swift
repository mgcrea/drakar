import AppKit
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

/// File > New Window (⇧⌘N): a picker window. ⌘N belongs to New Session.
private struct NewWindowCommand: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("New Window") { openWindow(value: WindowRoute.picker()) }
      .keyboardShortcut("n", modifiers: [.command, .shift])
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
  }

  func applicationWillTerminate(_ notification: Notification) {
    IDEBridge.shared.stop()
  }

  /// Quitting with unsaved tabs in any window asks first, once for all of them.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let workspaces = Workspace.all.filter { !$0.unsavedDocuments.isEmpty }
    let running = OpenSessions.shared.runningCount
    if workspaces.isEmpty {
      guard running > 0 else { return .terminateNow }
      return RunningSessions.alert(count: running).runModal() == .alertFirstButtonReturn
        ? .terminateNow : .terminateCancel
    }
    let alert = UnsavedChanges.alert(for: workspaces.flatMap(\.unsavedDocuments))
    if running > 0 { alert.informativeText += "\n\n" + RunningSessions.note(count: running) }
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

  var body: some View {
    Divider()
    Button("Pin Selection to Prompt") { workspace?.pinSelection() }
      .keyboardShortcut("k", modifiers: .option)
      .disabled(workspace?.active == nil)
    Button("Mention in Terminal Session") {
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
