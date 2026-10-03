import SwiftUI

/// Where the prompt is written. Return sends, Option-Return starts a new line; while a
/// turn runs, the button stops it.
struct ComposerView: View {
  let canSend: Bool
  let isRunning: Bool
  let send: (String) -> Void
  let stop: () -> Void

  @State private var text = ""
  @FocusState private var isFocused: Bool

  var body: some View {
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
    .padding(12)
    .onAppear { isFocused = true }
  }

  private func submit() {
    guard canSend else { return }
    send(text)
    text = ""
  }
}
