import DrakarKit
import SwiftUI

/// Where the prompt is written. Return sends, Option-Return starts a new line; while a
/// turn runs, the button stops it.
///
/// The editor's open file or selection goes with the prompt, as the extension's
/// `attachOpenFile` does by default; a click on it leaves it out of this one. Selections
/// pinned with ⌥K go too, until a click takes one off.
struct ComposerView: View {
  @Binding var text: String
  let canSend: Bool
  let isRunning: Bool
  let context: EditorSelection?
  let pinned: [EditorSelection]
  let unpin: (EditorSelection) -> Void
  let send: (String, [EditorSelection]) -> Void
  let stop: () -> Void
  let sessionFolder: URL
  let projectFolder: URL

  @State private var leavesContextOut = false
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !pinned.isEmpty || live != nil {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(pinned, id: \.self) { selection in
              PinnedChip(
                label: selection.label,
                unpin: { unpin(selection) },
                note: Self.selectionNote(
                  selection, sessionFolder: sessionFolder, projectFolder: projectFolder))
            }
            if let live {
              ContextChip(
                label: live.label, isIncluded: !leavesContextOut,
                toggle: { leavesContextOut.toggle() },
                note: Self.selectionNote(
                  live, sessionFolder: sessionFolder, projectFolder: projectFolder))
            }
          }
        }
      }
      field
    }
    .padding(12)
    .onAppear { isFocused = true }
    // A new selection is attached again, whatever happened to the last one.
    .onChange(of: context) { leavesContextOut = false }
  }

  /// The live selection, unless it is pinned already.
  private var live: EditorSelection? {
    guard let context, !pinned.contains(context) else { return nil }
    return context
  }

  private var field: some View {
    HStack(alignment: .bottom, spacing: 8) {
      TextField("Ask Claude to do something…", text: $text, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...10)
        .focused($isFocused)
        .onSubmit(submit)
        .accessibilityIdentifier("composer.field")
      if isRunning {
        Button("Stop", systemImage: "stop.circle.fill", action: stop)
          .keyboardShortcut(".", modifiers: .command)
          .accessibilityIdentifier("composer.stop")
      } else {
        Button("Send", systemImage: "arrow.up.circle.fill", action: submit)
          .disabled(!canSend || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("composer.send")
      }
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .font(.body)
    .imageScale(.large)
  }

  private func submit() {
    guard canSend else { return }
    send(text, pinned + (leavesContextOut ? [] : live.map { [$0] } ?? []))
    text = ""
  }

  /// "from the main checkout" when the session runs in a worktree of the project and the
  /// selection is a file outside it: the session reads another copy. A session in a plain
  /// subfolder (`apps/apple`) reads the same files, and gets no note.
  static func selectionNote(
    _ selection: EditorSelection, sessionFolder: URL, projectFolder: URL
  ) -> String? {
    let session = ProjectPath.normalize(sessionFolder.path(percentEncoded: false))
    let project = ProjectPath.normalize(projectFolder.path(percentEncoded: false))
    guard session != project, isWorktree(session),
      !ProjectPath.contains(session, selection.filePath)
    else { return nil }
    return String(localized: "from the main checkout")
  }

  /// Claude Code's own worktree folder, or any folder whose `.git` is a file: a linked
  /// worktree points at its repository that way, where a checkout has a directory.
  static func isWorktree(_ folder: String) -> Bool {
    if folder.contains("/.claude/worktrees/") { return true }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: folder + "/.git", isDirectory: &isDirectory)
      && !isDirectory.boolValue
  }
}

private struct ContextChip: View {
  let label: String
  let isIncluded: Bool
  let toggle: () -> Void
  let note: String?

  var body: some View {
    Button(action: toggle) {
      Label(
        note.map { "\(label) · \($0)" } ?? label, systemImage: isIncluded ? "doc.text" : "eye.slash"
      )
      .font(.caption)
      .strikethrough(!isIncluded)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(.quaternary.opacity(isIncluded ? 0.8 : 0.3), in: Capsule())
    }
    .buttonStyle(.plain)
    .foregroundStyle(isIncluded ? .primary : .secondary)
    .help(
      isIncluded ? "Sent with the prompt. Click to leave it out." : "Left out. Click to send it."
    )
    .accessibilityIdentifier("composer.context")
  }
}

private struct PinnedChip: View {
  let label: String
  let unpin: () -> Void
  let note: String?

  var body: some View {
    Button(action: unpin) {
      Label(note.map { "\(label) · \($0)" } ?? label, systemImage: "pin.fill")
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.8), in: Capsule())
    }
    .buttonStyle(.plain)
    .help("Pinned with ⌥K, sent with the prompt. Click to unpin.")
    .accessibilityLabel("Pinned \(label)")
    .accessibilityIdentifier("composer.pinned.\(label)")
  }
}
