import Foundation

/// Where Claude Code writes a subagent's own conversation: beside its session's transcript,
/// `<session id>/subagents/agent-<agent id>.jsonl` (2.1.312). Its conversation lines are all
/// `isSidechain`, so read it with `TranscriptFollower(file:includesSidechains: true)`.
public enum SubagentTranscript {
  /// `<transcript minus .jsonl>/subagents/agent-<agentID>.jsonl` if it exists, else the same
  /// name under any other session folder beside it; nil when agentID isn't
  /// ^[A-Za-z0-9_-]{1,128}$ or nothing exists.
  ///
  /// The other folders are for a fork, whose agents are written under the fork's own
  /// session id rather than the transcript it was read from.
  public static func file(agentID: String, transcriptFile: URL) -> URL? {
    guard isName(agentID) else { return nil }
    if let file = ownFile(agentID: agentID, transcriptFile: transcriptFile) { return file }
    let name = "agent-\(agentID).jsonl"
    let own = transcriptFile.deletingPathExtension()
    let folder = transcriptFile.deletingLastPathComponent()
    let siblings =
      (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    for sibling in siblings.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      guard sibling.lastPathComponent != own.lastPathComponent,
        (try? sibling.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
      else { continue }
      let file = sibling.appending(components: "subagents", name)
      if isFile(file) { return file }
    }
    return nil
  }

  /// `<transcript minus .jsonl>/subagents/agent-<agentID>.jsonl` if it exists, without the
  /// look through the folders beside it that `file` makes; nil for an ID that isn't a name.
  public static func ownFile(agentID: String, transcriptFile: URL) -> URL? {
    guard isName(agentID) else { return nil }
    let file = transcriptFile.deletingPathExtension()
      .appending(components: "subagents", "agent-\(agentID).jsonl")
    return isFile(file) ? file : nil
  }

  /// The extension's rule for an agent ID, `^[A-Za-z0-9_-]{1,128}$`: nothing that could
  /// leave the folder it is joined to.
  static func isName(_ id: String) -> Bool {
    let scalars = id.unicodeScalars
    return (1...128).contains(scalars.count)
      && scalars.allSatisfy { scalar in
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "-": true
        default: false
        }
      }
  }

  private static func isFile(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(
      atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && !isDirectory.boolValue
  }
}
