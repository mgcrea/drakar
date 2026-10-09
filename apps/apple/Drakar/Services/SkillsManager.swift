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
  var isFetching: Bool { fetches > 0 }
  /// A folder is being searched for skills, or an install is writing.
  var isBusy: Bool { busy > 0 }
  /// The folders are being read again.
  private(set) var isScanning = false

  /// The seams tests replace: the home folder, the account, the open projects, both agents'
  /// lists, the disk's trash, the folders' reading, the login shell's environment.
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
  /// Reads the folders, off the main actor; tests hold a reading in flight.
  @ObservationIgnored var scanner:
    @Sendable (_ account: URL, _ project: URL?, _ codexFolders: [SkillFolder]) ->
      ClaudeSkillScan.Result = { ClaudeSkillScan.scan(account: $0, project: $1, codexFolders: $2) }
  @ObservationIgnored var environment: () async -> [String: String] = {
    await AgentSession.environment.value
  }
  @ObservationIgnored private var watchers: [FolderWatcher] = []
  @ObservationIgnored private var observed: (project: WeakProject, id: UUID)?
  @ObservationIgnored private var scanning: Task<Void, Never>?
  @ObservationIgnored private var refreshing: Task<Void, Never>?
  /// Clones and pulls running; `isFetching` while any is.
  private var fetches = 0
  /// Searches and installs running; `isBusy` while any is.
  private var busy = 0
  /// How long file changes settle before the folders are read again; tests shorten it.
  @ObservationIgnored var settleDelay: Duration = .milliseconds(250)
  @ObservationIgnored private var isStarted = false
  /// The account the folders were last read for.
  @ObservationIgnored private var readAccount: String?
  @ObservationIgnored private var merged: (inputs: Inputs, records: [SkillRecord])?

  private struct WeakProject {
    weak var project: Project?
  }

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

  var isLoading: Bool { isScanning || codex.isLoading || claude.isLoading }

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

  /// A pick, the Settings default or the shell's account changed: when the window's account is
  /// another, its folders are watched and read instead, and both agents asked under it.
  func accountMayHaveChanged() {
    guard account.directory.skillPath != readAccount else { return }
    if isStarted { watch() }
    refresh(load: true)
  }

  /// A file in the project's skill folders changed; the project reads both lists again itself.
  func projectFilesChanged() { rescan(after: settleDelay) }

  /// A file in the account's skills or commands, `~/.agents`'s or `~/.codex`'s skills changed.
  func userFilesChanged() {
    rescan(after: settleDelay)
    refreshing?.cancel()
    let delay = settleDelay
    refreshing = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      codex.refreshIfLoaded()
      claude.refreshIfLoaded()
    }
  }

  /// Reads the folders off the main actor, after `delay` when file changes are still coming; a
  /// newer reading replaces one still waiting or running.
  private func rescan(after delay: Duration = .zero) {
    scanning?.cancel()
    let account = account.directory
    readAccount = account.skillPath
    let project = project
    let codexFolders = places.codexFolders
    let scanner = scanner
    isScanning = true
    scanning = Task { [weak self] in
      if delay > .zero { try? await Task.sleep(for: delay) }
      guard !Task.isCancelled else { return }
      let result = await Task.detached(priority: .userInitiated) {
        scanner(account, project, codexFolders)
      }.value
      // A newer reading has taken over when this one is cancelled, and clears the flag itself.
      guard !Task.isCancelled, let self else { return }
      scan = result
      isScanning = false
      if let selection, !records.contains(where: { $0.id == selection }) { self.selection = nil }
    }
  }

  private func watch() {
    unwatch()
    let roots = [
      account.directory.appending(path: "skills"), account.directory.appending(path: "commands"),
      home.appending(path: ".agents/skills"), home.appending(path: ".codex/skills"),
    ]
    watchers = roots.filter { FileManager.default.fileExists(atPath: $0.skillPath) }.compactMap {
      FolderWatcher(folder: $0) { [weak self] _ in self?.userFilesChanged() }
    }
    if let project, let window = projectAt(project) {
      observed = (
        WeakProject(project: window),
        window.observeSkillFiles { [weak self] in self?.projectFilesChanged() }
      )
    }
  }

  private func unwatch() {
    for watcher in watchers { watcher.stop() }
    watchers = []
    if let observed { observed.project.project?.stopObservingSkillFiles(observed.id) }
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

  /// Off the main actor: a copy can take a while.
  func install(
    _ folders: [URL], place: SkillPlace, agents: [SkillAgent], method: InstallMethod
  ) async {
    let actions = actions
    busy += 1
    let result = await Task.detached(priority: .userInitiated) {
      Result { try actions.install(folders, place: place, agents: agents, method: method) }
    }.value
    busy -= 1
    if case .failure(let error) = result { failure = error.localizedDescription }
    afterAction()
  }

  /// The skills `folder` offers, `depth` levels down at most, searched off the main actor.
  func skills(in folder: URL, depth: Int) async -> [URL] {
    busy += 1
    defer { busy -= 1 }
    return await Task.detached(priority: .userInitiated) {
      SkillFolderSearch.skills(in: folder, depth: depth)
    }.value
  }

  /// Clones or pulls `address`; the skills its clone offers.
  func fetch(_ address: String) async throws -> [URL] {
    fetches += 1
    defer { fetches -= 1 }
    let folder = try await sources.fetch(address)
    return await skills(in: folder, depth: 4)
  }

  /// Update: pulls the clone `record` came from.
  func update(_ record: SkillRecord) async {
    fetches += 1
    do {
      try await sources.update(record)
    } catch {
      failure = error.localizedDescription
    }
    fetches -= 1
    afterAction()
  }

  func isFromGit(_ record: SkillRecord) -> Bool { places.clone(containing: record.realPath) != nil }

  /// The SKILL.md or command file Open opens; nil for a link whose target is gone.
  func fileToOpen(_ record: SkillRecord) -> URL? { record.file.map { URL(filePath: $0) } }

  /// What Reveal in Finder selects: the first agent's folder, the link itself when it is one.
  func itemToReveal(_ record: SkillRecord) -> URL {
    URL(filePath: record.sightings.compactMap(\.path).first ?? record.realPath)
  }

  /// The first 4 KB of the SKILL.md or command file.
  func preview(of record: SkillRecord) -> String? {
    fileToOpen(record).flatMap { files.read($0, limit: 4096) }
  }

  /// In the project window's editor, or the default app with no project.
  func open(_ record: SkillRecord) {
    guard let url = fileToOpen(record) else { return }
    if let project, let window = projectAt(project) {
      window.workspace.open(url)
      window.workspace.window?.makeKeyAndOrderFront(nil)
    } else {
      NSWorkspace.shared.open(url)
    }
  }

  func reveal(_ record: SkillRecord) {
    NSWorkspace.shared.activateFileViewerSelecting([itemToReveal(record)])
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
