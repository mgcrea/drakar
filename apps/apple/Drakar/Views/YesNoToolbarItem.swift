import AppKit
import DrakarKit
import SwiftUI

/// Yes and No for the yes-or-no question the shown session ended on, beside Session > Answer
/// Yes (⌥⌘Y) and Answer No (⌥⌘N). Absent otherwise. A view of its own so that only it
/// redraws as the shown session's transcript streams, not the whole window.
struct YesNoToolbarItem: View {
  let project: Project

  var body: some View {
    if let ask = project.yesOrNoSelected {
      ControlGroup {
        Button("Yes", systemImage: "checkmark") { project.answerYesSelected() }
          .help(String(localized: "Answer Yes to “\(ask.text)” (⌥⌘Y)"))
          .accessibilityIdentifier("window.answerYes")
        Button("No", systemImage: "xmark") {
          project.answerNoSelected(bare: NSEvent.modifierFlags.contains(.option))
        }
        .help(
          String(
            localized:
              "Start a reply with No, to say what instead (⌥⌘N). Option-click sends just No."
          )
        )
        .accessibilityIdentifier("window.answerNo")
      }
    }
  }
}
