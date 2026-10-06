import AppKit
import DrakarKit

/// Moving a session another app runs into a project window: its process is ended, after
/// asking, and the session goes on here. Typing in that app again takes it back
/// (`OpenSessions.liveChanged`), which the question says.
enum MoveHere {
  @MainActor static func confirm(_ summary: SessionSummary, into project: Project) {
    let host = SessionMonitor.shared.host(of: summary, excluding: project)
    let alert = NSAlert()
    alert.messageText = String(localized: "Move this session to this window?")
    alert.informativeText = String(
      localized:
        "Claude Code in \(host) stops, and the conversation goes on here. Typing there again takes the session back, and this window stops writing to it."
    )
    alert.addButton(withTitle: String(localized: "Move Here"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    let move = {
      if !project.moveHere(summary) { failed(in: host, window: project.workspace.window) }
    }
    guard let window = project.workspace.window else {
      if alert.runModal() == .alertFirstButtonReturn { move() }
      return
    }
    alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { move() } }
  }

  /// The process started a turn since the menu was drawn, or is gone.
  @MainActor private static func failed(in host: String, window: NSWindow?) {
    let alert = NSAlert()
    alert.messageText = String(localized: "The session did not move")
    alert.informativeText = String(
      localized: "It is working in \(host), or no longer open there. Try again once its turn ends."
    )
    if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
  }
}
