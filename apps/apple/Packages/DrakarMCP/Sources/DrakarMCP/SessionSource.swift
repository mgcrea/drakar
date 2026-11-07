import DrakarKit
import Foundation

// What the tools read and steer, as plain values. The app answers `SessionSource` from its
// session model and its host connection; the tests answer it from a fake. Nothing here holds
// a reference into the app, so a tool can be tested with no window, no process and no port.

/// Which CLI runs a session.
public enum Agent: String, Sendable, CaseIterable {
  case claude, codex
}

/// A session's state as a caller reads it, folded from Drakar's own.
public enum SessionState: String, Sendable, CaseIterable {
  case working, waiting, idle, reconnecting, unreachable, ended
}

/// Where a session is held: in a window, by the host in the background, or by another
/// Drakar (`heldBy` names it).
public enum SessionPlace: String, Sendable {
  case window, background, elsewhere
}

/// One session, as the session list shows it.
public struct SessionRow: Sendable, Equatable {
  public var id: String
  public var title: String?
  public var agent: Agent
  public var folder: String
  /// The runner's display name; nil for this Mac.
  public var runner: String?
  public var state: SessionState
  public var waitingFor: String?
  public var model: String?
  public var contextUsed: Int?
  public var contextLimit: Int?
  public var lastActivity: Date?
  public var place: SessionPlace
  public var readOnly: Bool
  public var heldBy: String?

  public init(
    id: String, title: String? = nil, agent: Agent, folder: String, runner: String? = nil,
    state: SessionState, waitingFor: String? = nil, model: String? = nil,
    contextUsed: Int? = nil, contextLimit: Int? = nil, lastActivity: Date? = nil,
    place: SessionPlace, readOnly: Bool = false, heldBy: String? = nil
  ) {
    self.id = id
    self.title = title
    self.agent = agent
    self.folder = folder
    self.runner = runner
    self.state = state
    self.waitingFor = waitingFor
    self.model = model
    self.contextUsed = contextUsed
    self.contextLimit = contextLimit
    self.lastActivity = lastActivity
    self.place = place
    self.readOnly = readOnly
    self.heldBy = heldBy
  }
}

/// A request waiting on an answer: a tool's permission, or an MCP server's question.
public enum PendingItem: Sendable, Equatable {
  case permission(requestID: String, request: PermissionRequest)
  case elicitation(requestID: String, elicitation: Elicitation)

  public var requestID: String {
    switch self {
    case .permission(let requestID, _), .elicitation(let requestID, _): requestID
    }
  }
}

/// Why a session wants the person.
public enum AttentionKind: String, Sendable {
  case permission, question, plan, elicitation
  case askedInText = "asked_in_text"
  case offeredInText = "offered_in_text"
}

/// One session that wants the person, and what for.
public struct AttentionItem: Sendable, Equatable {
  public var session: SessionRow
  public var kind: AttentionKind
  /// The request to answer; nil for `askedInText` and `offeredInText`.
  public var pending: PendingItem?
  /// The ask's text, for the in-text kinds.
  public var text: String?

  public init(
    session: SessionRow, kind: AttentionKind, pending: PendingItem? = nil, text: String? = nil
  ) {
    self.session = session
    self.kind = kind
    self.pending = pending
    self.text = text
  }
}

/// One session in full: its row, and what waits on it.
public struct SessionDetail: Sendable, Equatable {
  public var row: SessionRow
  public var pending: [PendingItem]
  /// Messages queued behind the running turn, oldest first.
  public var queued: [String]
  public var permissionMode: String?
  public var accountFolder: String?

  public init(
    row: SessionRow, pending: [PendingItem] = [], queued: [String] = [],
    permissionMode: String? = nil, accountFolder: String? = nil
  ) {
    self.row = row
    self.pending = pending
    self.queued = queued
    self.permissionMode = permissionMode
    self.accountFolder = accountFolder
  }
}

/// A folder a session can be started in.
public struct ProjectRow: Sendable, Equatable {
  public var folder: String
  /// The runner's display name; nil for this Mac.
  public var runner: String?
  public var isOpen: Bool

  public init(folder: String, runner: String? = nil, isOpen: Bool) {
    self.folder = folder
    self.runner = runner
    self.isOpen = isOpen
  }
}

/// The runner Mac, as Settings shows it.
public struct RunnerStatus: Sendable, Equatable {
  public var name: String
  public var isConnected: Bool
  public var drakarVersion: String?
  public var claudeVersion: String?
  public var lastError: String?

  public init(
    name: String, isConnected: Bool, drakarVersion: String? = nil, claudeVersion: String? = nil,
    lastError: String? = nil
  ) {
    self.name = name
    self.isConnected = isConnected
    self.drakarVersion = drakarVersion
    self.claudeVersion = claudeVersion
    self.lastError = lastError
  }
}

/// A new session to start, and its first prompt.
public struct StartRequest: Sendable, Equatable {
  public var folder: String
  /// The runner's display name; nil for this Mac.
  public var runner: String?
  public var prompt: String
  /// Nil for the agent Drakar would pick.
  public var agent: Agent?
  public var model: String?

  public init(
    folder: String, runner: String? = nil, prompt: String, agent: Agent? = nil,
    model: String? = nil
  ) {
    self.folder = folder
    self.runner = runner
    self.prompt = prompt
    self.agent = agent
    self.model = model
  }
}

/// What became of a message: sent now, or queued behind the running turn.
public enum SendOutcome: String, Sendable {
  case sent, queued
}

/// A refusal whose sentence is meant for the caller.
public struct SessionError: LocalizedError, Sendable, Equatable {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }

  public var errorDescription: String? { message }
}

/// Everything the tools read and do, answered by the app with the calls its own controls make.
public protocol SessionSource: Sendable {
  /// Live sessions (window, background, elsewhere), then, when `includeEnded`, up to
  /// `endedLimit` ended ones newest first.
  func sessions(includeEnded: Bool, endedLimit: Int) async -> [SessionRow]
  func detail(of id: String) async -> SessionDetail?
  /// Most urgent first, Drakar's `Urgency` order (permission, choice, question, offer).
  func attention() async -> [AttentionItem]
  func transcript(of id: String) async throws -> Transcript
  func projects() async -> [ProjectRow]
  func runner() async -> RunnerStatus?
  /// Nil when work may be sent; otherwise the composer's sentence.
  func workRefusal() async -> String?
  /// Settings › MCP Server › Let agents answer permission prompts, read at each call.
  func permissionsAllowed() async -> Bool
  /// Returns the new session's id.
  func start(_ request: StartRequest) async throws -> String
  func send(to id: String, text: String) async throws -> SendOutcome
  func interrupt(_ id: String) async throws
  func end(_ id: String) async throws
  func answer(_ id: String, requestID: String, with decision: PermissionDecision) async throws
  func answer(_ id: String, requestID: String, with answer: ElicitationAnswer) async throws
}
