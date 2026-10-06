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
  /// Focused on appearing, unless the sidebar keeps the keys.
  var takesFocus = true
  /// What the skill at the start of the draft takes, shown above the field: a
  /// `TextField`'s placeholder only shows while it is empty.
  var hint: String? = nil
  /// A change asks for the focus: the inspector put a skill in the draft.
  var focusRequest = 0
  /// Called when the field takes the keys.
  var focused: () -> Void = {}
  /// The session's model and mode, on the toolbar under the field.
  var pills: SessionPills? = nil
  /// ⇧Tab in the field: the next permission mode.
  var cycleMode: (() -> Void)? = nil

  @State private var leavesContextOut = false
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        if let hint {
          Label(hint, systemImage: "text.cursor")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help("What this skill takes after its name")
            .accessibilityIdentifier("composer.hint")
        }
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
      .padding(.horizontal, 12)
      .padding(.top, 10)
      .padding(.bottom, 8)
      // A click anywhere above the toolbar types, as in the extension's box.
      .contentShape(Rectangle())
      .onTapGesture { isFocused = true }
      Divider().padding(.horizontal, 1)
      toolbar
    }
    // A card floating over the transcript's end, in its column: glass, so what scrolls under
    // it stays in sight, outlined in the accent while it has the keys.
    .glassEffect(.regular, in: .rect(cornerRadius: Self.radius))
    .overlay {
      RoundedRectangle(cornerRadius: Self.radius)
        .strokeBorder(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator))
    }
    .animation(.easeOut(duration: 0.12), value: isFocused)
    .frame(maxWidth: 820 - 32)
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
    .frame(maxWidth: .infinity)
    .onAppear { if takesFocus { isFocused = true } }
    .onChange(of: focusRequest) { isFocused = true }
    .onChange(of: isFocused) { _, focused in if focused { self.focused() } }
    // A new selection is attached again, whatever happened to the last one.
    .onChange(of: context) { leavesContextOut = false }
  }

  private static let radius: CGFloat = 12

  /// The live selection, unless it is pinned already.
  private var live: EditorSelection? {
    guard let context, !pinned.contains(context) else { return nil }
    return context
  }

  private var field: some View {
    TextField("Ask Claude to do something…", text: $text, axis: .vertical)
      .textFieldStyle(.plain)
      .lineLimit(1...10)
      .focused($isFocused)
      .onSubmit(submit)
      // ⇧Tab arrives as backtab; plain Tab is left to focus traversal.
      .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
        guard press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}"),
          let cycleMode
        else { return .ignored }
        cycleMode()
        return .handled
      }
      .accessibilityIdentifier("composer.field")
  }

  /// The model on the left; the mode and Send on the right, as the extension lays them out.
  private var toolbar: some View {
    HStack(spacing: 4) {
      if let pills { pills.model }
      Spacer(minLength: 8)
      if let pills { pills.mode }
      button
    }
    .padding(.leading, 6)
    .padding(.trailing, 6)
    .padding(.vertical, 6)
  }

  @ViewBuilder private var button: some View {
    Group {
      if isRunning {
        Button("Stop", systemImage: "stop.fill", action: stop)
          .keyboardShortcut(".", modifiers: .command)
          .help("Stop the turn (⌘.)")
          .accessibilityIdentifier("composer.stop")
      } else {
        Button("Send", systemImage: "arrow.up", action: submit)
          .disabled(!canSend || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .help("Send (Return)")
          .accessibilityIdentifier("composer.send")
      }
    }
    .labelStyle(.iconOnly)
    .buttonStyle(SendButtonStyle())
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

/// Send and Stop: a square in the accent, as the extension's, lighter under the pointer and
/// grey while there is nothing to send.
private struct SendButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    SendButton(configuration: configuration)
  }

  private struct SendButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
      configuration.label
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
        .frame(width: 26, height: 26)
        .background(
          isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
          in: RoundedRectangle(cornerRadius: 7)
        )
        .brightness(isEnabled && isHovered ? 0.08 : 0)
        .opacity(configuration.isPressed ? 0.75 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
  }
}
