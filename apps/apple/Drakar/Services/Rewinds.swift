import DrakarKit
import Foundation
import Observation

/// A session's code rewind, from the dry run to the outcome: what the sheet shows. Nothing
/// is written before the person saw the dry run's list and confirmed it (`confirm`). The
/// session sends what it asks (never noted, as the task controls are) and hands it the
/// replies.
@Observable
final class Rewinds {
  enum Phase: Equatable {
    /// The dry run is out.
    case checking
    /// The dry run's answer, canRewind true.
    case ready(RewindResult)
    case rewinding
    /// `RewindCopy.succeeded`.
    case done
    /// `RewindCopy.failed` or `.noCheckpoint`; the CLI's own words are in `detail`.
    case failed(String)
  }

  struct Request: Equatable {
    var messageID: String
    /// Fork and rewind: the fork follows a rewind that took.
    var thenFork: Bool
  }

  /// What the sheet is for, from `start` until `cancel`.
  private(set) var request: Request?
  private(set) var phase: Phase?
  /// The CLI's error behind a `.failed` other than no checkpoint, which says it already;
  /// nil when there was no reply or the CLI gave no words.
  private(set) var detail: String?
  /// The session's folder, so paths inside it are shown relative to it.
  var folder: URL?

  /// Settable so that a session can hand a closure over itself once it exists. False when
  /// nothing took the command: no process, or one the session may not rewind now.
  @ObservationIgnored var send: (AgentCommand) -> Bool
  @ObservationIgnored private let timeout: Duration
  /// The one request waiting on a reply; any other reply is not this one's.
  @ObservationIgnored private var outstanding: (messageID: String, dryRun: Bool)?
  /// Bumped by each request and by `cancel`: a timeout fails only the request it was set for.
  @ObservationIgnored private var attempt = 0
  /// A real rewind whose reply did not come in time, and the `attempt` its failure showed
  /// at. The CLI may still be writing: a late success is still a rewind that took.
  @ObservationIgnored private var late: (messageID: String, attempt: Int)?

  init(timeout: Duration = .seconds(10), send: @escaping (AgentCommand) -> Bool = { _ in false }) {
    self.timeout = timeout
    self.send = send
  }

  /// Sends the dry run. Nothing goes while another request waits on its reply.
  func start(_ request: Request) {
    guard outstanding == nil else { return }
    self.request = request
    detail = nil
    phase = .checking
    ask(dryRun: true)
  }

  /// From `.ready` only: sends the real rewind.
  func confirm() {
    guard case .ready = phase, outstanding == nil else { return }
    phase = .rewinding
    ask(dryRun: false)
  }

  /// Closes the sheet; nothing more is written, and a late reply opens nothing.
  func cancel() {
    attempt += 1
    outstanding = nil
    request = nil
    phase = nil
    detail = nil
  }

  /// A reply the session received; every other signal, and a reply for anything but the
  /// request waiting, is ignored, except a late success for a real rewind that timed out.
  /// True when it says a rewind took, for the session's note.
  @discardableResult func answered(_ signal: SessionSignal) -> Bool {
    guard case .rewindAnswered(let messageID, let dryRun, let result) = signal else {
      return false
    }
    guard let outstanding, outstanding.messageID == messageID, outstanding.dryRun == dryRun
    else { return answeredLate(messageID: messageID, dryRun: dryRun, result) }
    self.outstanding = nil
    attempt += 1
    if !dryRun { late = nil }
    guard let result, result.canRewind else {
      // Whichever request found it: the extension's line for a prompt with no snapshot.
      if result?.hasNoCheckpoint == true {
        phase = .failed(RewindCopy.noCheckpoint)
      } else {
        fail(detail: result?.error)
      }
      return false
    }
    phase = dryRun ? .ready(result) : .done
    return !dryRun
  }

  /// A real rewind's success after its timeout said it failed: the files were written. The
  /// sheet still showing that failure moves on to `.done`, as if the reply had come in time
  /// (and so Fork and rewind still forks); a sheet closed or started again since stays as
  /// it is. A dry run's late reply, or a late refusal, changes nothing.
  private func answeredLate(messageID: String, dryRun: Bool, _ result: RewindResult?) -> Bool {
    guard !dryRun, let late, late.messageID == messageID else { return false }
    self.late = nil
    guard result?.canRewind == true else { return false }
    if attempt == late.attempt, request?.messageID == messageID {
      detail = nil
      phase = .done
    }
    return true
  }

  /// The process went: what it was asked will not be answered.
  func processEnded() {
    // A process gone answers nothing late either.
    late = nil
    guard outstanding != nil else { return }
    outstanding = nil
    attempt += 1
    fail(detail: nil)
  }

  /// A turn started in the session: a dry run's list, out or shown, may no longer hold.
  /// The sheet fails rather than rewind what the agent may be changing again. A rewind
  /// already sent is left to its reply.
  func turnStarted() {
    switch phase {
    case .checking, .ready:
      outstanding = nil
      attempt += 1
      fail(detail: nil)
    default:
      break
    }
  }

  /// `path` relative to `folder` when it is inside it, else whole: a file outside the
  /// project (`~/.zshrc`) never looks like one of its own. Either side may name the folder
  /// through a link (`/var` for `/private/var`, a linked project), so each is read as given
  /// and resolved (`resolved(_:)`).
  func shownPath(_ path: String) -> String {
    let file = URL(filePath: path)
    let whole = file.standardizedFileURL.path(percentEncoded: false)
    guard let folder else { return whole }
    let files = [whole, Self.resolved(file)]
    let bases = [folder.standardizedFileURL.path(percentEncoded: false), Self.resolved(folder)]
      .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    for base in bases {
      for file in files where file.hasPrefix(base) && file.count > base.count {
        return String(file.dropFirst(base.count))
      }
    }
    return whole
  }

  /// `url` with its links resolved, through its deepest ancestor that exists: a file a
  /// rewind restores may not exist yet, and `resolvingSymlinksInPath()` leaves a missing
  /// path as it is.
  private static func resolved(_ url: URL) -> String {
    var existing = url.standardizedFileURL
    var rest: [String] = []
    while existing.pathComponents.count > 1,
      !FileManager.default.fileExists(atPath: existing.path(percentEncoded: false))
    {
      rest.insert(existing.lastPathComponent, at: 0)
      existing.deleteLastPathComponent()
    }
    var resolved = existing.resolvingSymlinksInPath()
    for component in rest { resolved.append(path: component) }
    return resolved.path(percentEncoded: false)
  }

  private func ask(dryRun: Bool) {
    guard let request else { return }
    attempt += 1
    outstanding = (request.messageID, dryRun)
    guard send(.rewindFiles(userMessageID: request.messageID, dryRun: dryRun)) else {
      outstanding = nil
      return fail(detail: nil)
    }
    let attempt = attempt
    Task { [weak self, timeout] in
      try? await Task.sleep(for: timeout)
      guard let self, self.attempt == attempt, let outstanding = self.outstanding else { return }
      self.outstanding = nil
      self.fail(detail: nil)
      if !outstanding.dryRun { self.late = (outstanding.messageID, self.attempt) }
    }
  }

  private func fail(detail: String?) {
    phase = .failed(RewindCopy.failed)
    self.detail = detail
  }
}
