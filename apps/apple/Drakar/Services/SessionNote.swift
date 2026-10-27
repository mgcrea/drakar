import DrakarKit
import Foundation

/// What the session did to its process, logged beside the process's own lines so that a
/// replay takes the same path: the CLI's stdout alone says nothing of a prompt typed here, an
/// answer given, or a request id the backend counted.
enum SessionNote: Codable, Equatable {
  /// `backend.started` ran, with the prompt typed before the process existed.
  case started(first: AgentCommand?, effect: NoteEffect)
  /// `backend.send` ran.
  case sent(AgentCommand, effect: NoteEffect)
}

/// What the session showed of a command when it sent it, which its process never echoes.
enum NoteEffect: Codable, Equatable {
  case prompt(text: String, context: String?, attachments: [AttachmentPreview])
  case queued(QueuedPrompt)
  case answered(requestID: String)
  /// An MCP server's question, answered as `action` says.
  case answeredElicitation(requestID: String, action: ElicitationAction)
  case none
}

/// What the person did with an MCP server's question, as a note keeps it: the action alone.
/// What they typed went to the CLI and is never kept, so an accepted form comes back from a
/// note as `.accept(nil)`.
enum ElicitationAction: String, Codable, Equatable {
  case accept, decline, cancel

  init(_ answer: ElicitationAnswer) {
    self =
      switch answer {
      case .accept: .accept
      case .decline: .decline
      case .cancel: .cancel
      }
  }

  var answer: ElicitationAnswer {
    switch self {
    case .accept: .accept(nil)
    case .decline: .decline
    case .cancel: .cancel
    }
  }
}

/// An answer as a command carries it: whole to the backend, and to a note as its action
/// alone (`ElicitationAction`).
struct NotedAnswer: Codable, Equatable {
  var answer: ElicitationAnswer

  init(_ answer: ElicitationAnswer) {
    self.answer = answer
  }

  init(from decoder: any Decoder) throws {
    answer = try ElicitationAction(from: decoder).answer
  }

  func encode(to encoder: any Encoder) throws {
    try ElicitationAction(answer).encode(to: encoder)
  }
}

/// A transport that keeps the session's notes with what it logs (a session host's).
nonisolated protocol NoteSink: AnyObject {
  func note(_ bytes: Data)
}

/// The host logs a note with the process's own lines.
extension HostedProcess: NoteSink {}
