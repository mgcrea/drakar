import AppKit
import DrakarKit

/// A session's row menu > Show in VS Code: the window the session runs in brought forward,
/// with its tab shown. Nothing is typed there: the extension drops a prompt for a session
/// already open, and a session waiting on the person always is.
@MainActor
enum ShowInVSCode {
  static let bundleID = "com.microsoft.VSCode"

  /// Started by the Claude Code extension. Whether VS Code itself runs it, rather than a
  /// fork with its own link scheme, is only known on a click.
  static func canShow(_ summary: SessionSummary) -> Bool {
    summary.live?.entrypoint == "claude-vscode"
  }

  static func show(_ summary: SessionSummary) {
    guard let (app, folder) = window(of: summary), let appURL = app.bundleURL,
      let link = VSCodeWindow.link(sessionID: summary.sessionID)
    else { return notFound(summary) }
    // Opening the folder brings its window forward rather than opening another; only then
    // does the link, which VS Code hands to its front window, reach the right one.
    NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: activating()) {
      _, error in
      Task { @MainActor in
        guard error == nil else { return notFound(summary) }
        await frontmost(app)
        NSWorkspace.shared.open(
          [link], withApplicationAt: appURL, configuration: activating(), completionHandler: nil)
      }
    }
  }

  private static func activating() -> NSWorkspace.OpenConfiguration {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    return configuration
  }

  /// VS Code, and the folder of the window whose extension host started the session's
  /// `claude`: the host is its parent, VS Code the host's.
  private static func window(of summary: SessionSummary) -> (NSRunningApplication, URL)? {
    guard let pid = summary.live?.pid, let host = ProcessAncestry.parent(of: pid),
      let main = ProcessAncestry.parent(of: host),
      let app = NSRunningApplication(processIdentifier: main), app.bundleIdentifier == bundleID
    else { return nil }
    let directories = [
      IDELockFile.directory(for: summary.account),
      FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".claude/ide", directoryHint: .isDirectory),
    ]
    guard
      let folder = VSCodeWindow.folder(
        listeningOn: ProcessAncestry.listeningPorts(of: host), in: directories)
    else { return nil }
    return (app, URL(filePath: folder, directoryHint: .isDirectory))
  }

  /// Until `app` is in front, for two seconds at most, and a moment more for its window.
  private static func frontmost(_ app: NSRunningApplication) async {
    for _ in 0..<20 where NSWorkspace.shared.frontmostApplication != app {
      try? await Task.sleep(for: .milliseconds(100))
    }
    try? await Task.sleep(for: .milliseconds(400))
  }

  private static func notFound(_ summary: SessionSummary) {
    let alert = NSAlert()
    alert.messageText = String(
      localized: "Drakar can’t find the VS Code window “\(summary.displayTitle)” runs in.")
    alert.informativeText = String(
      localized: "It may run in another editor built on VS Code, which this doesn’t reach.")
    alert.runModal()
  }
}
