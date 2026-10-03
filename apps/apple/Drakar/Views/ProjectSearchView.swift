import DrakarKit
import SwiftUI

/// ⇧⌘F: text across the folder's files, each hit opening its file with the match
/// selected.
struct ProjectSearchView: View {
  let workspace: Workspace
  @State private var query = ""
  @State private var hits: [ProjectSearch.Hit] = []
  @State private var isSearching = false
  @State private var search: Task<Void, Never>?
  @FocusState private var isFocused: Bool
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search in \(workspace.folder.lastPathComponent)", text: $query)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($isFocused)
          .onKeyPress(.escape) {
            dismiss()
            return .handled
          }
          .accessibilityIdentifier("search.field")
        if isSearching { ProgressView().controlSize(.small) }
      }
      .padding(12)
      Divider()
      List {
        ForEach(groups, id: \.path) { group in
          Section(group.path) {
            ForEach(group.hits) { hit in
              Button {
                workspace.open(
                  URL(filePath: workspace.tree.root + "/" + hit.path), select: hit.range)
                dismiss()
              } label: {
                HitRow(hit: hit)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("search.hit.\(hit.path):\(hit.line)")
            }
          }
        }
      }
      .listStyle(.plain)
      Divider()
      Text(summary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
    .frame(width: 640, height: 460)
    .onAppear {
      query = workspace.searchQuery
      isFocused = true
    }
    .onChange(of: query, initial: true) { start() }
    .onDisappear { search?.cancel() }
  }

  private var groups: [(path: String, hits: [ProjectSearch.Hit])] {
    var order: [String] = []
    var byPath: [String: [ProjectSearch.Hit]] = [:]
    for hit in hits {
      if byPath[hit.path] == nil { order.append(hit.path) }
      byPath[hit.path, default: []].append(hit)
    }
    return order.map { ($0, byPath[$0] ?? []) }
  }

  private var summary: String {
    if query.isEmpty { return String(localized: "Smart case: a capital letter matches case.") }
    if isSearching { return String(localized: "Searching…") }
    let files = Set(hits.map(\.path)).count
    let capped =
      hits.count >= ProjectSearch.maximumHits ? String(localized: " (stopped there)") : ""
    return String(
      AttributedString(
        localized: "^[\(hits.count) result](inflect: true) in ^[\(files) file](inflect: true)"
      ).characters) + capped
  }

  /// A quarter second after the last keystroke, off the main thread, abandoned when the
  /// query changes again.
  private func start() {
    search?.cancel()
    let query = query
    let root = workspace.folder
    guard !query.isEmpty else {
      hits = []
      isSearching = false
      return
    }
    isSearching = true
    search = Task {
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      let found = await Task.detached {
        let files = QuickOpen.files(under: root)
        return ProjectSearch.search(query, in: files, under: root) { Task.isCancelled }
      }.value
      guard !Task.isCancelled else { return }
      hits = found
      isSearching = false
    }
  }
}

private struct HitRow: View {
  let hit: ProjectSearch.Hit

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(String(hit.line))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 36, alignment: .trailing)
      Text(highlighted)
        .font(.callout.monospaced())
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
  }

  private var highlighted: AttributedString {
    let preview = hit.preview as NSString
    let range = NSRange(location: hit.previewRange.lowerBound, length: hit.previewRange.count)
    guard NSMaxRange(range) <= preview.length else { return AttributedString(hit.preview) }
    var text = AttributedString(preview.substring(to: range.location))
    var match = AttributedString(preview.substring(with: range))
    match.backgroundColor = .yellow.opacity(0.35)
    match.font = .callout.monospaced().bold()
    text += match
    text += AttributedString(preview.substring(from: NSMaxRange(range)))
    return text
  }
}
