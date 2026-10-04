import AppKit
import DrakarKit
import UserNotifications

/// What wants the person while they look elsewhere: the Dock badge for permission requests
/// waiting in any window, and a local notification when Drakar is not the active app. Only
/// Drakar's own sessions: Armada notifies for every session on the Mac already.
final class Attention: NSObject, UNUserNotificationCenterDelegate {
  static let shared = Attention()

  /// Asked once; every post awaits the same answer, so one made during the prompt waits.
  private var authorization: Task<Bool, Never>?

  var waitingCount: Int {
    OpenSessions.shared.projects.values.reduce(0) { total, project in
      total + project.sessions.reduce(0) { $0 + $1.session.transcript.pendingPermissions.count }
    }
  }

  func refresh() {
    let count = waitingCount
    NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
  }

  /// A session's waiting requests changed: the badge follows, and a notification for
  /// requests that are no longer waiting is withdrawn.
  func permissionsChanged(_ item: ProjectSession?) {
    refresh()
    guard let item, item.waitingFor == nil, let id = item.sessionID else { return }
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
  }

  func permissionRequested(_ item: ProjectSession, in project: Project) {
    refresh()
    guard !NSApp.isActive, let wants = item.waitingFor else { return }
    post(title: item.displayTitle, body: String(localized: "Wants to use \(wants)"), item: item)
  }

  func turnEnded(_ item: ProjectSession, in project: Project) {
    refresh()
    guard !NSApp.isActive, UserDefaults.standard.bool(forKey: PreferenceKey.notifiesTurnEnds)
    else { return }
    post(title: item.displayTitle, body: String(localized: "Finished its turn."), item: item)
  }

  private func post(title: String, body: String, item: ProjectSession) {
    guard let sessionID = item.sessionID else { return }
    let center = UNUserNotificationCenter.current()
    let asking =
      authorization
      ?? Task { (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
    authorization = asking
    Task {
      _ = await asking.value
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
