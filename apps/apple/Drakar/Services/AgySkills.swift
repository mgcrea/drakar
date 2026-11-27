import DrakarKit
import Foundation
import Observation

/// Antigravity and Grok slash commands and skills for one folder, populated either by a running
/// session's `available_commands_update` or by a short-lived `AgyProbe`.
@Observable
final class AgySkills {
  let folder: URL
  let agent: AgentKind
  private(set) var skills: [SkillEntry]?
  private(set) var problem: String?
  private(set) var isAgyMissing = false
  private(set) var isLoading = false
  private(set) var hasLoaded = false

  @ObservationIgnored var reader: (URL) async throws -> [SkillEntry]
  @ObservationIgnored private var running: Task<Void, Never>?
  @ObservationIgnored private var rerun = false

  struct NotFound: Error, LocalizedError {
    var agent: AgentKind = .agy

    var errorDescription: String? {
      agent == .grok
        ? String(localized: "Grok Build (grok) was not found.")
        : String(localized: "Antigravity (agy) was not found.")
    }
  }

  init(folder: URL, agent: AgentKind = .agy) {
    self.folder = folder
    self.agent = agent
    self.reader = { try await AgySkills.read(folder: $0, agent: agent) }
  }

  func record(_ entries: [SkillEntry]) {
    skills = entries
    problem = nil
    isAgyMissing = false
    hasLoaded = true
  }

  func loadIfNeeded() {
    guard !hasLoaded, running == nil else { return }
    refresh()
  }

  func refresh() {
    if running != nil {
      rerun = true
      return
    }
    rerun = false
    isLoading = true
    running = Task { await self.read() }
  }

  private func read() async {
    while true {
      do {
        let entries = try await reader(folder)
        skills = entries
        problem = nil
        isAgyMissing = false
        hasLoaded = true
      } catch {
        let name = agent.name
        problem = String(
          localized: "Couldn't read \(name)'s skills. \(error.localizedDescription)")
        isAgyMissing = error is NotFound
      }
      guard rerun else { break }
      rerun = false
    }
    isLoading = false
    running = nil
  }

  static func read(folder: URL, agent: AgentKind = .agy) async throws -> [SkillEntry] {
    let environment = await AgentSession.environment.value
    guard let executable = AgyLaunch.locate(path: environment["PATH"], binary: agent.rawValue)
    else {
      throw NotFound(agent: agent)
    }
    let snapshot = try await AgyProbe.read(
      folder: folder,
      configuration: AgyLaunch.configuration(
        executable: executable, environment: environment, folder: folder, agent: agent))
    if !snapshot.models.isEmpty {
      if agent == .grok {
        ModelCatalog.shared.recordGrok(snapshot.models)
      } else {
        ModelCatalog.shared.recordAgy(snapshot.models)
      }
    }
    return snapshot.commands ?? []
  }
}

/// Every folder's `AgySkills`, by the agent and the folder as `ProjectPath.normalize` writes it.
final class AgySkillStore {
  static let shared = AgySkillStore()

  private var entries: [String: AgySkills] = [:]

  func skills(for folder: URL, agent: AgentKind = .agy) -> AgySkills {
    let path = ProjectPath.normalize(folder)
    let key = "\(agent.rawValue)\n\(path)"
    if let entry = entries[key] { return entry }
    let entry = AgySkills(
      folder: URL(filePath: path, directoryHint: .isDirectory), agent: agent)
    entries[key] = entry
    return entry
  }
}
