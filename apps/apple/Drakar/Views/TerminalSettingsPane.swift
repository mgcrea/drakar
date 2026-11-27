import SwiftTerm
import SwiftUI

enum TerminalDefaults {
  static let fontSize = 13
  static let scrollback = 500
  static let bell = "sound"
}

struct TerminalSettingsPane: View {
  @AppStorage(PreferenceKey.terminalFontSize) private var fontSize = TerminalDefaults.fontSize
  @AppStorage(PreferenceKey.terminalScrollback) private var scrollback = TerminalDefaults.scrollback
  @AppStorage(PreferenceKey.terminalBell) private var bell = TerminalDefaults.bell

  var body: some View {
    Form {
      Section {
        Stepper(value: $fontSize, in: 8...32) {
          LabeledContent("Font size", value: "\(fontSize) pt")
        }
        .accessibilityIdentifier("settings.terminalFontSize")
        Picker("Scrollback lines", selection: $scrollback) {
          ForEach([500, 1_000, 5_000, 10_000, 50_000], id: \.self) { lines in
            Text(lines.formatted()).tag(lines)
          }
        }
        .accessibilityIdentifier("settings.terminalScrollback")
        Picker("Terminal bell", selection: $bell) {
          Text("Off").tag(BellStyle.none.tagName)
          Text("Sound").tag(BellStyle.sound.tagName)
          Text("Flash").tag(BellStyle.visual.tagName)
          Text("Sound and flash").tag(BellStyle.soundAndVisual.tagName)
        }
        .accessibilityIdentifier("settings.terminalBell")
      }
    }
    .formStyle(.grouped)
  }
}
