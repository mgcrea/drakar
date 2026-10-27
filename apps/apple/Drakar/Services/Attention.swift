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

  /// How much a session live outside Drakar wants the person, from its registry and its
  /// transcript's end: waiting is a permission, or a choice when the call it waits on is an
  /// `AskUserQuestion`; done with a turn that ended on a question or an offer, that, unless
  /// `dismissed` is that message. Busy, ended, or Drakar's own (no registry entry): nothing.
  static func of(
    _ summary: SessionSummary, recognisesAsks: Bool, dismissed: String?
  ) -> Urgency? {
    guard let live = summary.live else { return nil }
    switch live.status {
    case "waiting": return summary.pendingQuestion == nil ? .permission : .choice
    case "busy": return nil
    default:
      guard recognisesAsks, let ask = summary.closingAsk,
        summary.closingMessageID != dismissed
      else { return nil }
      return ask.kind == .question ? .question : .offer
    }
  }

  /// What a session elsewhere at this level wants, for its row's second line and the
  /// notification: the registry's own words for a permission ("permission prompt").
  func wants(of summary: SessionSummary) -> String? {
    switch self {
    case .permission: summary.live?.waitingFor
    case .choice: summary.pendingQuestion
    case .question, .offer: summary.closingAsk?.text
    }
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
/// by level, and a local notification unless the session is the one in front of them. A
/// window's own sessions, and those of its folder live in a terminal or VS Code.
final class Attention: NSObject, UNUserNotificationCenterDelegate {
  static let shared = Attention()

  /// Asked once; every post awaits the same answer, so one made during the prompt waits.
  private var authorization: Task<Bool, Never>?
  /// Sessions with a notification on screen that wants an answer: withdrawn when the row
  /// no longer wants the person, however that came about.
  private var asking: Set<String> = []
  /// Per session live elsewhere, what it last wanted (`newsKey`, "" for nothing): a change
  /// is news, a session first seen (a window opening, the app launching) is not.
  private var seenElsewhere: [String: String] = [:]

  var waitingCount: Int { waitingCount(elsewhere: elsewhere()) }

  private func waitingCount(
    elsewhere: [String: (project: Project, summary: SessionSummary, level: Urgency?)]
  ) -> Int {
    let badges = { AttentionChoice.isOn($0, .badges) }
    return Self.count(OpenSessions.shared.projects.values.flatMap(\.sessions), badges: badges)
      + elsewhere.values.count { $0.level.map(badges) ?? false }
  }

  /// Every session live elsewhere under an open window, once each, with the window it lists
  /// in and how much it wants the person.
  private func elsewhere() -> [String: (project: Project, summary: SessionSummary, level: Urgency?)]
  {
    var found: [String: (project: Project, summary: SessionSummary, level: Urgency?)] = [:]
    for project in OpenSessions.shared.projects.values {
      for summary in project.groups.elsewhere
      where summary.live != nil && found[summary.sessionID] == nil {
        found[summary.sessionID] = (project, summary, project.urgency(of: summary))
      }
    }
    return found
  }

  /// What makes a session elsewhere wanting the person news: its level, and the ask itself,
  /// so a second question after an answer notifies again.
  static func newsKey(_ summary: SessionSummary, level: Urgency?) -> String {
    guard let level else { return "" }
    return switch level {
    case .question, .offer: "\(level.rawValue)#\(summary.closingMessageID ?? "")"
    case .choice: "\(level.rawValue)#\(summary.pendingQuestion ?? "")"
    case .permission: level.rawValue
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
    let elsewhere = elsewhere()
    let count = waitingCount(elsewhere: elsewhere)
    NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
    notifyElsewhere(elsewhere)
    let answered = asking.filter { id in
      if let (_, item) = OpenSessions.shared.locate(id) { return item.urgency == nil }
      return elsewhere[id]?.level == nil
    }
    guard !answered.isEmpty else { return }
    asking.subtract(answered)
    UNUserNotificationCenter.current().removeDeliveredNotifications(
      withIdentifiers: Array(answered))
  }

  func permissionRequested(_ item: ProjectSession, in project: Project) {
    refresh()
    guard let level = item.urgency, AttentionChoice.isOn(level, .notifies),
      !inView(item, in: project), let wants = item.wants
    else { return }
    // A server's question says itself; only a tool is something it wants to use.
    let asksQuestion =
      item.pendingElicitation != nil && item.session.transcript.pendingPermissions.isEmpty
    let body =
      level == .choice || asksQuestion ? wants : String(localized: "Wants to use \(wants)")
    post(title: item.displayTitle, body: body, item: item, wantsAnswer: true)
  }

  func turnEnded(_ item: ProjectSession, in project: Project) {
    refresh()
    guard !inView(item, in: project),
      let notice = Self.turnEndNotice(
        ask: item.closingAsk, level: item.urgency,
        notifiesTurnEnds: AttentionChoice.notifiesTurnEnds,
        levelNotifies: { AttentionChoice.isOn($0, .notifies) })
    else { return }
    post(title: item.displayTitle, body: notice.body, item: item, wantsAnswer: notice.wantsAnswer)
  }

  /// A session elsewhere that came to want the person, or wants something new, notifies as
  /// its level is set to, unless it is the one watched in front of them.
  private func notifyElsewhere(
    _ found: [String: (project: Project, summary: SessionSummary, level: Urgency?)]
  ) {
    var seen: [String: String] = [:]
    for (id, entry) in found {
      let key = Self.newsKey(entry.summary, level: entry.level)
      seen[id] = key
      guard let before = seenElsewhere[id], before != key, let level = entry.level,
        AttentionChoice.isOn(level, .notifies), !inView(sessionID: id, in: entry.project)
      else { continue }
      let wants = level.wants(of: entry.summary)
      let body =
        switch level {
        case .permission: wants.map { String(localized: "Waiting for you: \($0)") }
        case .choice, .question, .offer: wants
        }
      post(
        title: entry.summary.displayTitle, body: body ?? RowState.waiting.label, sessionID: id,
        wantsAnswer: true)
    }
    seenElsewhere = seen
  }

  /// What a turn's end posts: its ask when that level notifies; otherwise "Finished its
  /// turn." when those are on, whatever the turn ended on; otherwise nothing.
  static func turnEndNotice(
    ask: ClosingAsk?, level: Urgency?, notifiesTurnEnds: Bool,
    levelNotifies: (Urgency) -> Bool
  ) -> (body: String, wantsAnswer: Bool)? {
    if let ask, let level, levelNotifies(level) { return (ask.text, true) }
    return notifiesTurnEnds ? (String(localized: "Finished its turn."), false) : nil
  }

  /// A session this window ran was taken up by another process, and the window gave it
  /// way: said unless it is in front of the person, where the banner says it.
  func continuedElsewhere(_ item: ProjectSession, in project: Project) {
    guard !inView(item, in: project), let id = item.sessionID,
      let summary = SessionMonitor.shared.all.first(where: { $0.sessionID == id })
    else { return }
    let host = SessionMonitor.shared.host(of: summary, excluding: project)
    post(
      title: item.displayTitle, body: String(localized: "Continued in \(host)."), item: item,
      wantsAnswer: false)
  }

  private func inView(_ item: ProjectSession, in project: Project) -> Bool {
    Self.isInView(
      appIsActive: NSApp.isActive, windowIsKey: project.workspace.window?.isKeyWindow == true,
      rowIsSelected: project.selectedID == item.id)
  }

  /// A session elsewhere is in front of the person when the key window watches it.
  private func inView(sessionID: String, in project: Project) -> Bool {
    Self.isInView(
      appIsActive: NSApp.isActive, windowIsKey: project.workspace.window?.isKeyWindow == true,
      rowIsSelected: project.selected?.sessionID == sessionID)
  }

  private func post(title: String, body: String, item: ProjectSession, wantsAnswer: Bool) {
    guard let sessionID = item.sessionID else { return }
    post(title: title, body: body, sessionID: sessionID, wantsAnswer: wantsAnswer)
  }

  private func post(title: String, body: String, sessionID: String, wantsAnswer: Bool) {
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

  /// A click brings the session's window forward with its row selected; one live elsewhere,
  /// watched there.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard let id = response.notification.request.content.userInfo["sessionID"] as? String
    else { return }
    await MainActor.run {
      let project: Project
      if let (owner, item) = OpenSessions.shared.locate(id) {
        owner.select(item)
        project = owner
      } else if let entry = elsewhere()[id] {
        entry.project.openElsewhere(entry.summary)
        project = entry.project
      } else {
        return
      }
      NSApp.activate()
      project.workspace.window?.makeKeyAndOrderFront(nil)
    }
  }
}
