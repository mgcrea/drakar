import DrakarKit
import SwiftUI

/// Where the prompt is written. Return sends, Option-Return starts a new line. While a turn
/// runs, Stop ends it, and what is typed is queued: sent now, taken when the CLI can.
///
/// A `/` at the start opens the commands it lists, narrowed as the name is typed: ↑ and ↓
/// move, Return or Tab writes the name in, Esc closes the list until the draft changes.
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
  /// What the `/` menu offers: the skills and the CLI's own commands.
  var commands: [SkillEntry] = []
  /// A command picked in the menu, for the caller to write into the draft.
  var pickCommand: (SkillEntry) -> Void = { _ in }
  /// The images and files going with the next prompt, shown as chips above the field.
  var attachments: [Attachment] = []
  /// Why the last things offered were not all attached.
  var attachmentNote: String? = nil
  var removeAttachment: (Attachment) -> Void = { _ in }
  /// Files or an image to attach: pasted, or picked with the paperclip.
  var attach: ([AttachmentSource]) -> Void = { _ in }

  @State private var leavesContextOut = false
  /// The menu's row under the keyboard.
  @State private var highlighted = 0
  /// The draft the menu was closed on with Esc; it opens again once the draft changes.
  @State private var menuClosedOn: String?
  @State private var pasteMonitor = PasteMonitor()
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
        if !attachments.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(attachments) { attachment in
                AttachmentChip(preview: attachment.preview) { removeAttachment(attachment) }
              }
            }
          }
          .accessibilityIdentifier("composer.attachments")
        }
        if let attachmentNote {
          Label(attachmentNote, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("composer.attachmentNote")
        }
        if !menu.isEmpty {
          CommandMenu(commands: menu, highlighted: highlighted, pick: choose)
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
    .onChange(of: text) { highlighted = 0 }
    // ⌘V with files or a screenshot on the clipboard attaches them; text pastes as usual.
    .onAppear { pasteMonitor.install(attach) }
    .onDisappear { pasteMonitor.remove() }
    .onChange(of: isFocused, initial: true) { _, focused in pasteMonitor.isActive = focused }
  }

  /// The commands the draft's `/name` matches, while the field has the keys.
  private var menu: [SkillEntry] {
    guard isFocused, menuClosedOn != text, let query = SlashCommand.query(in: text) else {
      return []
    }
    return SlashCommand.matches(query, in: commands)
  }

  private func choose(_ command: SkillEntry) {
    pickCommand(command)
    highlighted = 0
  }

  private func moveHighlight(_ step: Int) -> KeyPress.Result {
    let count = menu.count
    guard count > 0 else { return .ignored }
    highlighted = (highlighted + step + count) % count
    return .handled
  }

  private var hasText: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Something to send: text, or attachments alone.
  private var hasContent: Bool { hasText || !attachments.isEmpty }

  private static let radius: CGFloat = 12

  /// The live selection, unless it is pinned already.
  private var live: EditorSelection? {
    guard let context, !pinned.contains(context) else { return nil }
    return context
  }

  private var field: some View {
    TextField(
      isRunning && canSend ? "Queue another message…" : "Ask Claude to do something…", text: $text,
      axis: .vertical
    )
    .textFieldStyle(.plain)
    .lineLimit(1...10)
    .focused($isFocused)
    .onSubmit(submit)
    .onKeyPress(.upArrow) { moveHighlight(-1) }
    .onKeyPress(.downArrow) { moveHighlight(1) }
    .onKeyPress(.escape) {
      guard !menu.isEmpty else { return .ignored }
      menuClosedOn = text
      return .handled
    }
    // ⇧Tab arrives as backtab: the next mode. Plain Tab writes the menu's pick in, else is
    // left to focus traversal.
    .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
      if press.modifiers.contains(.shift) || press.key == KeyEquivalent("\u{19}") {
        guard let cycleMode else { return .ignored }
        cycleMode()
        return .handled
      }
      let menu = menu
      guard menu.indices.contains(highlighted) else { return .ignored }
      choose(menu[highlighted])
      return .handled
    }
    .accessibilityIdentifier("composer.field")
  }

  /// The model on the left; the mode and Send on the right, as the extension lays them out.
  private var toolbar: some View {
    HStack(spacing: 4) {
      if let pills { pills.model }
      Button("Attach", systemImage: "paperclip") { attach(AttachmentIntake.choose()) }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Attach images or files (or paste, or drop them on the session)")
        .accessibilityIdentifier("composer.attach")
      Spacer(minLength: 8)
      if let pills { pills.mode }
      button
    }
    .padding(.leading, 6)
    .padding(.trailing, 6)
    .padding(.vertical, 6)
  }

  @ViewBuilder private var button: some View {
    HStack(spacing: 4) {
      if isRunning {
        Button("Stop", systemImage: "stop.fill", action: stop)
          .keyboardShortcut(".", modifiers: .command)
          .help("Stop the turn and what is queued (⌘.)")
          .accessibilityIdentifier("composer.stop")
      }
      // While a turn runs, only once something is typed: it is queued behind the turn.
      if !isRunning || hasContent {
        Button("Send", systemImage: "arrow.up", action: submit)
          .disabled(!canSend || !hasContent)
          .help(isRunning ? "Queue (Return)" : "Send (Return)")
          .accessibilityIdentifier("composer.send")
      }
    }
    .labelStyle(.iconOnly)
    .buttonStyle(SendButtonStyle())
  }

  private func submit() {
    // Return on the menu writes the command in rather than sending the half-typed name.
    let menu = menu
    if menu.indices.contains(highlighted) { return choose(menu[highlighted]) }
    guard canSend, hasContent else { return }
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

/// The `/` menu over the field: each command's name, what it takes, and what it does.
private struct CommandMenu: View {
  let commands: [SkillEntry]
  let highlighted: Int
  let pick: (SkillEntry) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
            row(command, isHighlighted: index == highlighted)
              .id(command.id)
          }
        }
      }
      .frame(maxHeight: 240)
      .fixedSize(horizontal: false, vertical: true)
      .onChange(of: highlighted) { _, index in
        guard commands.indices.contains(index) else { return }
        proxy.scrollTo(commands[index].id)
      }
    }
    .accessibilityIdentifier("composer.commands")
  }

  private func row(_ command: SkillEntry, isHighlighted: Bool) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 6) {
        Text("/\(command.name)").font(.callout.monospaced().weight(.medium))
        if command.takesArguments {
          Text(command.argumentHint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      if !command.description.isEmpty {
        Text(command.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isHighlighted ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
      in: RoundedRectangle(cornerRadius: 6)
    )
    .contentShape(Rectangle())
    .onTapGesture { pick(command) }
    .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    .accessibilityIdentifier("composer.command.\(command.name)")
  }
}

/// An image's thumbnail, or a document's name, with × to take it off.
private struct AttachmentChip: View {
  let preview: AttachmentPreview
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      AttachmentBadge(preview: preview, size: 28)
      Button("Remove", systemImage: "xmark.circle.fill", action: remove)
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help("Don't send this")
    }
    .padding(3)
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
  }
}

/// While the composer has the keys, ⌘V with something to attach on the clipboard attaches
/// it instead of reaching the text field, which would paste nothing or the files' names.
@MainActor final class PasteMonitor {
  var isActive = false
  private var monitor: Any?

  func install(_ attach: @escaping ([AttachmentSource]) -> Void) {
    remove()
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.isActive,
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
        event.charactersIgnoringModifiers == "v",
        let sources = AttachmentIntake.sources(in: .general)
      else { return event }
      attach(sources)
      return nil
    }
  }

  func remove() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
}
