import DrakarKit
import Foundation
import MCPKit

/// How a transcript goes out, a page at a time: each entry with its `index` in
/// `Transcript.entries`, so a cursor names a place in the transcript rather than in a page.
/// Thinking is left out: it is the model's working, not what it said or did.
enum TranscriptEncoding {

  /// The most of a tool's result an entry carries, in UTF-8 bytes. A `cat` of a large file
  /// must not reach the caller whole.
  static let resultLimit = 2048

  /// Entries from index `after` on, at most `last` of them, oldest first (nil: the newest
  /// `last`); the cursor to pass as `after` next time; and the indices below it that may
  /// still change.
  ///
  /// The cursor is one past the last entry given when the page was cut by `last`, and the
  /// transcript's end otherwise, so reading on from each cursor skips nothing and never stalls.
  /// An entry already read can still change where it stands: a tool call gets its result, and
  /// the newest main-thread text grows as it streams. `unsettled` names them, wherever they
  /// are in the transcript, for the caller to read again by index.
  static func page(_ transcript: Transcript, after: Int?, last: Int) -> (
    entries: [MCPKit.JSONValue], cursor: Int, unsettled: [Int]
  ) {
    let all = transcript.entries
    let shown = all.indices.filter { index in
      if case .thinking = all[index].kind { return false }
      return true
    }
    let kept: [Int]
    var cursor = all.count
    if let after {
      let since = shown.filter { $0 >= after }
      kept = Array(since.prefix(last))
      if since.count > last, let lastKept = kept.last { cursor = lastKept + 1 }
    } else {
      kept = Array(shown.suffix(last))
    }
    return (
      kept.compactMap { entry(all[$0], index: $0) }, cursor,
      unsettled(transcript).filter { $0 < cursor }
    )
  }

  /// The entries DrakarKit may still rewrite in place, in order: each tool call with no result
  /// yet while its turn runs, or while the subagent it runs under (or that it started) still
  /// runs, which a background fork does after its turn ended; and the newest main-thread text
  /// while a turn runs. A transcript read from its file, or whose process exited, has none:
  /// nothing will come to change them.
  static func unsettled(_ transcript: Transcript) -> [Int] {
    let all = transcript.entries
    let tasks = transcript.agentTasks
    func taskRuns(_ callID: String?) -> Bool {
      callID.flatMap { tasks[$0]?.status } == .running
    }
    var indices = all.indices.filter { index in
      guard case .tool(let call) = all[index].kind, call.result == nil else { return false }
      return transcript.isRunning || taskRuns(all[index].parentToolUseID) || taskRuns(call.id)
    }
    if transcript.isRunning,
      let newestText = all.indices.last(where: { index in
        guard all[index].parentToolUseID == nil, case .text = all[index].kind else { return false }
        return true
      })
    {
      indices.append(newestText)
    }
    return indices.sorted()
  }

  /// One entry; nil for thinking.
  static func entry(_ entry: Transcript.Entry, index: Int) -> MCPKit.JSONValue? {
    let fields: [String: MCPKit.JSONValue]
    switch entry.kind {
    case .prompt(let text): fields = ["role": "user", "text": .string(text)]
    case .text(let text): fields = ["role": "assistant", "text": .string(text)]
    case .notice(let text), .failure(let text): fields = ["role": "system", "text": .string(text)]
    case .tool(let call): fields = tool(call)
    case .thinking: return nil
    }
    return .object(fields.merging(["index": .int(index)]) { kept, _ in kept })
  }

  /// A tool call: its name, the one line its card shows, how it stands, and its result cut at
  /// `resultLimit`, `resultTruncated` set when it was.
  private static func tool(_ call: Transcript.ToolCall) -> [String: MCPKit.JSONValue] {
    var fields: [String: MCPKit.JSONValue] = [
      "role": "tool",
      "name": .string(call.name),
      "summary": .string(call.summary),
      "status": "running",
      "result": .null,
    ]
    if let result = call.result {
      fields["status"] = result.isError ? "error" : "done"
      let (content, truncated) = Encoding.truncating(
        .string(result.content), limit: resultLimit)
      fields["result"] = content
      if truncated { fields["resultTruncated"] = true }
    }
    return fields
  }
}
