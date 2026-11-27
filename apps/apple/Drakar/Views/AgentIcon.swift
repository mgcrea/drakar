import AppKit
import SwiftUI

struct AgentIcon: View {
  let agent: AgentKind
  @ScaledMetric(relativeTo: .caption) private var iconSize = 14.0

  // ChatGPT ships this Codex artwork with the desktop app.
  private static let codexIcon: NSImage? = {
    guard
      let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
      let artwork = Bundle(url: app)?.url(forResource: "icon-codex-light", withExtension: "png")
    else { return nil }
    return NSImage(contentsOf: artwork)
  }()

  var body: some View {
    if agent == .codex, let icon = Self.codexIcon {
      Image(nsImage: icon)
        .resizable()
        .scaledToFit()
        .frame(width: iconSize, height: iconSize)
    } else {
      Image(systemName: agent.iconSymbol ?? "sun.max")
    }
  }
}
