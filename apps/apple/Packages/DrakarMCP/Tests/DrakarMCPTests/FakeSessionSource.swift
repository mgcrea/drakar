import DrakarKit
import Foundation

@testable import DrakarMCP

/// Drakar in memory. Every read answers what a test stored; every write records itself in
/// `calls`, with its arguments, and keeps what it was handed, so a test can check the tool
/// passed the source what it meant to.
final class FakeSessionSource: SessionSource, @unchecked Sendable {
  private let lock = NSLock()

  // MARK: Reads, settable per test

  private var _sessions: [SessionRow] = []
  private var _ended: [SessionRow] = []
  private var _details: [String: SessionDetail] = [:]
  private var _attention: [AttentionItem] = []
  private var _transcripts: [String: Transcript] = [:]
  private var _projects: [ProjectRow] = []
  private var _runner: RunnerStatus?
  private var _refusal: String?
  private var _allowsPermissions = false
  private var _liveThen: [[SessionRow]] = []
  private var _attentionThen: [[AttentionItem]] = []

  /// Live sessions, served first.
  var sessions: [SessionRow] {
    get { lock.withLock { _sessions } }
    set { lock.withLock { _sessions = newValue } }
  }
  /// Ended sessions, newest first, served after the live ones when asked for.
  var ended: [SessionRow] {
    get { lock.withLock { _ended } }
    set { lock.withLock { _ended = newValue } }
  }
  var details: [String: SessionDetail] {
    get { lock.withLock { _details } }
    set { lock.withLock { _details = newValue } }
  }
  var attentionItems: [AttentionItem] {
    get { lock.withLock { _attention } }
    set { lock.withLock { _attention = newValue } }
  }
  /// A session with none throws `transcriptMissing`.
  var transcripts: [String: Transcript] {
    get { lock.withLock { _transcripts } }
    set { lock.withLock { _transcripts = newValue } }
  }
  var projectRows: [ProjectRow] {
    get { lock.withLock { _projects } }
    set { lock.withLock { _projects = newValue } }
  }
  var runnerStatus: RunnerStatus? {
    get { lock.withLock { _runner } }
    set { lock.withLock { _runner = newValue } }
  }
  /// What `workRefusal()` answers: nil lets work through.
  var refusal: String? {
    get { lock.withLock { _refusal } }
    set { lock.withLock { _refusal = newValue } }
  }
  var allowsPermissions: Bool {
    get { lock.withLock { _allowsPermissions } }
    set { lock.withLock { _allowsPermissions = newValue } }
  }

  /// What `sessions` becomes after each look at the live sessions alone, one list per look:
  /// a session moving under `drakar_wait`'s polls. A look that asks for ended sessions too,
  /// as resolving an id does, leaves it be.
  var liveThen: [[SessionRow]] {
    get { lock.withLock { _liveThen } }
    set { lock.withLock { _liveThen = newValue } }
  }
  /// What `attentionItems` becomes after each `attention()`, one list per call.
  var attentionThen: [[AttentionItem]] {
    get { lock.withLock { _attentionThen } }
    set { lock.withLock { _attentionThen = newValue } }
  }

  // MARK: Writes, settable per test

  private var _startedID = "new-session"
  private var _sendOutcome = SendOutcome.sent
  private var _writeError: SessionError?

  /// The id `start` returns.
  var startedID: String {
    get { lock.withLock { _startedID } }
    set { lock.withLock { _startedID = newValue } }
  }
  var sendOutcome: SendOutcome {
    get { lock.withLock { _sendOutcome } }
    set { lock.withLock { _sendOutcome = newValue } }
  }
  /// When set, every write throws it after recording itself.
  var writeError: SessionError? {
    get { lock.withLock { _writeError } }
    set { lock.withLock { _writeError = newValue } }
  }

  // MARK: What the writes received

  private var _calls: [String] = []
  private var _started: StartRequest?
  private var _decision: PermissionDecision?
  private var _elicitationAnswer: ElicitationAnswer?
  private var _answered: RequestID?

  /// Each write, in order: `"start <folder> <prompt>"`, `"send <id> <text>"`,
  /// `"interrupt <id>"`, `"end <id>"`, `"permission <id> <raw requestID>"`,
  /// `"elicitation <id> <raw requestID>"`.
  var calls: [String] { lock.withLock { _calls } }
  /// The last request `start` received.
  var started: StartRequest? { lock.withLock { _started } }
  /// The last permission decision received.
  var decision: PermissionDecision? { lock.withLock { _decision } }
  /// The last elicitation answer received.
  var elicitationAnswer: ElicitationAnswer? { lock.withLock { _elicitationAnswer } }
  /// The request the last answer named, with its fingerprint.
  var answered: RequestID? { lock.withLock { _answered } }

  static let transcriptMissing = SessionError("No transcript for that session.")

  // MARK: SessionSource

  func sessions(includeEnded: Bool, endedLimit: Int) async -> [SessionRow] {
    lock.withLock {
      let answer = _sessions + (includeEnded ? Array(_ended.prefix(endedLimit)) : [])
      if !includeEnded, !_liveThen.isEmpty { _sessions = _liveThen.removeFirst() }
      return answer
    }
  }

  func detail(of id: String) async -> SessionDetail? { lock.withLock { _details[id] } }

  func attention() async -> [AttentionItem] {
    lock.withLock {
      let answer = _attention
      if !_attentionThen.isEmpty { _attention = _attentionThen.removeFirst() }
      return answer
    }
  }

  func transcript(of id: String) async throws -> Transcript {
    guard let transcript = lock.withLock({ _transcripts[id] }) else {
      throw Self.transcriptMissing
    }
    return transcript
  }

  func projects() async -> [ProjectRow] { lock.withLock { _projects } }
  func runner() async -> RunnerStatus? { lock.withLock { _runner } }
  func workRefusal() async -> String? { lock.withLock { _refusal } }
  func permissionsAllowed() async -> Bool { lock.withLock { _allowsPermissions } }

  func start(_ request: StartRequest) async throws -> String {
    try record("start \(request.folder) \(request.prompt)") {
      _started = request
      return _startedID
    }
  }

  func send(to id: String, text: String) async throws -> SendOutcome {
    try record("send \(id) \(text)") { _sendOutcome }
  }

  func interrupt(_ id: String) async throws {
    try record("interrupt \(id)") {}
  }

  func end(_ id: String) async throws {
    try record("end \(id)") {}
  }

  func answer(_ id: String, requestID: RequestID, with decision: PermissionDecision)
    async throws
  {
    try record("permission \(id) \(requestID.raw)") {
      _answered = requestID
      _decision = decision
    }
  }

  func answer(_ id: String, requestID: RequestID, with answer: ElicitationAnswer) async throws {
    try record("elicitation \(id) \(requestID.raw)") {
      _answered = requestID
      _elicitationAnswer = answer
    }
  }

  /// Logs the call and keeps what it was handed, under the lock, then throws `writeError`
  /// if a test set one.
  private func record<T>(_ call: String, _ keep: () -> T) throws -> T {
    let (result, error) = lock.withLock {
      _calls.append(call)
      return (keep(), _writeError)
    }
    if let error { throw error }
    return result
  }
}
