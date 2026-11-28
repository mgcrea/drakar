import DrakarKit
import Foundation

/// Which agent a session runs. Stored with a session's target, so a window reopens each of
/// its sessions with its own agent; a target stored before Codex arrived is Claude Code's.
enum AgentKind: String, Codable, CaseIterable {
  case claude, codex, agy, grok

  /// The agent ⌥-click and ⌃⌘N start.
  var other: AgentKind { self == .claude ? .codex : .claude }

  /// The product's name: "Claude Code exited", the footer's version.
  var name: String {
    switch self {
    case .claude: String(localized: "Claude Code")
    case .codex: String(localized: "Codex")
    case .grok: String(localized: "Grok")
    case .agy: String(localized: "Antigravity")
    }
  }

  /// How a sentence addresses it: "Ask Claude to do something…".
  var shortName: String {
    switch self {
    case .claude: String(localized: "Claude")
    case .codex: String(localized: "Codex")
    case .grok: String(localized: "Grok")
    case .agy: String(localized: "Antigravity")
    }
  }

  var features: AgentFeatures {
    switch self {
    case .claude: .claude
    case .codex: .codex
    case .grok: .grok
    case .agy: .agy
    }
  }

  func makeBackend() -> AgentBackend {
    switch self {
    case .claude: ClaudeBackend()
    case .codex: CodexBackend()
    case .grok: AgyBackend(agent: .grok)
    case .agy: AgyBackend()
    }
  }
}

/// What an agent's sessions can do beyond a conversation. The views ask this, never which
/// agent runs (docs/superpowers/specs/2026-10-07-codex-live-sessions-design.md).
struct AgentFeatures: Equatable {
  var agent: AgentKind
  /// A prompt sent mid-turn can be taken back.
  var cancelsQueued: Bool
  /// The composer's `/` menu lists the agent's commands and skills (`Project.slashCommands`),
  /// and the inspector's skills run in its sessions.
  var slashCommands: Bool
  var forks: Bool
  /// Its files can move to another account.
  var moves: Bool
  /// The footer names its account and the sidebar marks another one: Codex's accounts are
  /// slice 4.
  var showsAccount: Bool
  var showsPromptCache: Bool
  var acceptsPDF: Bool
  /// Settings' effort for new sessions applies: it is Claude Code's. Each agent has its own
  /// default mode and model.
  var usesSettingsDefaults: Bool
  /// A mode, model or effort pick reaches a running process at once; Codex's wait for the
  /// next turn.
  var picksApplyAtOnce: Bool
  /// A running task can be stopped, a foreground call moved to the background, and a shell
  /// task's output read (`TaskControls`).
  var controlsTasks: Bool
  /// The agent guesses the next prompt once a turn ends (`AgentEvent.promptSuggested`), and
  /// can be told to stop while nobody sees the composer (`AgentCommand.pauseSuggestions`).
  var suggestsPrompts = false

  var name: String { agent.name }

  static let claude = AgentFeatures(
    agent: .claude, cancelsQueued: true, slashCommands: true, forks: true, moves: true,
    showsAccount: true, showsPromptCache: true, acceptsPDF: true, usesSettingsDefaults: true,
    picksApplyAtOnce: true, controlsTasks: true, suggestsPrompts: true)

  static let codex = AgentFeatures(
    agent: .codex, cancelsQueued: false, slashCommands: true, forks: false, moves: false,
    showsAccount: false, showsPromptCache: false, acceptsPDF: false,
    usesSettingsDefaults: false, picksApplyAtOnce: false, controlsTasks: false)

  static let grok = AgentFeatures(
    agent: .grok, cancelsQueued: true, slashCommands: true, forks: false, moves: false,
    showsAccount: false, showsPromptCache: false, acceptsPDF: false,
    usesSettingsDefaults: false, picksApplyAtOnce: true, controlsTasks: false)

  static let agy = AgentFeatures(
    agent: .agy, cancelsQueued: true, slashCommands: true, forks: false, moves: false,
    showsAccount: false, showsPromptCache: false, acceptsPDF: false,
    usesSettingsDefaults: false, picksApplyAtOnce: true, controlsTasks: false)
}

extension SessionSummary {
  var agentKind: AgentKind { provider.flatMap(AgentKind.init(rawValue:)) ?? .claude }

  var archiveKey: String { "\(agentKind.rawValue):\(sessionID)" }
}
