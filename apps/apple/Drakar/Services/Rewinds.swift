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
  /// request waiting, is ignored.
  func answered(_ signal: SessionSignal) {
    guard case .rewindAnswered(let messageID, let dryRun, let result) = signal,
      let outstanding, outstanding.messageID == messageID, outstanding.dryRun == dryRun
    else { return }
    self.outstanding = nil
    attempt += 1
    guard let result, result.canRewind else {
      if dryRun, result?.hasNoCheckpoint == true {
        phase = .failed(RewindCopy.noCheckpoint)
      } else {
        fail(detail: result?.error)
      }
      return
    }
    phase = dryRun ? .ready(result) : .done
  }

  /// The process went: what it was asked will not be answered.
  func processEnded() {
    guard outstanding != nil else { return }
    outstanding = nil
    attempt += 1
    fail(detail: nil)
  }

  /// `path` relative to `folder` when it is inside it, else whole: a file outside the
  /// project (`~/.zshrc`) never looks like one of its own. Either side may name the folder
  /// through a link (`/var` for `/private/var`), so each is read both ways.
  func shownPath(_ path: String) -> String {
    let file = URL(filePath: path)
    let whole = file.standardizedFileURL.path(percentEncoded: false)
    guard let folder else { return whole }
    let files = [whole, file.resolvingSymlinksInPath().path(percentEncoded: false)]
    let bases = [folder.standardizedFileURL, folder.resolvingSymlinksInPath()].map {
      let base = $0.path(percentEncoded: false)
      return base.hasSuffix("/") ? base : base + "/"
    }
    for base in bases {
      for file in files where file.hasPrefix(base) && file.count > base.count {
        return String(file.dropFirst(base.count))
      }
    }
    return whole
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
      guard let self, self.attempt == attempt, self.outstanding != nil else { return }
      self.outstanding = nil
      self.fail(detail: nil)
    }
  }

  private func fail(detail: String?) {
    phase = .failed(RewindCopy.failed)
    self.detail = detail
  }
}
