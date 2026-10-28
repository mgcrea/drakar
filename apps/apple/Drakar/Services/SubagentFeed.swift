import DrakarKit
import Foundation
import Observation

/// A subagent's file, followed while the card is open.
///
/// The file is looked for on the first refresh in the session's own folder and then in the
/// folders beside it (a fork's agents are written there, and already exist when the card
/// opens). Until it turns up, later refreshes look in the session's own folder only: the
/// look beside it lists the whole project folder. Once found, it is kept.
///
/// Made from a call's id alone (a subagent still running in a session read from its file,
/// with no task and no report to name it), each refresh first looks for the agent that call
/// started, until it is known.
@Observable final class SubagentFeed {
  /// nil: no file, so the card keeps its streamed children.
  private(set) var transcript: Transcript?

  /// nil until the call's agent is found.
  @ObservationIgnored private(set) var agentID: String?
  @ObservationIgnored let toolUseID: String?
  @ObservationIgnored let transcriptFile: URL
  @ObservationIgnored private var follower: TranscriptFollower?
  /// Everything folded in so far, shown once it holds an entry.
  @ObservationIgnored private var read = Transcript()
  @ObservationIgnored private var hasLooked = false

  init(agentID: String, transcriptFile: URL) {
    self.agentID = agentID
    toolUseID = nil
    self.transcriptFile = transcriptFile
  }

  /// The agent named, or else the one `toolUseID` started.
  init(agentID: String?, toolUseID: String, transcriptFile: URL) {
    self.agentID = agentID
    self.toolUseID = toolUseID
    self.transcriptFile = transcriptFile
  }

  /// Catches up; a read error leaves transcript as it was.
  func refresh() {
    if agentID == nil, let toolUseID {
      agentID = SubagentTranscript.agentID(forToolUseID: toolUseID, transcriptFile: transcriptFile)
    }
    if follower == nil {
      guard let agentID else { return }
      let file =
        hasLooked
        ? SubagentTranscript.ownFile(agentID: agentID, transcriptFile: transcriptFile)
        : SubagentTranscript.file(agentID: agentID, transcriptFile: transcriptFile)
      hasLooked = true
      guard let file else { return }
      follower = TranscriptFollower(file: file, includesSidechains: true)
    }
    guard var reader = follower else { return }
    // On copies, so that a read that fails part way leaves both as they were.
    var next = read
    do { try reader.catchUp(&next) } catch { return }
    let advanced = reader.offset != follower?.offset
    follower = reader
    read = next
    if advanced, !next.entries.isEmpty { transcript = next }
  }
}
