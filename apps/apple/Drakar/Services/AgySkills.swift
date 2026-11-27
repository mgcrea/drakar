import DrakarKit
import Foundation
import Observation

/// Antigravity's slash commands and skills for one folder, populated either by a running
/// `agy acp` session's `available_commands_update` or by a short-lived `AgyProbe`.
@Observable
final class AgySkills {
  let folder: URL
  private(set) var skills: [SkillEntry]?
  private(set) var problem: String?
  private(set) var isAgyMissing = false
  private(set) var isLoading = false
  private(set) var hasLoaded = false

  @ObservationIgnored var reader: (URL) async throws -> [SkillEntry] = {
    try await AgySkills.read(folder: $0)
  }
  @ObservationIgnored private var running: Task<Void, Never>?
  @ObservationIgnored private var rerun = false

  struct NotFound: Error, LocalizedError {
    var errorDescription: String? { String(localized: "Antigravity (agy) was not found.") }
  }

  init(folder: URL) {
    self.folder = folder
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
        problem = String(
          localized: "Couldn't read Antigravity's skills. \(error.localizedDescription)")
        isAgyMissing = error is NotFound
      }
      guard rerun else { break }
      rerun = false
    }
    isLoading = false
    running = nil
  }

  static func read(folder: URL) async throws -> [SkillEntry] {
    let environment = await AgentSession.environment.value
    guard let executable = AgyLaunch.locate(path: environment["PATH"]) else {
      throw NotFound()
    }
    let snapshot = try await AgyProbe.read(
      folder: folder,
      configuration: AgyLaunch.configuration(
        executable: executable, environment: environment, folder: folder))
    if !snapshot.models.isEmpty { ModelCatalog.shared.recordAgy(snapshot.models) }
    return snapshot.commands ?? []
  }
}

/// Every folder's `AgySkills`, by the folder as `ProjectPath.normalize` writes it.
final class AgySkillStore {
  static let shared = AgySkillStore()

  private var entries: [String: AgySkills] = [:]

  func skills(for folder: URL) -> AgySkills {
    let path = ProjectPath.normalize(folder)
    if let entry = entries[path] { return entry }
    let entry = AgySkills(folder: URL(filePath: path, directoryHint: .isDirectory))
    entries[path] = entry
    return entry
  }
}
