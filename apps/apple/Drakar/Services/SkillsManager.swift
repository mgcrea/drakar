import AppKit
import DrakarKit
import Foundation
import Observation

/// A place of the Skills window's sidebar.
enum SkillsPlace: String, CaseIterable, Identifiable {
  case all, yours, project, plugins, codex

  var id: Self { self }

  func includes(_ record: SkillRecord) -> Bool {
    switch self {
    case .all: true
    case .yours: record.origin == .user
    case .project: record.origin == .project
    case .plugins: if case .plugin = record.origin { true } else { false }
    case .codex: record.origin == .codexSystem || record.origin == .codexAdmin
    }
  }
}

/// The Skills window's model: one project's skills (or none) under its window's account, as
/// both agents see them, and what the window does to them. One for the app, as the window is.
@Observable
final class SkillsManager {
  static let shared = SkillsManager()
  static let windowID = "skills"

  /// The project shown; nil for the account's and `~/.agents`'s skills only.
  private(set) var project: URL?
  var place: SkillsPlace = .all
  var filter = ""
  var selection: SkillRecord.ID?
  /// The last reading of the places Claude Code reads.
  private(set) var scan = ClaudeSkillScan.Result()
  /// Why the last action did nothing, for the alert.
  var failure: String?
  /// A git clone or pull is running.
  private(set) var isFetching = false

  /// The seams tests replace: the home folder, the account, the open projects, both agents'
  /// lists, the disk's trash, the login shell's environment.
  @ObservationIgnored var home = FileManager.default.homeDirectoryForCurrentUser
  @ObservationIgnored var accountFor: (URL?) -> ClaudeAccount = { SkillsManager.account(for: $0) }
  @ObservationIgnored var openFolders: () -> [URL] = { SkillsManager.openProjectFolders() }
  @ObservationIgnored var projectAt: (URL) -> Project? = { SkillsManager.openProject(at: $0) }
  @ObservationIgnored var codexFor: (URL) -> CodexSkills = {
    CodexSkillStore.shared.skills(for: $0)
  }
  @ObservationIgnored var claudeFor: (URL, ClaudeAccount) -> Capabilities = {
    CapabilityStore.shared.capabilities(for: $0, account: $1)
  }
  @ObservationIgnored var files = SkillFileSystem()
  @ObservationIgnored var environment: () async -> [String: String] = {
    await AgentSession.environment.value
  }
  @ObservationIgnored private var watchers: [FolderWatcher] = []
  @ObservationIgnored private var observed: (project: Project, id: UUID)?
  @ObservationIgnored private var isStarted = false
  @ObservationIgnored private var merged: (inputs: Inputs, records: [SkillRecord])?

  private struct Inputs: Equatable {
    var scan: [ScannedSkill]
    var claude: [SkillEntry]?
    var codex: [CodexSkillRecord]?
  }

  init() {}

  // MARK: - What is shown

  /// The project window's account, else Settings' for new sessions.
  var account: ClaudeAccount { accountFor(project) }
  var places: SkillPlaces { SkillPlaces(account: account.directory, home: home, project: project) }
  /// The folder both agents are asked about: the project, or the home folder for user-level
  /// skills only.
  private var folder: URL { project ?? home }
  var codex: CodexSkills { codexFor(folder) }
  var claude: Capabilities { claudeFor(folder, account) }

  var records: [SkillRecord] {
    let inputs = Inputs(scan: scan.skills, claude: claude.lists.skills, codex: codex.records)
    if let merged, merged.inputs == inputs { return merged.records }
    let records = SkillInventory.merge(
      scan: inputs.scan, claude: inputs.claude, codex: inputs.codex)
    merged = (inputs, records)
    return records
  }

  var shown: [SkillRecord] { records.filter { place.includes($0) && $0.matches(filter) } }

  func count(_ place: SkillsPlace) -> Int { records.count(where: place.includes) }

  var selected: SkillRecord? { records.first { $0.id == selection } }

  var visiblePlaces: [SkillsPlace] {
    SkillsPlace.allCases.filter { $0 != .project || project != nil }
  }

  /// What failed to read, shown above the list with Retry; Codex missing is a caption instead.
  var problems: [String] {
    scan.problems + (codex.isCodexMissing ? [] : [codex.problem].compactMap { $0 })
  }

  var isLoading: Bool { codex.isLoading || claude.isLoading }

  // MARK: - Choosing the project

  /// Opens the window (`open` is SwiftUI's `openWindow(id:)`) on `folder`'s project; with no
  /// folder, keeps the project shown while it is still open.
  func show(project folder: URL?, open: (String) -> Void) {
    if let folder { choose(project: folder) } else { openProjectsChanged() }
    open(Self.windowID)
  }

  func choose(project folder: URL?) {
    let folder = folder.map { URL(filePath: $0.skillPath, directoryHint: .isDirectory) }
    guard folder?.skillPath != project?.skillPath else { return }
    project = folder
    selection = nil
    if folder == nil, place == .project { place = .all }
    if isStarted { watch() }
    refresh(load: true)
  }

  /// A project window closed: a project no longer open is no longer shown.
  func openProjectsChanged() {
    guard let project, !openFolders().map(\.skillPath).contains(project.skillPath) else {
      return
    }
    choose(project: nil)
  }

  // MARK: - Reading

  /// The window appeared: watch the folders and read everything.
  func start() {
    isStarted = true
    watch()
    refresh(load: true)
  }

  func stop() {
    isStarted = false
    unwatch()
  }

  /// Reads the folders again, and asks both agents again; with `load`, only those that have
  /// not answered yet.
  func refresh(load: Bool = false) {
    rescan()
    if load {
      codex.loadIfNeeded()
      claude.loadIfNeeded()
    } else {
      codex.refresh(force: true)
      claude.refresh()
    }
  }

  /// A file in the project's skill folders changed; the project reads both lists again itself.
  func projectFilesChanged() { rescan() }

  /// A file in the account's, `~/.agents`'s or `~/.codex`'s skills changed.
  func userFilesChanged() {
    rescan()
    codex.refreshIfLoaded()
    claude.refreshIfLoaded()
  }

  private func rescan() {
    scan = ClaudeSkillScan.scan(
      account: account.directory, project: project, codexFolders: places.codexFolders)
    if let selection, !records.contains(where: { $0.id == selection }) { self.selection = nil }
  }

  private func watch() {
    unwatch()
    let roots = [
      account.directory.appending(path: "skills"), home.appending(path: ".agents/skills"),
      home.appending(path: ".codex/skills"),
    ]
    watchers = roots.filter { FileManager.default.fileExists(atPath: $0.skillPath) }.compactMap {
      FolderWatcher(folder: $0) { [weak self] _ in self?.userFilesChanged() }
    }
    if let project, let window = projectAt(project) {
      observed = (window, window.observeSkillFiles { [weak self] in self?.projectFilesChanged() })
    }
  }

  private func unwatch() {
    for watcher in watchers { watcher.stop() }
    watchers = []
    if let observed { observed.project.stopObservingSkillFiles(observed.id) }
    observed = nil
  }

  // MARK: - Actions

  private var actions: SkillActions { SkillActions(places: places, files: files) }
  private var sources: SkillSources { SkillSources(root: places.sources, environment: environment) }

  func share(_ record: SkillRecord) { perform { _ = try actions.share(record) } }

  /// What deleting `record` would do, for the confirmation; nil after saying why it cannot.
  func deletePlan(for record: SkillRecord) -> DeletePlan? {
    do {
      return try actions.deletePlan(for: record)
    } catch {
      failure = error.localizedDescription
      return nil
    }
  }

  func delete(_ plan: DeletePlan) { perform { try actions.delete(plan) } }

  func install(_ folders: [URL], place: SkillPlace, agents: [SkillAgent], method: InstallMethod) {
    perform { _ = try actions.install(folders, place: place, agents: agents, method: method) }
  }

  /// Clones or pulls `address`; the skills its clone offers.
  func fetch(_ address: String) async throws -> [URL] {
    isFetching = true
    defer { isFetching = false }
    let folder = try await sources.fetch(address)
    return SkillFolderSearch.skills(in: folder, depth: 4)
  }

  /// Update: pulls the clone `record` came from.
  func update(_ record: SkillRecord) async {
    isFetching = true
    do {
      try await sources.update(record)
    } catch {
      failure = error.localizedDescription
    }
    isFetching = false
    afterAction()
  }

  func isFromGit(_ record: SkillRecord) -> Bool { places.clone(containing: record.realPath) != nil }

  /// The first 4 KB of the SKILL.md or command file.
  func preview(of record: SkillRecord) -> String? {
    record.file.flatMap { files.read(URL(filePath: $0), limit: 4096) }
  }

  /// In the project window's editor, or the default app with no project.
  func open(_ record: SkillRecord) {
    guard let file = record.file else { return }
    let url = URL(filePath: file)
    if let project, let window = projectAt(project) {
      window.workspace.open(url)
      window.workspace.window?.makeKeyAndOrderFront(nil)
    } else {
      NSWorkspace.shared.open(url)
    }
  }

  func reveal(_ record: SkillRecord) {
    let path = record.sightings.compactMap(\.path).first ?? record.realPath
    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
  }

  private func perform(_ action: () throws -> Void) {
    do {
      try action()
    } catch {
      failure = error.localizedDescription
    }
    afterAction()
  }

  /// A folder may have appeared: watch it; then read everything again at once.
  private func afterAction() {
    if isStarted { watch() }
    refresh()
  }

  // MARK: - Defaults

  static func account(for folder: URL?) -> ClaudeAccount {
    if let folder { return AccountStore.shared.windowAccount(for: folder) }
    return ClaudeChoice.newSessionAccount ?? AccountStore.shared.shellAccount
  }

  static func openProjectFolders() -> [URL] {
    Set(OpenSessions.shared.projects.values.map(\.folder.skillPath)).sorted().map {
      URL(filePath: $0, directoryHint: .isDirectory)
    }
  }

  static func openProject(at folder: URL) -> Project? {
    OpenSessions.shared.projects.values.first { $0.folder.skillPath == folder.skillPath }
  }
}
