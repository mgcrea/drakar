import DrakarKit
import Foundation
import Observation

/// Codex's skills for one folder, as a short-lived `codex app-server` lists them
/// (`skills/list`, docs/codex-app-server.md, "Skills"): what a Codex session's `/` menu and
/// the inspector offer, and what a prompt can name; the Skills window reads the same answer's
/// records. Read when first asked for, again when Codex or the folder's files say they
/// changed; in memory only. Every window on the folder shares it, under the one Codex home
/// until Codex accounts (slice 4).
@Observable
final class CodexSkills {
  let folder: URL
  /// The last list read; a failed reload leaves it.
  private(set) var skills: [SkillEntry]?
  /// Every skill the last read listed, shadowed and disabled ones too; a failed reload
  /// leaves them.
  private(set) var records: [CodexSkillRecord]?
  /// Why the last read failed, until one succeeds.
  private(set) var problem: String?
  /// The last read failed because there is no `codex` to ask.
  private(set) var isCodexMissing = false
  private(set) var isLoading = false
  /// A read has listed the skills at least once.
  private(set) var hasLoaded = false

  /// Stands in for Codex, in tests: the folder, and whether Codex reads its files again.
  @ObservationIgnored var reader: (URL, Bool) async throws -> CodexSkillList.Listing = {
    try await CodexSkills.read(folder: $0, force: $1)
  }
  @ObservationIgnored private var running: Task<Void, Never>?
  /// Asked again while a read ran: whether that read forces a reload; nil when not asked.
  @ObservationIgnored private var rerun: Bool?

  /// No `codex` on the login shell's PATH.
  struct NotFound: Error, LocalizedError {
    var errorDescription: String? { String(localized: "Codex was not found.") }
  }

  init(folder: URL) {
    self.folder = folder
  }

  /// The first time a list is shown; after a failed read, the next time one is asked for.
  func loadIfNeeded() {
    guard !hasLoaded, running == nil else { return }
    refresh()
  }

  /// A read now, or, while one runs, once more after it however often this is asked.
  /// `force` has Codex read the skill files again rather than answer from its cache.
  func refresh(force: Bool = false) {
    if running != nil {
      rerun = (rerun ?? false) || force
      return
    }
    rerun = nil
    isLoading = true
    running = Task { await self.read(force: force) }
  }

  /// For a change Codex or the files reported: only a list something already asked for.
  func refreshIfLoaded() {
    guard hasLoaded || running != nil else { return }
    refresh()
  }

  private func read(force: Bool) async {
    var force = force
    while true {
      do {
        let listing = try await reader(folder, force)
        skills = listing.entries
        records = listing.records
        problem = nil
        isCodexMissing = false
        hasLoaded = true
      } catch {
        problem = String(localized: "Couldn't read Codex's skills. \(error.localizedDescription)")
        isCodexMissing = error is NotFound
      }
      guard let again = rerun else { break }
      force = again
      rerun = nil
    }
    isLoading = false
    running = nil
  }

  /// Asks a `codex app-server` started in `folder`, as the model list's is.
  static func read(folder: URL, force: Bool) async throws -> CodexSkillList.Listing {
    let environment = await AgentSession.environment.value
    guard let executable = CodexLaunch.locate(path: environment["PATH"]) else {
      throw NotFound()
    }
    return try await read(
      folder: folder, force: force,
      configuration: CodexLaunch.configuration(
        executable: executable, environment: environment, folder: folder))
  }

  static func read(folder: URL, force: Bool, configuration: AgentProcess.Configuration)
    async throws -> CodexSkillList.Listing
  {
    var params: [String: JSONValue] = [
      "cwds": .array([.string(ProjectPath.normalize(folder.path(percentEncoded: false)))])
    ]
    if force { params["forceReload"] = .bool(true) }
    let results = try await CodexOneShot(configuration: configuration).run { previous in
      previous == nil ? ("skills/list", .object(params)) : nil
    }
    return CodexSkillList.listing(results.first ?? .null)
  }
}

/// Every folder's `CodexSkills`, by the folder as `ProjectPath.normalize` writes it.
final class CodexSkillStore {
  static let shared = CodexSkillStore()

  private var entries: [String: CodexSkills] = [:]

  func skills(for folder: URL) -> CodexSkills {
    let path = ProjectPath.normalize(folder.path(percentEncoded: false))
    if let entry = entries[path] { return entry }
    let entry = CodexSkills(folder: URL(filePath: path, directoryHint: .isDirectory))
    entries[path] = entry
    return entry
  }
}
