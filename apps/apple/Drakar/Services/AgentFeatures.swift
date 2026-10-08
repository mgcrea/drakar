import DrakarKit
import Foundation

/// Which agent a session runs. Stored with a session's target, so a window reopens each of
/// its sessions with its own agent; a target stored before Codex arrived is Claude Code's.
enum AgentKind: String, Codable, CaseIterable {
  case claude, codex

  /// The agent ⌥-click and ⌃⌘N start.
  var other: AgentKind { self == .claude ? .codex : .claude }

  /// The product's name: "Claude Code exited", the footer's version.
  var name: String {
    switch self {
    case .claude: String(localized: "Claude Code")
    case .codex: String(localized: "Codex")
    }
  }

  /// How a sentence addresses it: "Ask Claude to do something…".
  var shortName: String {
    switch self {
    case .claude: String(localized: "Claude")
    case .codex: String(localized: "Codex")
    }
  }

  var features: AgentFeatures { self == .claude ? .claude : .codex }

  func makeBackend() -> AgentBackend { self == .claude ? ClaudeBackend() : CodexBackend() }
}

/// What an agent's sessions can do beyond a conversation. The views ask this, never which
/// agent runs (docs/superpowers/specs/2026-10-07-codex-live-sessions-design.md).
struct AgentFeatures: Equatable {
  var agent: AgentKind
  /// A prompt sent mid-turn can be taken back.
  var cancelsQueued: Bool
  /// The composer's `/` menu lists the agent's commands and skills.
  var slashCommands: Bool
  var forks: Bool
  /// Its files can move to another account.
  var moves: Bool
  /// The footer names its account and the sidebar marks another one: Codex's accounts are
  /// slice 4.
  var showsAccount: Bool
  var showsPromptCache: Bool
  var acceptsPDF: Bool
  /// Settings' model, mode and effort for new sessions apply: they are Claude Code's.
  var usesSettingsDefaults: Bool
  /// A mode, model or effort pick reaches a running process at once; Codex's wait for the
  /// next turn.
  var picksApplyAtOnce: Bool

  var name: String { agent.name }

  static let claude = AgentFeatures(
    agent: .claude, cancelsQueued: true, slashCommands: true, forks: true, moves: true,
    showsAccount: true, showsPromptCache: true, acceptsPDF: true, usesSettingsDefaults: true,
    picksApplyAtOnce: true)

  static let codex = AgentFeatures(
    agent: .codex, cancelsQueued: false, slashCommands: false, forks: false, moves: false,
    showsAccount: false, showsPromptCache: false, acceptsPDF: false,
    usesSettingsDefaults: false, picksApplyAtOnce: false)
}
