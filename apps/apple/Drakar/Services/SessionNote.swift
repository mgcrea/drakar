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
  case none
}

/// A transport that keeps the session's notes with what it logs (a session host's).
nonisolated protocol NoteSink: AnyObject {
  func note(_ bytes: Data)
}
