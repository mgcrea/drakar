import DrakarKit
import SwiftUI

/// ⌘P: a few letters of a file's name, then Return.
struct QuickOpenView: View {
  let workspace: Workspace
  @State private var query = ""
  @State private var matches: [QuickOpen.Match] = []
  @State private var selected = 0
  @FocusState private var isFocused: Bool
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      TextField("Open a file by name", text: $query)
        .textFieldStyle(.plain)
        .font(.title3)
        .padding(12)
        .focused($isFocused)
        .onSubmit(open)
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.escape) {
          dismiss()
          return .handled
        }
        .accessibilityIdentifier("quickOpen.field")
      Divider()
      ScrollViewReader { proxy in
        List {
          ForEach(Array(matches.enumerated()), id: \.element.path) { index, match in
            Button {
              selected = index
              open()
            } label: {
              MatchRow(match: match, isSelected: index == selected)
            }
            .buttonStyle(.plain)
            .listRowBackground(index == selected ? Theme.accent.opacity(0.25) : Color.clear)
            .id(index)
            .accessibilityIdentifier("quickOpen.match.\(match.path)")
          }
        }
        .listStyle(.plain)
        .onChange(of: selected) { proxy.scrollTo(selected) }
      }
      if workspace.quickOpenFiles == nil {
        ProgressView().controlSize(.small).padding(8)
      }
    }
    .frame(width: 560, height: 380)
    .onAppear {
      query = workspace.quickOpenQuery
      isFocused = true
    }
    .onChange(of: query, initial: true) { search() }
    .onChange(of: workspace.quickOpenFiles) { search() }
  }

  private func search() {
    matches = QuickOpen.search(query, in: workspace.quickOpenFiles ?? [])
    selected = 0
  }

  private func move(_ step: Int) -> KeyPress.Result {
    guard !matches.isEmpty else { return .ignored }
    selected = min(max(selected + step, 0), matches.count - 1)
    return .handled
  }

  private func open() {
    guard matches.indices.contains(selected) else { return }
    workspace.open(URL(filePath: workspace.tree.root + "/" + matches[selected].path))
    dismiss()
  }
}

private struct MatchRow: View {
  let match: QuickOpen.Match
  let isSelected: Bool

  var body: some View {
    let name = (match.path as NSString).lastPathComponent
    let folder = (match.path as NSString).deletingLastPathComponent
    HStack(spacing: 8) {
      Image(systemName: "doc.text").foregroundStyle(.secondary)
      Text(highlighted(name, offset: match.path.count - name.count))
      Text(folder)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.head)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
  }

  /// The name with the letters that matched in bold.
  private func highlighted(_ name: String, offset: Int) -> AttributedString {
    var text = AttributedString()
    for (index, character) in name.enumerated() {
      var piece = AttributedString(String(character))
      if match.positions.contains(index + offset) { piece.font = .body.bold() }
      text += piece
    }
    return text
  }
}
