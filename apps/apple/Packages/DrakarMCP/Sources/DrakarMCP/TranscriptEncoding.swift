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
  /// `last`), and the cursor to pass as `after` next time.
  ///
  /// The cursor is one past the last entry given, except that it never passes a given entry
  /// that may still change in place: a tool call with no result yet, or, while a turn runs,
  /// the transcript's last entry when it is text or a notice still streaming. Those come again
  /// on the next read, under the same `index`, the later copy the one to keep. So reading on
  /// from each cursor skips nothing and leaves nothing half-written. A page cut by `last` that
  /// would hold the cursor where it started moves it on instead, so a call that never finished
  /// (its process gone) cannot keep a reader on the same page forever.
  static func page(_ transcript: Transcript, after: Int?, last: Int) -> (
    entries: [MCPKit.JSONValue], cursor: Int
  ) {
    let all = transcript.entries
    let shown = all.indices.filter { index in
      if case .thinking = all[index].kind { return false }
      return true
    }
    let kept: [Int]
    var cursor = all.count
    var cut = false
    if let after {
      let since = shown.filter { $0 >= after }
      kept = Array(since.prefix(last))
      cut = since.count > last
      if cut, let lastKept = kept.last { cursor = lastKept + 1 }
    } else {
      kept = Array(shown.suffix(last))
    }
    if let unsettled = kept.first(where: { mayChange(all[$0], at: $0, in: transcript) }),
      !cut || unsettled > (after ?? 0)
    {
      cursor = min(cursor, unsettled)
    }
    return (kept.compactMap { entry(all[$0], index: $0) }, cursor)
  }

  /// Whether DrakarKit may still rewrite `entry` where it stands: a tool call's result is
  /// attached to it, and the newest text or notice of a running turn grows or is revised.
  static func mayChange(_ entry: Transcript.Entry, at index: Int, in transcript: Transcript)
    -> Bool
  {
    switch entry.kind {
    case .tool(let call): call.result == nil
    case .text, .notice: transcript.isRunning && index == transcript.entries.count - 1
    case .prompt, .thinking, .failure: false
    }
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
