import DrakarKit
import Foundation
import Observation

/// One project's skills and MCP servers under one account, as its `claude` would load them:
/// read by a probe, refreshed by the project's own sessions, kept for the launch and never
/// on disk. Every window on the folder shares it.
@Observable
final class Capabilities {
  let folder: URL
  /// The account the lists are for: the probe runs under it.
  let account: ClaudeAccount
  var accountKey: String { account.key }
  /// The last lists read; a failed reload leaves them.
  private(set) var lists = ProjectCapabilities()
  /// Why the last reading has no skills, or no servers.
  private(set) var skillsProblem: String?
  private(set) var serversProblem: String?
  private(set) var diagnostics = ""
  private(set) var isLoading = false
  /// A probe has read at least one of the lists.
  private(set) var hasLoaded = false

  /// Stands in for the probe, in tests: the folder and the account to probe it under.
  @ObservationIgnored var probe: (URL, ClaudeAccount) async -> ProbeOutcome = {
    await CapabilityProbe.run(folder: $0, account: $1)
  }
  @ObservationIgnored private var running: Task<Void, Never>?
  @ObservationIgnored private var rerun = false
  @ObservationIgnored private var observers: [UUID: (CapabilityChanges) -> Void] = [:]

  init(folder: URL, account: ClaudeAccount) {
    self.folder = folder
    self.account = account
  }

  /// The first time a window shows the project.
  func loadIfNeeded() {
    guard !hasLoaded, running == nil else { return }
    refresh()
  }

  /// A probe now, or, while one runs, once more after it however often this is asked.
  func refresh() {
    if running != nil {
      rerun = true
      return
    }
    rerun = false
    isLoading = true
    running = Task { await self.runProbes() }
  }

  /// For a file change: only lists something already asked for.
  func refreshIfLoaded() {
    guard hasLoaded || running != nil else { return }
    refresh()
  }

  /// The last window on the folder closed: its probe goes with it.
  func cancel() {
    running?.cancel()
    running = nil
    rerun = false
    isLoading = false
  }

  /// A session in the project's own folder answered `initialize`: its skills are current.
  func sessionReported(skills: [SkillEntry]) {
    skillsProblem = nil
    replace(ProjectCapabilities(skills: skills, mcpServers: lists.mcpServers))
  }

  /// `handler` hears what each new reading changed (`CapabilityChanges`), never the first.
  func observe(_ handler: @escaping (CapabilityChanges) -> Void) -> UUID {
    let id = UUID()
    observers[id] = handler
    return id
  }

  func stopObserving(_ id: UUID) {
    observers[id] = nil
  }

  private func runProbes() async {
    // Asks made since this task was created count for one more probe, even those made before
    // the first one started, so `rerun` is cleared only when that probe is taken up again.
    while true {
      let outcome = await probe(folder, account)
      if Task.isCancelled { return }
      apply(outcome)
      guard rerun else { break }
      rerun = false
    }
    isLoading = false
    running = nil
  }

  private func apply(_ outcome: ProbeOutcome) {
    var next = lists
    if let skills = outcome.capabilities.skills { next.skills = skills }
    if let servers = outcome.capabilities.mcpServers { next.mcpServers = servers }
    skillsProblem = outcome.skillsProblem
    serversProblem = outcome.serversProblem
    diagnostics = outcome.diagnostics
    // A reading without either list (no `claude`, or it failed to start) is not a load: the
    // next window on the folder tries again, as "open the folder again" says.
    if outcome.capabilities.skills != nil || outcome.capabilities.mcpServers != nil {
      hasLoaded = true
    }
    replace(next)
  }

  private func replace(_ next: ProjectCapabilities) {
    let changes = CapabilityChanges.diff(from: lists, to: next)
    lists = next
    guard !changes.isEmpty else { return }
    for handler in observers.values { handler(changes) }
  }
}

/// Every project's `Capabilities`, by folder (as `ProjectPath.normalize` writes it) and
/// account: another account has other user skills and servers.
final class CapabilityStore {
  static let shared = CapabilityStore()

  private var entries: [String: Capabilities] = [:]

  func capabilities(for folder: URL, account: ClaudeAccount) -> Capabilities {
    let path = ProjectPath.normalize(folder.path(percentEncoded: false))
    let key = path + "\n" + account.key
    if let entry = entries[key] { return entry }
    let entry = Capabilities(
      folder: URL(filePath: path, directoryHint: .isDirectory), account: account)
    entries[key] = entry
    return entry
  }
}

/// What a window's lists brought since the inspector was last seen: the rows with a dot,
/// and the toolbar button's dot while the inspector is hidden. Per window, so one tab
/// having seen a change does not clear it in another.
struct CapabilityMarks: Equatable {
  var skills: Set<String> = []
  var servers: Set<String> = []

  var isEmpty: Bool { skills.isEmpty && servers.isEmpty }

  mutating func add(_ changes: CapabilityChanges) {
    skills.formUnion(changes.addedSkills)
    servers.formUnion(changes.worsenedServers)
  }

  /// "2 new skills · github: Failed", for the toolbar button's tooltip.
  func summary(servers entries: [MCPServerEntry]) -> String {
    var parts: [String] = []
    if !skills.isEmpty {
      parts.append(
        skills.count == 1
          ? String(localized: "1 new skill") : String(localized: "\(skills.count) new skills"))
    }
    for name in servers.sorted() {
      let status = entries.first { $0.name == name }?.status.label
      parts.append(status.map { "\(name): \($0)" } ?? name)
    }
    return parts.joined(separator: " · ")
  }
}

extension MCPServerStatus {
  var label: String {
    switch self {
    case .connected: String(localized: "Connected")
    case .needsAuth: String(localized: "Needs authentication")
    case .failed: String(localized: "Failed")
    case .pending: String(localized: "Connecting")
    case .other(let raw): raw
    }
  }
}

/// Where a server is configured, as a row says it.
enum MCPSourceLabel {
  static func text(_ source: String?) -> String? {
    switch source {
    case nil: nil
    case "user": String(localized: "User")
    case "project": String(localized: "Project")
    case "local": String(localized: "Local")
    case "plugin": String(localized: "Plugin")
    case "claudeai": String(localized: "claude.ai")
    case let other?: other
    }
  }
}
