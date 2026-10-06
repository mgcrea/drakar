import DrakarKit
import SwiftUI

/// Forks the shown session, beside Session > Fork Session (⇧⌘D). A view of its own so that
/// only it redraws as the shown session's transcript streams, not the whole window.
struct ForkToolbarButton: View {
  let project: Project

  var body: some View {
    let running = project.selected?.session.transcript.isRunning == true
    Button("Fork Session", systemImage: "arrow.triangle.branch") { project.forkSelected() }
      .disabled(!project.canForkSelected)
      .help(
        running
          ? String(localized: "Fork once this turn ends (⇧⌘D)")
          : String(localized: "Continue a copy under a new id, leaving the original as it is (⇧⌘D)")
      )
      .accessibilityIdentifier("window.fork")
  }
}
