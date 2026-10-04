import AppKit
import DrakarKit
import UserNotifications

/// What wants the person while they look elsewhere: the Dock badge for permission requests
/// waiting in any window, and a local notification when Drakar is not the active app. Only
/// Drakar's own sessions: Armada notifies for every session on the Mac already.
final class Attention: NSObject, UNUserNotificationCenterDelegate {
  static let shared = Attention()

  private var askedForPermission = false

  var waitingCount: Int {
    OpenSessions.shared.projects.values.reduce(0) { total, project in
      total + project.sessions.reduce(0) { $0 + $1.session.transcript.pendingPermissions.count }
    }
  }

  func refresh() {
    let count = waitingCount
    NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
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
    center.delegate = self
    Task {
      if !askedForPermission {
        askedForPermission = true
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
      }
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
