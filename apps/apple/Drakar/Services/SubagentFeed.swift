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
///
/// The first read of the file, which may be long, runs off the main actor; the reads that
/// follow it take only what was appended since.
@Observable final class SubagentFeed {
  /// What the card draws of the file, grouped as a transcript is.
  struct Drawn: Equatable {
    var top: [Transcript.Entry]
    var children: [String: [Transcript.Entry]]
  }

  /// nil: no file, or nothing in it but its prompt, so the card keeps its streamed children.
  private(set) var transcript: Transcript?
  /// `transcript` without the prompt the file opens with, which the card shows itself, cut
  /// short: drawn as a prompt of the session's, it ran to full length.
  private(set) var drawn: Drawn?

  /// nil until the call's agent is found.
  @ObservationIgnored private(set) var agentID: String?
  @ObservationIgnored let toolUseID: String?
  @ObservationIgnored let transcriptFile: URL
  @ObservationIgnored private var follower: TranscriptFollower?
  /// Everything folded in so far, shown once it holds an entry besides its prompt.
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
  func refresh() async {
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
    guard let start = follower else { return }
    // On copies, so that a read that fails part way leaves both as they were.
    let caught: (TranscriptFollower, Transcript)?
    if start.offset == 0 {
      caught = await Task.detached { [read] in Self.catchUp(start, read) }.value
    } else {
      caught = Self.catchUp(start, read)
    }
    guard let (reader, next) = caught else { return }
    // A refresh that ran meanwhile read at least as far.
    guard reader.offset >= follower?.offset ?? 0 else { return }
    let advanced = reader.offset != follower?.offset
    follower = reader
    read = next
    guard advanced else { return }
    let groups = next.grouped()
    var top = groups.top
    if case .prompt? = top.first?.kind { top.removeFirst() }
    guard !top.isEmpty else { return }
    transcript = next
    drawn = Drawn(top: top, children: groups.children)
  }

  private nonisolated static func catchUp(_ follower: TranscriptFollower, _ read: Transcript)
    -> (TranscriptFollower, Transcript)?
  {
    var reader = follower
    var next = read
    do { try reader.catchUp(&next) } catch { return nil }
    return (reader, next)
  }
}
