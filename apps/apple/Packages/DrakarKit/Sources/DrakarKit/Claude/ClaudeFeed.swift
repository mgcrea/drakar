import Foundation

/// A transcript fed Claude Code's stream-json and transcript lines: a `Transcript` and the
/// `ClaudeTranslator` that reads for it. What tests and `Transcript.history` use; a session
/// keeps the two apart, its translator in its backend.
@dynamicMemberLookup
public struct ClaudeFeed: Sendable {
  public private(set) var transcript = Transcript()
  private var translator = ClaudeTranslator()

  public init() {}

  public subscript<Value>(dynamicMember path: KeyPath<Transcript, Value>) -> Value {
    transcript[keyPath: path]
  }

  /// `time` is when the line arrived.
  public mutating func apply(_ message: StreamMessage, at time: Date = .now) {
    for event in translator.translate(message, at: time) { transcript.apply(event, at: time) }
  }

  /// One transcript-file line.
  public mutating func applyHistory(_ json: JSONValue) {
    let time = ClaudeTranslator.timestamp(of: json)
    for event in translator.history(json) { transcript.apply(event, at: time ?? .now) }
  }

  // What the person does, as on a `Transcript`.

  public mutating func addPrompt(
    _ text: String, context: String? = nil, attachments: [AttachmentPreview] = [],
    uuid: String? = nil, running: Bool = true, at time: Date = .now
  ) {
    transcript.addPrompt(
      text, context: context, attachments: attachments, uuid: uuid, running: running, at: time)
  }

  public mutating func queue(_ prompt: QueuedPrompt) { transcript.queue(prompt) }
  public mutating func resolvePermission(requestID: String) {
    transcript.resolvePermission(requestID: requestID)
  }
  public mutating func resolveElicitation(requestID: String, with answer: ElicitationAnswer) {
    transcript.resolveElicitation(requestID: requestID, with: answer)
  }
  public mutating func processExited() { transcript.processExited() }
  public mutating func noteColdCache(at now: Date = .now) { transcript.noteColdCache(at: now) }
  public func grouped() -> (top: [Transcript.Entry], children: [String: [Transcript.Entry]]) {
    transcript.grouped()
  }
}
