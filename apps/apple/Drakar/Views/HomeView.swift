import DrakarKit
import SwiftUI
import UniformTypeIdentifiers

/// Home: the projects the person tracks, how busy each is, and folders with recent sessions
/// to add. Searching also finds sessions, across every account and folder.
struct HomeView: View {
  /// A session picked: `forking` when it is open in another process.
  let pick: (SessionSummary, Bool) -> Void
  /// A project entered: this window becomes it, or its open window comes forward.
  let enter: (URL) -> Void

  @State private var query = ""
  @State private var choosingFolder = false
  @State private var showsAllSuggestions = false
  /// The order rows were last sorted in: kept while the list is on screen, so a row never
  /// moves under the pointer when a session writes.
  @State private var order: [String] = []
  /// A session open in another process, waiting for the choice to fork it.
  @State private var openElsewhere: SessionSummary?
  /// What the session host holds, read again whenever the registry changes: a window
  /// handing its sessions over, or one ending, changes it.
  @State private var held: [HeldProcess] = []

  private var monitor: SessionMonitor { .shared }
  private var list: ProjectList { .shared }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if !monitor.isLoaded {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if list.tracked.projects.isEmpty && suggestions.isEmpty && query.isEmpty {
        ContentUnavailableView {
          Label("Add a project to start", systemImage: "folder.badge.plus")
        } actions: {
          Button("Add Project…") { choosingFolder = true }
        }
      } else {
        content
      }
    }
    .searchable(text: $query, placement: .toolbar, prompt: "Search projects and sessions")
    .fileImporter(
      isPresented: $choosingFolder, allowedContentTypes: [.folder],
      allowsMultipleSelection: true
    ) { result in
      if case .success(let folders) = result { folders.forEach(list.track) }
    }
    .dropDestination(for: URL.self) { urls, _ in
      let folders = urls.filter(\.hasDirectoryPath)
      folders.forEach(list.track)
      return !folders.isEmpty
    }
    .onAppear { resort() }
    .task(id: monitor.liveSessions) { held = await SessionHost.shared.heldIfRunning() }
    .onChange(of: query) { resort() }
    .onChange(of: list.tracked.paths) { resort() }
    .onChange(of: monitor.isLoaded) { resort() }
    .confirmationDialog(
      "This session is open in \(openElsewhere.map { monitor.host(of: $0) } ?? "")",
      isPresented: Binding(get: { openElsewhere != nil }, set: { if !$0 { openElsewhere = nil } }),
      presenting: openElsewhere
    ) { summary in
      Button("Fork a Copy") { pick(summary, true) }
        .accessibilityIdentifier("sessions.fork")
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text(
        "Two apps writing to one session would interleave its history. Drakar can continue a copy under a new id, leaving the original where it is."
      )
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "sailboat")
        .font(.title2)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 2) {
        Text("Projects").font(.title3.weight(.semibold))
        Text("Click a project to open it, or add a folder to track.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Add Project…") { choosingFolder = true }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("home.addProject")
    }
    .padding(16)
  }

  private var content: some View {
    List {
      if !projects.isEmpty {
        Section("Projects") {
          ForEach(projects) { entry in
            Button {
              enter(entry.url)
            } label: {
              ProjectRow(
                entry: entry, stats: stats[entry.path] ?? ProjectStats(),
                own: own[entry.path] ?? (0, 0), background: background[entry.path] ?? 0,
                isOpen: openFolders.contains(entry.path))
            }
            .buttonStyle(.plain)
            .contextMenu { menu(for: entry) }
            .accessibilityIdentifier("home.project.\(entry.path)")
          }
        }
      } else if !query.isEmpty {
        Text("No matching projects").foregroundStyle(.secondary)
      }
      if !shownSuggestions.isEmpty {
        Section("Recent Folders") {
          ForEach(shownSuggestions) { suggestion in
            SuggestionRow(suggestion: suggestion) {
              list.track(URL(filePath: suggestion.path, directoryHint: .isDirectory))
            } hide: {
              list.hide(suggestion.path)
            }
          }
          if filteredSuggestions.count > 8 && !showsAllSuggestions {
            Button("Show All (\(filteredSuggestions.count))") { showsAllSuggestions = true }
              .buttonStyle(.link)
          }
        }
      }
      if !query.isEmpty {
        Section("Sessions") {
          if matchingSessions.isEmpty {
            Text("No matching sessions").foregroundStyle(.secondary)
          }
          ForEach(matchingSessions.prefix(100)) { summary in
            PickerRow(
              summary: summary, showsAccount: showsAccounts,
              isOpenHere: OpenSessions.shared.locate(summary.sessionID) != nil
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { resume(summary) }
            .contextMenu { menu(for: summary) }
            .accessibilityElement(children: .combine)
            .accessibilityAction { resume(summary) }
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("sessions.row.\(summary.sessionID)")
          }
        }
      }
    }
    .listStyle(.inset)
    .accessibilityIdentifier("home.list")
  }

  // MARK: Projects

  private var stats: [String: ProjectStats] {
    ProjectStats.compute(
      projects: list.tracked.paths, folders: monitor.folders, live: monitor.liveSessions,
      checkout: monitor.checkout(of:))
  }

  /// Drakar's own sessions waiting and running, by tracked project: the registry leaves
  /// Drakar's children out, so these come from its windows.
  private var own: [String: (waiting: Int, running: Int)] {
    let owners = ProjectPath.Owners(list.tracked.paths)
    var counts: [String: (waiting: Int, running: Int)] = [:]
    for project in OpenSessions.shared.projects.values {
      guard let owner = owners.owner(of: project.folder.path(percentEncoded: false)) else {
        continue
      }
      counts[owner, default: (0, 0)].waiting += project.waitingCount
      counts[owner, default: (0, 0)].running += project.runningCount
    }
    return counts
  }

  private var background: [String: Int] {
    BackgroundSessions.count(
      held: held, live: monitor.liveSessions, owners: ProjectPath.Owners(list.tracked.paths))
  }

  private var openFolders: Set<String> { Set(OpenSessions.shared.folders) }

  /// In the order last sorted; a project added since goes on top until the next sort.
  private var projects: [TrackedProjects.Entry] {
    let entries = list.tracked.projects.filter(matches)
    let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    return entries.sorted { (rank[$0.path] ?? -1, $0.path) < (rank[$1.path] ?? -1, $1.path) }
  }

  private func matches(_ entry: TrackedProjects.Entry) -> Bool {
    query.isEmpty || entry.path.localizedCaseInsensitiveContains(query)
  }

  private func resort() {
    order = list.tracked.ordered(by: stats).map(\.path)
  }

  @ViewBuilder private func menu(for entry: TrackedProjects.Entry) -> some View {
    Button("Open") { enter(entry.url) }
    Button("Open in New Tab") { WindowTabs.open(.project(entry.url), asTab: true) }
    Button("Open in New Window") { WindowTabs.open(.project(entry.url), asTab: false) }
    Divider()
    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    Button("Copy Path") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(entry.path, forType: .string)
    }
    Divider()
    Button("Remove from Projects") { list.remove(entry.path) }
  }

  // MARK: Suggestions

  private var suggestions: [FolderSuggestion] {
    FolderSuggestions.compute(
      folders: monitor.folders, tracked: list.tracked.paths, hidden: list.tracked.hidden,
      now: .now)
  }

  private var filteredSuggestions: [FolderSuggestion] {
    suggestions.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }
  }

  private var shownSuggestions: [FolderSuggestion] {
    showsAllSuggestions ? filteredSuggestions : Array(filteredSuggestions.prefix(8))
  }

  // MARK: Sessions

  private var matchingSessions: [SessionSummary] {
    monitor.all.filter {
      $0.displayTitle.localizedCaseInsensitiveContains(query)
        || ($0.cwd?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }

  private var showsAccounts: Bool { Set(monitor.all.map(\.account)).count > 1 }

  @ViewBuilder private func menu(for summary: SessionSummary) -> some View {
    Button("Resume") { resume(summary) }
    if summary.live != nil, OpenSessions.shared.locate(summary.sessionID) == nil {
      Button("Fork a Copy") { pick(summary, true) }
    }
    Divider()
    Button("Show Transcript in Finder") {
      NSWorkspace.shared.activateFileViewerSelecting([summary.file])
    }
  }

  /// In this window, unless it is open already: in another Drakar window, that window
  /// comes forward; anywhere else, the choice is a fork or nothing.
  private func resume(_ summary: SessionSummary) {
    if OpenSessions.shared.locate(summary.sessionID) != nil || summary.live == nil {
      pick(summary, false)
    } else {
      openElsewhere = summary
    }
  }
}

extension TrackedProjects.Entry {
  var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
}

/// A tracked project: its name and path, what wants the person, how many sessions it
/// has, when it was last worked in, and its newest session's context.
private struct ProjectRow: View {
  let entry: TrackedProjects.Entry
  let stats: ProjectStats
  let own: (waiting: Int, running: Int)
  /// Kept by the session host between turns, with no window showing them.
  let background: Int
  let isOpen: Bool

  private var monitor: SessionMonitor { .shared }

  private var exists: Bool { FileManager.default.fileExists(atPath: entry.path) }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: exists ? "folder.fill" : "questionmark.folder")
        .foregroundStyle(exists ? Theme.accent : .secondary)
        .font(.title3)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(entry.url.lastPathComponent).fontWeight(.medium)
          if isOpen {
            Text("Open")
              .font(.caption2)
              .padding(.horizontal, 5)
              .background(.quaternary, in: Capsule())
              .help("Open in a window: clicking brings it forward")
          }
        }
        Text(exists ? ContentView.abbreviated(entry.url) : String(localized: "Folder not found"))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      HStack(spacing: 12) {
        HStack(spacing: 4) {
          if waiting > 0 {
            count(
              waiting, symbol: "hand.raised.fill", tint: .blue,
              help: "Waiting for you: \(waiting)")
          }
          if running > 0 {
            count(
              running, symbol: "arrow.triangle.2.circlepath", tint: .green,
              help: "Running: \(running)")
          }
          if background > 0 {
            count(
              background, symbol: "tray.fill", tint: .gray,
              help:
                "In the background, no window showing them: \(background). Open the project to bring them back."
            )
          }
        }
        Text(
          stats.sessionCount == 0
            ? String(localized: "No sessions")
            : String(localized: "\(stats.sessionCount) sessions")
        )
        .foregroundStyle(.secondary)
        if let date = stats.lastActivity {
          Text(date, format: .relative(presentation: .named))
            .foregroundStyle(.secondary)
            .frame(minWidth: 70, alignment: .trailing)
        }
        Group {
          if let gauge { ContextGaugeView(gauge: gauge) } else { Color.clear }
        }
        .frame(width: 36)
      }
      .font(.callout.monospacedDigit())
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .opacity(exists ? 1 : 0.55)
    .task(id: stats.newest) {
      if let file = stats.newest, let account = stats.newestAccount {
        await monitor.load(file, account: account)
      }
    }
  }

  private var waiting: Int { stats.waiting + own.waiting }
  private var running: Int { stats.running + own.running }

  private var gauge: ContextGauge? {
    guard let file = stats.newest, let summary = monitor.summary(forFile: file) else {
      return nil
    }
    return ContextGauge.make(
      usage: summary.context?.usage, reportedLimit: nil, initModelID: nil,
      attachmentModelID: summary.modelID,
      accountModelID: monitor.accountModel(for: summary.account),
      messageModelID: summary.context?.modelID)
  }

  private func count(
    _ value: Int, symbol: String, tint: Color, help: LocalizedStringKey
  ) -> some View {
    HStack(spacing: 3) {
      Image(systemName: symbol).imageScale(.small)
      Text(value, format: .number)
    }
    .font(.caption.monospacedDigit().weight(.semibold))
    .foregroundStyle(.white)
    .padding(.horizontal, 6)
    .background(tint, in: Capsule())
    .help(help)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(help))
  }
}

/// A folder with recent sessions nobody tracks yet.
private struct SuggestionRow: View {
  let suggestion: FolderSuggestion
  let add: () -> Void
  let hide: () -> Void

  var body: some View {
    let url = URL(filePath: suggestion.path, directoryHint: .isDirectory)
    HStack(spacing: 10) {
      Image(systemName: "folder")
        .foregroundStyle(.secondary)
        .font(.title3)
      VStack(alignment: .leading, spacing: 2) {
        Text(url.lastPathComponent)
        Text(ContentView.abbreviated(url))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Text("\(suggestion.sessionCount) sessions")
        .foregroundStyle(.secondary)
      Text(suggestion.lastActivity, format: .relative(presentation: .named))
        .foregroundStyle(.secondary)
        .frame(minWidth: 70, alignment: .trailing)
      Button("Add", action: add)
        .accessibilityIdentifier("home.suggestion.add.\(suggestion.path)")
      Button("Hide", systemImage: "xmark", action: hide)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Stop suggesting this folder until a new session starts in it")
    }
    .font(.callout.monospacedDigit())
    .padding(.vertical, 2)
  }
}

private struct PickerRow: View {
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
          Label("Live in \(SessionMonitor.shared.host(of: summary))", systemImage: "circle.fill")
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
