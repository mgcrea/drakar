import AppKit
import SupportKitUI
import SwiftUI

@main
struct DrakarApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate

  var body: some Scene {
    // One window per session, keyed by its route: a window opened without one shows the
    // session list, and SwiftUI reopens each session's window at the next launch.
    WindowGroup(for: SessionRoute.self) { $route in
      ContentView(route: $route)
    }
    .commands {
      SupportCommands(app: Support.app, preferIssueTracker: Support.preferIssueTracker)
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

/// Starts the editor bridge at launch and takes its lock files down at quit: a lock left
/// behind beside a live one stops `claude --ide` from connecting to either.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    IDEBridge.shared.start()
  }

  func applicationWillTerminate(_ notification: Notification) {
    IDEBridge.shared.stop()
  }

  /// Quitting with unsaved tabs in any window asks first, once for all of them.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let workspaces = Workspace.all.filter { !$0.unsavedDocuments.isEmpty }
    guard !workspaces.isEmpty else { return .terminateNow }
    switch UnsavedChanges.choice(
      UnsavedChanges.alert(for: workspaces.flatMap(\.unsavedDocuments)).runModal())
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

/// The extension's two shortcuts: ⌥K puts `@file#L3-5` into the prompt being written here,
/// ⌘⌥K into a terminal `claude`'s.
private struct MentionCommands: View {
  @FocusedValue(\.workspace) private var workspace

  var body: some View {
    Divider()
    Button("Mention in Prompt") { workspace?.mentionInComposer() }
      .keyboardShortcut("k", modifiers: .option)
      .disabled(workspace?.active == nil)
    Button("Mention in Terminal Session") {
      if workspace?.mentionInTerminal() != true { NSSound.beep() }
    }
    .keyboardShortcut("k", modifiers: [.command, .option])
    .disabled(workspace?.active == nil)
  }
}
