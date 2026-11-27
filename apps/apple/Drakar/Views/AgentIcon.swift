import AppKit
import SwiftUI

struct AgentIcon: View {
  let agent: AgentKind

  var body: some View {
    Image("agent-\(agent.rawValue)")
      .symbolRenderingMode(.monochrome)
  }
}

struct AgentAppIcon: View {
  let agent: AgentKind
  @ScaledMetric(relativeTo: .caption) private var size = 16.0
  @MainActor private static var icons: [AgentKind: NSImage] = [:]

  @MainActor private var installedIcon: NSImage? {
    if let icon = Self.icons[agent] { return icon }
    let bundleID: String
    switch agent {
    case .claude: bundleID = "com.anthropic.claudefordesktop"
    case .codex: bundleID = "com.openai.codex"
    case .agy, .grok: return nil
    }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else { return nil }
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    Self.icons[agent] = icon
    return icon
  }

  var body: some View {
    Group {
      if let installedIcon {
        Image(nsImage: installedIcon)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      } else {
        AgentIcon(agent: agent)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}
