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

  /// Entries from index `after` on (nil: the last `last` entries), and the cursor to pass next
  /// time: the index one past the last entry of the transcript. Reading on from a cursor gives
  /// at most `last` entries, the oldest first; when more came since, the cursor is one past the
  /// last entry given, so the next call reads on from there and nothing is skipped.
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
    if let after {
      let since = shown.filter { $0 >= after }
      kept = Array(since.prefix(last))
      if since.count > last, let lastKept = kept.last { cursor = lastKept + 1 }
    } else {
      kept = Array(shown.suffix(last))
    }
    return (kept.compactMap { entry(all[$0], index: $0) }, cursor)
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
