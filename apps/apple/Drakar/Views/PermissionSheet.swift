import DrakarKit
import SwiftUI

/// "May Claude run this?" with the CLI's own "always allow" suggestions as extra buttons,
/// which is how the extension's "don't ask again" works.
struct PermissionSheet: View {
  let pending: Transcript.PendingPermission
  let answer: (PermissionDecision) -> Void

  private var request: PermissionRequest { pending.request }

  /// An edit shown as the diffs it would make, one per file; a Write is diffed against the
  /// file as it is now, read once when the sheet appears.
  @State private var changes: [FileChange] = []

  private var isEdit: Bool { !changes.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(
        isEdit
          ? "Apply this change?" : "Allow \(request.displayName ?? request.toolName)?"
      )
      .font(.title3.weight(.semibold))
      if let description = request.description, !description.isEmpty {
        Text(description)
      }
      if isEdit {
        ForEach(changes, id: \.path) { change in
          FileChangeView(change: change)
        }
      } else {
        CodeBlock(text: request.summary.isEmpty ? request.input.prettyPrinted : request.summary)
      }
      if !isEdit, let path = request.blockedPath {
        Label(path, systemImage: "folder")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if !request.parsedSuggestions.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(request.parsedSuggestions) { suggestion in
            Button(Self.title(suggestion, for: request)) {
              answer(.allow(updatedInput: request.input, updatedPermissions: [suggestion.raw]))
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("permission.suggestion.\(suggestion.id)")
          }
        }
      }
      HStack {
        Spacer()
        Button(isEdit ? "Reject" : "Deny") { answer(.deny(message: "The user denied this.")) }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("permission.deny")
        Button(isEdit ? "Accept" : "Allow") { answer(.allow(updatedInput: request.input)) }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("permission.allow")
      }
    }
    .padding(20)
    .frame(width: isEdit ? 680 : 460)
    .interactiveDismissDisabled()
    .task(id: pending.requestID) { changes = Self.changes(for: request) }
  }

  /// One change per file: a Codex patch can touch several. Claude's calls touch one, and a
  /// Write is diffed against the file on disk.
  static func changes(for request: PermissionRequest) -> [FileChange] {
    guard case .fileChange(let path, let edits) = request.kind else { return [] }
    guard Set(edits.map(\.path)).count <= 1 else { return FileChange.each(edits: edits) }
    var existing: String?
    if edits.contains(where: { if case .write = $0.change { true } else { false } }) {
      let url = URL(filePath: path)
      // A diff against a huge file is unreadable anyway; past 1 MB it shows as a new file.
      if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000 {
        existing = try? String(contentsOf: url, encoding: .utf8)
      }
    }
    return [FileChange(path: path, edits: edits, existing: existing)].compactMap { $0 }
  }

  /// A suggestion's button label. Codex's own wording names what its session-long yes covers.
  static func title(_ suggestion: PermissionSuggestion, for request: PermissionRequest) -> String {
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
    case .codexDecision:
      return request.toolName == "Shell"
        ? String(localized: "Allow, and don't ask again for this command")
        : String(localized: "Allow, and don't ask again for these files")
    case .other(let type):
      return String(localized: "Allow (\(type)) \(scope)")
    }
  }
}
