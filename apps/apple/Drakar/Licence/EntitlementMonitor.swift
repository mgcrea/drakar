import Foundation
import Observation

/// The licence gate, in one place.
///
/// DIVERGES from armada, whose gate is whether its watchers run at all: Drakar has no
/// watchers to stop, so here the gate is whether work may be sent to an agent. Refused,
/// `AgentSession.canSend` and `canQueue` answer false, and every prompt goes through
/// `AgentSession.send`, which reads them: the composer, Yes and No, skills, fan-out and
/// the debug prompts are all one check. Reading stays free, and a turn already running
/// keeps going, its permissions, questions and Stop untouched (none of them reads
/// `canSend`). The views then only have to say why the composer is not there,
/// `LockedComposerCard`, rather than each deciding what to hide.
///
/// Everything that can change the answer goes through here: launch, a trial starting, a
/// key entered or removed, and the trial window closing. That is what keeps the bridge,
/// the composer and what the windows say from disagreeing.
///
/// It is also a few lines anyone reading the source can find and remove. See
/// `LicenseKey` for why that is accepted rather than defended against.
@MainActor
@Observable
final class EntitlementMonitor {
  static let shared = EntitlementMonitor()

  /// Tests only: forces `allowsWork` for the current task, so parallel suites never share
  /// a flipped global. Task-local, as `ClaudeChoice.testSuite` is.
  @TaskLocal static var forced: Bool?

  /// What `AgentSession.canSend`/`canQueue` read: `forced ?? shared.allowsWork`.
  static var allowsWorkNow: Bool { forced ?? shared.allowsWork }

  /// DIVERGES from armada, which only shipped once it was selling: while nothing is sold,
  /// nothing is gated. A Drakar refusing work with nothing to buy would be a trap.
  var isSelling: Bool

  /// Read by every view that shows the gate. Stored rather than computed so a
  /// change is observed; `apply()` is the only writer.
  private(set) var current: Entitlement

  /// Where the answer comes from: `Entitlement.current` in the app. A parameter so a test
  /// can reach the states the process's own trial cannot, since a trial once started in
  /// the test process cannot be ended.
  @ObservationIgnored private let entitlement: () -> Entitlement

  /// DIVERGES from armada's private `init()`: instances are built by the tests, and only
  /// `shared` ever drives the IDE bridge (`apply()`).
  init(
    isSelling: Bool = LicenceLinks.isSelling,
    entitlement: @escaping () -> Entitlement = { Entitlement.current }
  ) {
    self.isSelling = isSelling
    self.entitlement = entitlement
    current = entitlement()
  }

  /// Whether work may be sent to an agent now.
  var allowsWork: Bool { Self.forced ?? isEntitled }

  /// The answer without a test's `forced`, for what the whole process shares.
  private var isEntitled: Bool { !isSelling || current.isEntitled }

  /// Bring the IDE bridge in line with the entitlement, as armada brings its MCP server:
  /// an unlicensed Drakar advertises itself to no terminal `claude`. Idempotent both ways:
  /// `start()` returns early when already listening and `stop()` when stopped.
  ///
  /// The bridge reads the unforced answer: it is one per process, and a test's task-local
  /// refusal must not take it down under every other suite. Only `shared` touches it.
  func apply() {
    current = entitlement()
    guard self === Self.shared else { return }
    if isEntitled {
      IDEBridge.shared.start()
    } else {
      IDEBridge.shared.stop()
    }
  }

  func startTrial() {
    Trial.start()
    apply()
  }

  @discardableResult
  func enterKey(_ key: String) -> LicenseCheck {
    let result = LicenseStore.store(key)
    apply()
    return result
  }

  func removeKey() {
    LicenseStore.clear()
    apply()
  }
}
