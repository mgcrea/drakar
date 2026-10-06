import AppKit
import DrakarKit

/// Rename… on a session row and in the Session menu: asks for the name over the current
/// one, and says so when the session could not take it.
enum RenameSessionPrompt {
  @MainActor static func run(for item: ProjectSession) {
    let current = item.displayTitle
    let alert = NSAlert()
    alert.messageText = String(localized: "Rename Session")
    alert.informativeText = String(
      localized: "Claude Code shows the new name too, in its list of sessions to resume.")
    alert.addButton(withTitle: String(localized: "Rename"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    let field = NSTextField(string: current)
    field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
    field.lineBreakMode = .byTruncatingTail
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    // Left empty or unchanged: nothing to do, and nothing to complain about.
    guard alert.runModal() == .alertFirstButtonReturn, field.stringValue != current,
      SessionTitle.clean(field.stringValue) != nil
    else { return }
    guard !item.session.rename(to: field.stringValue) else { return }
    let failure = NSAlert()
    failure.messageText = String(localized: "“\(current)” could not be renamed.")
    failure.informativeText = String(
      localized: "Another app may have it open now, or its transcript cannot be written.")
    failure.runModal()
  }
}
