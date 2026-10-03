import AmiralKit
import SwiftUI

/// "May Claude run this?" with the CLI's own "always allow" suggestions as extra buttons,
/// which is how the extension's "don't ask again" works.
struct PermissionSheet: View {
  let pending: Transcript.PendingPermission
  let answer: (PermissionDecision) -> Void

  private var request: PermissionRequest { pending.request }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Allow \(request.displayName ?? request.toolName)?")
        .font(.title3.weight(.semibold))
      if let description = request.description, !description.isEmpty {
        Text(description)
      }
      CodeBlock(text: request.summary.isEmpty ? request.input.prettyPrinted : request.summary)
      if let path = request.blockedPath {
        Label(path, systemImage: "folder")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if !request.parsedSuggestions.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(request.parsedSuggestions) { suggestion in
            Button(Self.title(suggestion)) {
              answer(.allow(updatedInput: request.input, updatedPermissions: [suggestion.raw]))
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("permission.suggestion.\(suggestion.id)")
          }
        }
      }
      HStack {
        Spacer()
        Button("Deny") { answer(.deny(message: "The user denied this.")) }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("permission.deny")
        Button("Allow") { answer(.allow(updatedInput: request.input)) }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("permission.allow")
      }
    }
    .padding(20)
    .frame(width: 460)
    .interactiveDismissDisabled()
  }

  private static func title(_ suggestion: PermissionSuggestion) -> String {
    let scope =
      suggestion.isPersistent
      ? String(localized: "from now on") : String(localized: "for this session")
    switch suggestion.kind {
    case .addRules(let rules):
      return String(localized: "Always allow \(rules.joined(separator: ", ")) \(scope)")
    case .addDirectories(let directories):
      let names = directories.map { URL(filePath: $0).lastPathComponent }.joined(separator: ", ")
      return String(localized: "Allow access to \(names) \(scope)")
    case .setMode("acceptEdits"):
      return String(localized: "Accept all edits \(scope)")
    case .setMode(let mode):
      return String(localized: "Switch to \(mode) mode \(scope)")
    case .other(let type):
      return String(localized: "Allow (\(type)) \(scope)")
    }
  }
}
