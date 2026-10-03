import DrakarKit
import SwiftUI
import UniformTypeIdentifiers

/// Every session on the Mac, newest first, across every Claude Code account: the ones the
/// extension and the terminal started too, since they all write the same transcripts.
struct SessionsView: View {
  let open: (SessionRoute) -> Void

  @State private var sessions: [SessionSummary] = []
  @State private var isLoading = true
  @State private var query = ""
  @State private var choosingFolder = false
  /// A session open in another process, waiting for the choice to fork it.
  @State private var openElsewhere: SessionSummary?
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if isLoading && sessions.isEmpty {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if filtered.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? "No sessions yet" : "No matching sessions",
          systemImage: "bubble.left.and.text.bubble.right",
          description: Text(
            query.isEmpty ? "Open a folder to start one." : "Try another word."))
      } else {
        List(filtered) { summary in
          SessionRow(
            summary: summary, showsAccount: showsAccounts,
            isOpenHere: OpenSessions.shared.routes[summary.sessionID] != nil
          )
          .contentShape(Rectangle())
          .onTapGesture(count: 2) { resume(summary) }
          .contextMenu { menu(for: summary) }
          .accessibilityElement(children: .combine)
          .accessibilityAction { resume(summary) }
          .accessibilityAddTraits(.isButton)
          .accessibilityIdentifier("sessions.row.\(summary.sessionID)")
        }
        .listStyle(.inset)
        .accessibilityIdentifier("sessions.list")
      }
    }
    .searchable(text: $query, placement: .toolbar, prompt: "Search sessions")
    .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
      if case .success(let folder) = result { open(.new(folder: folder)) }
    }
    .task { await load() }
    .confirmationDialog(
      "This session is open in \(openElsewhere.map(Self.host) ?? "")",
      isPresented: Binding(get: { openElsewhere != nil }, set: { if !$0 { openElsewhere = nil } }),
      presenting: openElsewhere
    ) { summary in
      Button("Fork a Copy") {
        if let route = SessionRoute.resume(summary, forking: true) { open(route) }
      }
      .accessibilityIdentifier("sessions.fork")
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text(
        "Two apps writing to one session would interleave its history. Drakar can continue a copy under a new id, leaving the original where it is."
      )
    }
  }

  /// Where a live session is open, in words.
  static func host(_ summary: SessionSummary) -> String {
    switch summary.live?.entrypoint {
    case "claude-vscode": String(localized: "VS Code")
    case "cli": String(localized: "a terminal")
    case "claude-desktop": String(localized: "the Claude app")
    default: String(localized: "another app")
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "sailboat")
        .font(.title2)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text("Sessions").font(.title3.weight(.semibold))
        Text("Double-click one to resume it, or open a folder to start a new one.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
        .labelStyle(.iconOnly)
        .keyboardShortcut("r")
      Button("Open Folder…") { choosingFolder = true }
        .keyboardShortcut("o")
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("sessions.openFolder")
    }
    .padding(16)
  }

  private var filtered: [SessionSummary] {
    guard !query.isEmpty else { return sessions }
    return sessions.filter {
      $0.displayTitle.localizedCaseInsensitiveContains(query)
        || ($0.cwd?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }

  private var showsAccounts: Bool { Set(sessions.map(\.account)).count > 1 }

  @ViewBuilder private func menu(for summary: SessionSummary) -> some View {
    Button("Resume") { resume(summary) }
    if summary.live == nil, let route = SessionRoute.resume(summary) {
      Button("Resume in New Window") { openWindow(value: route) }
    }
    if summary.live != nil, OpenSessions.shared.routes[summary.sessionID] == nil,
      let route = SessionRoute.resume(summary, forking: true)
    {
      Button("Fork a Copy") { open(route) }
    }
    if let cwd = summary.cwd {
      Button("New Session in \(URL(filePath: cwd).lastPathComponent)") {
        open(.new(folder: URL(filePath: cwd, directoryHint: .isDirectory)))
      }
    }
    Divider()
    Button("Show Transcript in Finder") {
      NSWorkspace.shared.activateFileViewerSelecting([summary.file])
    }
  }

  /// In this window, unless it is open already: in another Drakar window, that window
  /// comes forward; anywhere else, the choice is a fork or nothing.
  private func resume(_ summary: SessionSummary) {
    if let route = OpenSessions.shared.routes[summary.sessionID] {
      openWindow(value: route)
    } else if summary.live != nil {
      openElsewhere = summary
    } else if let route = SessionRoute.resume(summary) {
      open(route)
    }
  }

  private func load() async {
    isLoading = true
    let extra =
      (await ClaudeSession.environment.value)["CLAUDE_CONFIG_DIR"].map {
        [URL(filePath: $0, directoryHint: .isDirectory)]
      } ?? []
    sessions = await Task.detached {
      SessionIndex.list(accounts: ClaudeAccount.discover(extra: extra))
    }.value
    isLoading = false
  }
}

private struct SessionRow: View {
  let summary: SessionSummary
  let showsAccount: Bool
  let isOpenHere: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(summary.displayTitle)
        .lineLimit(1)
        .foregroundStyle(summary.title == nil ? .secondary : .primary)
      HStack(spacing: 6) {
        if let cwd = summary.cwd {
          Label(URL(filePath: cwd).lastPathComponent, systemImage: "folder")
            .help(ContentView.abbreviated(URL(filePath: cwd)))
        } else {
          Label("Unknown folder", systemImage: "questionmark.folder")
        }
        Text(summary.modified, format: .relative(presentation: .named))
        if isOpenHere {
          Label("Open in Drakar", systemImage: "macwindow")
            .foregroundStyle(.blue)
        } else if summary.live != nil {
          Label("Live in \(SessionsView.host(summary))", systemImage: "circle.fill")
            .foregroundStyle(.green)

        }
        if showsAccount {
          Text(summary.account.name)
            .padding(.horizontal, 5)
            .background(.quaternary, in: Capsule())
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 3)
  }
}
