import DrakarKit
import Foundation
import Observation

/// What the Run in Each Subfolder sheet holds until it starts the sessions
/// (docs/superpowers/specs/2026-10-12-skill-fanout-design.md §3).
@Observable
final class FanOutDraft {
  let skill: SkillEntry
  let agent: AgentKind
  private(set) var parent: URL
  private(set) var folders: [Subfolder] = []
  /// Only the folders holding a `.git`.
  var gitOnly = true {
    didSet { askCodex() }
  }
  var arguments = ""
  /// The mode each session starts in; nil for Settings' default.
  var mode: PermissionMode?
  /// How many run at once, as typed; empty for all.
  var limitText = ""

  @ObservationIgnored private let account: URL
  @ObservationIgnored private let codexSkills: (URL) -> CodexSkills
  /// Where Claude Code would not find the skill, read with the folders.
  private var claudeMissing: Set<URL> = []
  /// The ticks the person set; the others follow whether the skill reaches the folder.
  private var overrides: [URL: Bool] = [:]

  init(
    skill: SkillEntry, agent: AgentKind, parent: URL, account: URL,
    codexSkills: @escaping (URL) -> CodexSkills = { CodexSkillStore.shared.skills(for: $0) }
  ) {
    self.skill = skill
    self.agent = agent
    self.parent = parent
    self.account = account
    self.codexSkills = codexSkills
    read()
  }

  func change(parent: URL) {
    self.parent = parent
    overrides = [:]
    read()
  }

  var shown: [Subfolder] { gitOnly ? folders.filter(\.isGitRepository) : folders }

  /// Whether a session there would find the skill; unknown counts as found.
  func reaches(_ folder: Subfolder) -> Bool {
    switch agent {
    case .claude: return !claudeMissing.contains(folder.url)
    case .codex:
      guard let skills = codexSkills(folder.url).skills else { return true }
      return skills.contains { $0.name == skill.name }
    }
  }

  func isTicked(_ folder: Subfolder) -> Bool { overrides[folder.url] ?? reaches(folder) }

  func setTicked(_ folder: Subfolder, _ ticked: Bool) { overrides[folder.url] = ticked }

  func tickAll(_ ticked: Bool) {
    for folder in shown { overrides[folder.url] = ticked }
  }

  var chosen: [URL] { shown.filter(isTicked).map(\.url) }

  /// Codex could not say which folders hold the skill: every one is taken to.
  var reachUnchecked: Bool {
    agent == .codex && shown.contains { codexSkills($0.url).problem != nil }
  }

  /// The modes the agent takes, as the composer offers them.
  var offeredModes: [PermissionMode] {
    switch agent {
    case .claude: PermissionMode.allCases.filter { $0 != .bypass || ClaudeChoice.allowsBypass }
    case .codex: CodexPolicy.offeredModes(allowsBypass: ClaudeChoice.allowsBypass)
    }
  }

  var limit: Int? {
    Int(limitText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
  }

  func start(in project: Project) {
    project.runInSubfolders(
      skill, folders: chosen, arguments: arguments, mode: mode, limit: limit)
  }

  private func read() {
    folders = SubfolderScan.children(of: parent)
    switch agent {
    case .claude:
      claudeMissing = SkillReach.claudeMissing(
        name: skill.name, isBuiltin: skill.isBuiltin, account: account, parent: parent,
        folders: folders.map(\.url))
    case .codex: askCodex()
    }
  }

  /// One short-lived `codex app-server` per folder shown, not yet asked: the list is shared
  /// with the sessions' `/` menus.
  private func askCodex() {
    guard agent == .codex else { return }
    for folder in shown { codexSkills(folder.url).loadIfNeeded() }
  }
}
