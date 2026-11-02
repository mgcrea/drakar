import DrakarKit
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle sleep while an agent works, as `caffeinate -i` would: from a
/// prompt to the end of its turn, unless Settings › General turns it off. The display still
/// sleeps, and a laptop closed on battery sleeps anyway.
///
/// Two holders, so a turn handed over keeps the Mac awake to its end. The app holds one
/// assertion while a session of this Mac's is in a turn, and marks each hosted turn with the
/// session host (`HostedProcess.keepAwake(until:)`), which holds its own until the line that
/// ends the turn, with or without the app. A window that closes, or a quit, leaves its marks
/// with the host: only a turn seen to end, or the setting turned off, takes one back. A
/// runner's turns are marked with the runner's host, which keeps that Mac awake, not this one.
final class KeepAwake {
  static let shared = KeepAwake()

  /// Whether Settings has it on; on unless turned off.
  static var isOn: Bool {
    UserDefaults.standard.object(forKey: PreferenceKey.keepsAwake) as? Bool ?? true
  }

  private var assertion: IOPMAssertionID?
  /// The sessions the assertion is named for.
  private var held = 0
  /// The sessions in a turn when last looked.
  private var working: Set<ObjectIdentifier> = []
  /// Per session, the hosted process its turn was marked with.
  private var marked: [ObjectIdentifier: ObjectIdentifier] = [:]
  private var following: Task<Void, Never>?

  /// Follows every window's sessions from now on.
  func start() {
    guard following == nil else { return }
    following = Task {
      for await working in Observations({ @MainActor in Self.working() }) {
        self.working = working
        apply()
      }
    }
  }

  /// Holds or lets go as the sessions and the setting now say: called again when it changes.
  func apply() {
    let isOn = Self.isOn
    var here = 0
    var seen: Set<ObjectIdentifier> = []
    for item in OpenSessions.shared.projects.values.flatMap(\.sessions) {
      let session = item.session
      let id = ObjectIdentifier(session)
      seen.insert(id)
      let works = isOn && working.contains(id)
      if works, !session.isOnRunner { here += 1 }
      mark(session, works)
    }
    // Gone with its window: the host keeps the mark until the turn ends.
    marked = marked.filter { seen.contains($0.key) }
    hold(here)
  }

  /// The sessions of every window in a turn: those that follow another app's are not
  /// Drakar's to keep awake for.
  static func working() -> Set<ObjectIdentifier> {
    Set(
      OpenSessions.shared.projects.values.flatMap(\.sessions)
        .map(\.session)
        .filter { $0.transcript.isRunning && !$0.isReadOnly }
        .map(ObjectIdentifier.init))
  }

  /// What `pmset -g assertions` shows for `count` sessions at work.
  static func name(working count: Int) -> String {
    count == 1 ? "Drakar: a session is working" : "Drakar: \(count) sessions are working"
  }

  private func mark(_ session: AgentSession, _ works: Bool) {
    let id = ObjectIdentifier(session)
    let hosted = session.process as? HostedProcess
    let process = hosted.map(ObjectIdentifier.init)
    guard (works ? process : nil) != marked[id] else { return }
    // A process started since the mark has none to take back.
    if !works, marked[id] == process { hosted?.keepAwake(until: nil) }
    if works, let hosted {
      hosted.keepAwake(until: session.agent.turnEnd)
      marked[id] = process
    } else {
      marked[id] = nil
    }
  }

  private func hold(_ count: Int) {
    guard count != held else { return }
    held = count
    guard count > 0 else {
      if let assertion { IOPMAssertionRelease(assertion) }
      assertion = nil
      return
    }
    let name = Self.name(working: count) as CFString
    if let assertion {
      IOPMAssertionSetProperty(assertion, kIOPMAssertionNameKey as CFString, name)
      return
    }
    var id = IOPMAssertionID(0)
    let created = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &id)
    if created == kIOReturnSuccess { assertion = id }
  }
}

extension AgentKind {
  /// What a line the CLI writes holds when it ends a turn, for the session host, which reads
  /// no line itself: Claude Code's `result`, Codex's `turn/completed`. Both print compact JSON,
  /// and inside a string the quotes would be escaped.
  var turnEnd: Data {
    switch self {
    case .claude: Data(#""type":"result""#.utf8)
    case .codex: Data(#""method":"turn/completed""#.utf8)
    }
  }
}
