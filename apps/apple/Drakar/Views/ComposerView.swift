import DrakarKit
import SwiftUI

/// Where the prompt is written. Return sends, Option-Return starts a new line; while a
/// turn runs, the button stops it.
///
/// The editor's open file or selection goes with the prompt, as the extension's
/// `attachOpenFile` does by default; a click on it leaves it out of this one.
struct ComposerView: View {
  let canSend: Bool
  let isRunning: Bool
  let context: EditorSelection?
  /// A reference to put into the text (⌥K in the editor), then report as done.
  let mention: String?
  let mentionInserted: () -> Void
  let send: (String, EditorSelection?) -> Void
  let stop: () -> Void

  @State private var text = ""
  @State private var leavesContextOut = false
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let context {
        ContextChip(label: context.label, isIncluded: !leavesContextOut) {
          leavesContextOut.toggle()
        }
      }
      field
    }
    .padding(12)
    .onAppear { isFocused = true }
    // A new selection is attached again, whatever happened to the last one.
    .onChange(of: context) { leavesContextOut = false }
    .onChange(of: mention, initial: true) { _, mention in
      guard let mention else { return }
      let separator = text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " "
      text += separator + mention + " "
      isFocused = true
      mentionInserted()
    }
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
    send(text, leavesContextOut ? nil : context)
    text = ""
  }
}

private struct ContextChip: View {
  let label: String
  let isIncluded: Bool
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      Label(label, systemImage: isIncluded ? "doc.text" : "eye.slash")
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
