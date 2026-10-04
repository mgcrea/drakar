import Foundation

/// A project window's sidebar, below the sessions it holds: those live elsewhere, and
/// those that ended.
public struct ProjectGroups: Sendable, Equatable {
  /// Live in a terminal, VS Code or another Drakar window: newest activity first.
  public var elsewhere: [SessionSummary]
  /// Newest first.
  public var ended: [SessionSummary]
}

public enum ProjectSessions {
  /// `summaries` sorted into a project's groups.
  ///
  /// A session belongs to the deepest open project containing its `cwd`, so a deeper window
  /// (`otherFolders`) takes its own. `attached` ids are the window's own rows and are left
  /// out. `inOtherWindows` ids are open in another Drakar window, which the registry does
  /// not say: Drakar's own children are not read from it. One id under two accounts is one
  /// conversation, and keeps its newer transcript.
  public static func group(
    _ summaries: [SessionSummary], folder: String, otherFolders: [String],
    attached: Set<String>, inOtherWindows: Set<String>
  ) -> ProjectGroups {
    let folders = [folder] + otherFolders
    let own = ProjectPath.normalize(folder)
    let owners = ProjectPath.Owners(folders)
    var newest: [String: SessionSummary] = [:]
    for summary in summaries where !attached.contains(summary.sessionID) {
      guard let cwd = summary.cwd, owners.owner(of: cwd) == own else {
        continue
      }
      if let kept = newest[summary.sessionID], kept.modified >= summary.modified { continue }
      newest[summary.sessionID] = summary
    }
    let isElsewhere = { (summary: SessionSummary) in
      summary.live != nil || inOtherWindows.contains(summary.sessionID)
    }
    let activity = { (summary: SessionSummary) in summary.live?.updatedAt ?? summary.modified }
    return ProjectGroups(
      elsewhere: newest.values.filter(isElsewhere).sorted { a, b in
        activity(a) == activity(b) ? a.sessionID < b.sessionID : activity(a) > activity(b)
      },
      ended: newest.values.filter { !isElsewhere($0) }.sorted { a, b in
        a.modified == b.modified ? a.sessionID < b.sessionID : a.modified > b.modified
      })
  }
}
