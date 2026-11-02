import AppKit
import SwiftUI

/// Where the shown session can go, between a Mac and its runner (remote sessions spec §5):
/// Open on the Runner in a runner's window; Bring Back to the Mac that started it, or Take
/// Over Here a session a Mac owns, on the runner's own Drakar. Nil when none applies.
enum Handoff: Equatable {
  case openOnRunner
  case bringBack(to: String)
  case takeOver

  @MainActor init?(_ item: ProjectSession, in project: Project) {
    if project.canOpenOnRunner(item) {
      self = .openOnRunner
    } else if let origin = project.bringBackDestination(item) {
      self = .bringBack(to: origin)
    } else if project.canTakeOver(item) {
      self = .takeOver
    } else {
      return nil
    }
  }

  var title: String {
    switch self {
    case .openOnRunner: String(localized: "Open on the Runner")
    case .bringBack(let origin): String(localized: "Bring Back to \(origin)")
    case .takeOver: String(localized: "Take Over Here")
    }
  }

  var help: String {
    switch self {
    case .openOnRunner:
      String(localized: "Leave this session to Drakar on the runner, and close it here.")
    case .bringBack(let origin):
      String(localized: "Give this session back to Drakar on \(origin).")
    case .takeOver: String(localized: "Go on with this session in this window.")
    }
  }

  var systemImage: String {
    switch self {
    case .openOnRunner: "rectangle.portrait.and.arrow.right"
    case .bringBack: "arrow.uturn.backward"
    case .takeOver: "hand.raised"
    }
  }

  @MainActor func run(_ item: ProjectSession, in project: Project) {
    switch self {
    case .openOnRunner: project.openOnRunner(item)
    case .bringBack: project.bringBack(item)
    case .takeOver:
      Task {
        guard let refusal = await project.takeOver(item) else { return }
        let alert = NSAlert()
        alert.messageText = refusal
        alert.informativeText = String(
          localized:
            "Its Mac's Drakar has it open. It can be taken over here once that Mac lets it go or loses its connection."
        )
        if let window = project.workspace.window {
          alert.beginSheetModal(for: window) { _ in }
        } else {
          alert.runModal()
        }
      }
    }
  }
}

/// The Session menu's handoff item for the shown session, apart so that only it redraws as
/// that session changes.
struct HandoffCommand: View {
  let project: Project?

  var body: some View {
    if let project, let item = project.selected, let handoff = Handoff(item, in: project) {
      Divider()
      Button(handoff.title) { handoff.run(item, in: project) }
    }
  }
}

/// The same in the window's toolbar.
struct HandoffToolbarItem: View {
  let project: Project

  var body: some View {
    if let item = project.selected, let handoff = Handoff(item, in: project) {
      Button(handoff.title, systemImage: handoff.systemImage) { handoff.run(item, in: project) }
        .help(handoff.help)
        .accessibilityIdentifier("window.handoff")
    }
  }
}
