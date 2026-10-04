import AppKit
import DrakarKit
import UserNotifications

/// How much a session wants the person, least first: an offer at the end of a turn, a
/// question at the end of a turn, an `AskUserQuestion` waiting on a choice, a tool waiting
/// on permission.
enum Urgency: String, CaseIterable, Comparable {
  case offer, question, choice, permission

  static func < (a: Urgency, b: Urgency) -> Bool {
    allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
  }

  /// Its row in the Attention pane.
  var title: String {
    switch self {
    case .permission: String(localized: "Permission request")
    case .choice: String(localized: "Choice to make")
    case .question: String(localized: "Question")
    case .offer: String(localized: "Offer")
    }
  }
}

/// What wants the person while they look elsewhere: the Dock badge for rows that want them,
/// by level, and a local notification unless the session is the one in front of them. Only
/// Drakar's own sessions: Armada notifies for every session on the Mac already.
final class Attention: NSObject, UNUserNotificationCenterDelegate {
  static let shared = Attention()

  /// Asked once; every post awaits the same answer, so one made during the prompt waits.
  private var authorization: Task<Bool, Never>?
  /// Sessions with a notification on screen that wants an answer: withdrawn when the row
  /// no longer wants the person, however that came about.
  private var asking: Set<String> = []

  var waitingCount: Int {
    Self.count(OpenSessions.shared.projects.values.flatMap(\.sessions)) {
      AttentionChoice.isOn($0, .badges)
    }
  }

  /// Rows of `items` whose level `badges`.
  static func count(_ items: [ProjectSession], badges: (Urgency) -> Bool) -> Int {
    items.count { $0.urgency.map(badges) ?? false }
  }

  /// The row the person is looking at, in the window they are in: nothing to tell them.
  static func isInView(appIsActive: Bool, windowIsKey: Bool, rowIsSelected: Bool) -> Bool {
    appIsActive && windowIsKey && rowIsSelected
  }

  /// The badge follows, and a notification whose session no longer wants anything goes.
  func refresh() {
    let count = waitingCount
    NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
    let answered = asking.filter { id in
      OpenSessions.shared.locate(id).map { $0.1.urgency == nil } ?? true
    }
    guard !answered.isEmpty else { return }
    asking.subtract(answered)
    UNUserNotificationCenter.current().removeDeliveredNotifications(
      withIdentifiers: Array(answered))
  }

  /// A session's waiting requests changed.
  func permissionsChanged(_ item: ProjectSession?) {
    refresh()
  }

  func permissionRequested(_ item: ProjectSession, in project: Project) {
    refresh()
    guard let level = item.urgency, AttentionChoice.isOn(level, .notifies),
      !inView(item, in: project), let wants = item.wants
    else { return }
    let body = level == .choice ? wants : String(localized: "Wants to use \(wants)")
    post(title: item.displayTitle, body: body, item: item, wantsAnswer: true)
  }

  func turnEnded(_ item: ProjectSession, in project: Project) {
    refresh()
    guard !inView(item, in: project) else { return }
    if let level = item.urgency, let ask = item.closingAsk {
      guard AttentionChoice.isOn(level, .notifies) else { return }
      post(title: item.displayTitle, body: ask.text, item: item, wantsAnswer: true)
    } else if AttentionChoice.notifiesTurnEnds {
      post(
        title: item.displayTitle, body: String(localized: "Finished its turn."), item: item,
        wantsAnswer: false)
    }
  }

  private func inView(_ item: ProjectSession, in project: Project) -> Bool {
    Self.isInView(
      appIsActive: NSApp.isActive, windowIsKey: project.workspace.window?.isKeyWindow == true,
      rowIsSelected: project.selectedID == item.id)
  }

  private func post(title: String, body: String, item: ProjectSession, wantsAnswer: Bool) {
    guard let sessionID = item.sessionID else { return }
    if wantsAnswer { asking.insert(sessionID) }
    let center = UNUserNotificationCenter.current()
    let asked =
      authorization
      ?? Task { (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
    authorization = asked
    Task {
      _ = await asked.value
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.userInfo = ["sessionID": sessionID]
      try? await center.add(
        UNNotificationRequest(identifier: sessionID, content: content, trigger: nil))
    }
  }

  /// A click brings the session's window forward with its row selected.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard let id = response.notification.request.content.userInfo["sessionID"] as? String
    else { return }
    await MainActor.run {
      guard let (project, item) = OpenSessions.shared.locate(id) else { return }
      project.select(item)
      NSApp.activate()
      project.workspace.window?.makeKeyAndOrderFront(nil)
    }
  }
}
