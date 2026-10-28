import DrakarKit
import Foundation

/// Sessions the session host keeps that no app shows, by tracked project: a window handed
/// them over, or the app quit. One running or waiting is the registry's to count, as busy
/// or waiting; the rest sit between turns until their project's window takes them back.
enum BackgroundSessions {
  static func count(
    held: [HeldProcess], live: [LiveSession], owners: ProjectPath.Owners
  ) -> [String: Int] {
    let atWork = Set(
      live.filter { $0.status == "busy" || $0.status == "waiting" }.map(\.sessionID))
    var counts: [String: Int] = [:]
    for process in held where process.running && process.attachedApp == nil {
      guard let meta = try? JSONDecoder().decode(SessionMeta.self, from: process.meta),
        let owner = owners.owner(of: meta.windowFolder),
        !(meta.sessionID.map(atWork.contains) ?? false)
      else { continue }
      counts[owner, default: 0] += 1
    }
    return counts
  }
}
