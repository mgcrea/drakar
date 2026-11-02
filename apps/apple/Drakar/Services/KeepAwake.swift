import DrakarKit
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle sleep while an agent works, as `caffeinate -i` would: from a
/// prompt to the end of its turn, unless Settings › General turns it off. Not while it waits
/// on the person (a permission, a question), who may be away. The display still sleeps, and
/// a laptop closed on battery sleeps anyway.
///
/// Two holders, so a turn handed over keeps the Mac awake to its end. The app holds one
/// assertion while a session of this Mac's works, and marks each hosted session at work with
/// the session host (`HostedProcess.keepAwake(until:)`), which holds its own until the agent
/// stops (`AgentKind.pauses`), with or without the app. Work that goes on after a stop the
/// app saw (an answer, a queued prompt's turn) is marked again, by `Transcript.pauses`. A
/// window that closes, or a quit, leaves its marks with the host, and the setting turned off
/// takes back only those of sessions still in a window. A runner's sessions are marked with
/// the runner's host, which keeps that Mac awake, not this one.
final class KeepAwake {
  static let shared = KeepAwake()

  /// Whether Settings has it on; on unless turned off.
  static var isOn: Bool {
    UserDefaults.standard.object(forKey: PreferenceKey.keepsAwake) as? Bool ?? true
  }

  private var assertion: IOPMAssertionID?
  /// The sessions the assertion is named for.
  private var held = 0
  /// The sessions at work when last looked, with the pauses their transcript had counted.
  private var working: [ObjectIdentifier: Int] = [:]
  /// Per session, the hosted process marked, and after how many pauses.
  private var marked: [ObjectIdentifier: Mark] = [:]
  private var following: Task<Void, Never>?

  /// Follows every window's sessions from now on.
  func start() {
    guard following == nil else { return }
    following = Task {
      for await working in Observations({ @MainActor in Self.working() })
      where working != self.working {
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
      let pauses = isOn ? working[id] : nil
      if pauses != nil, !session.isOnRunner { here += 1 }
      mark(session, after: pauses)
    }
    // Gone with its window: the host keeps the mark until the agent stops.
    marked = marked.filter { seen.contains($0.key) }
    hold(here)
  }

  /// The sessions of every window at work, with their pauses: in a turn and asking nothing.
  /// Those that follow another app's are not Drakar's to keep awake for.
  static func working() -> [ObjectIdentifier: Int] {
    var working: [ObjectIdentifier: Int] = [:]
    for session in OpenSessions.shared.projects.values.flatMap(\.sessions).map(\.session)
    where session.transcript.isRunning && !session.transcript.isWaitingOnPerson
      && !session.isReadOnly
    {
      working[ObjectIdentifier(session)] = session.transcript.pauses
    }
    return working
  }

  /// What `pmset -g assertions` shows for `count` sessions at work.
  static func name(working count: Int) -> String {
    count == 1 ? "Drakar: a session is working" : "Drakar: \(count) sessions are working"
  }

  private struct Mark: Equatable {
    var process: ObjectIdentifier
    var pauses: Int
  }

  /// Marks the session's hosted process when it works, `pauses` being how many times it had
  /// stopped; again after each further stop, which the host let go at. Takes it back when not.
  private func mark(_ session: AgentSession, after pauses: Int?) {
    let id = ObjectIdentifier(session)
    let hosted = session.process as? HostedProcess
    let wanted = hosted.flatMap { hosted in
      pauses.map { Mark(process: ObjectIdentifier(hosted), pauses: $0) }
    }
    guard wanted != marked[id] else { return }
    if let hosted, let wanted {
      hosted.keepAwake(until: session.agent.pauses)
      marked[id] = wanted
      return
    }
    // A process started since the mark has none to take back.
    if let hosted, marked[id]?.process == ObjectIdentifier(hosted) {
      hosted.keepAwake(until: [])
    }
    marked[id] = nil
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
  /// What a line the CLI writes holds when the agent stops working, for the session host,
  /// which reads no line itself: exactly the lines that count a `Transcript.pauses`. Claude
  /// Code's `result`, and its `can_use_tool` and `elicitation` requests; Codex's
  /// `turn/completed` and its approval requests. Both print compact JSON, where a string's
  /// quotes are escaped; a tool's input is an object, though, and one holding these bytes
  /// would let the Mac sleep early.
  var pauses: [Data] {
    let markers =
      switch self {
      case .claude:
        [#""type":"result""#, #""subtype":"can_use_tool""#, #""subtype":"elicitation""#]
      case .codex:
        [
          #""method":"turn/completed""#, #""method":"item/commandExecution/requestApproval""#,
          #""method":"item/fileChange/requestApproval""#,
        ]
      }
    return markers.map { Data($0.utf8) }
  }
}
