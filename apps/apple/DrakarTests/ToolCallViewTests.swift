import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Tool call card presentation")
struct ToolCallViewTests {
  private let folder = URL(filePath: "/Users/me/Projects/drakar")

  @Test func abbreviatesFilePathsAcrossProviders() {
    let path = "/Users/me/Projects/drakar/apps/apple/Drakar/Services/AgentSession.swift"

    let claude = Transcript.ToolCall(
      id: "c1", name: "Edit", input: .object(["file_path": .string(path)]),
      kind: .fileChange(path: path, edits: []))
    let agy = Transcript.ToolCall(
      id: "c2", name: "Edit", input: .object(["Path": .string(path)]),
      kind: .fileChange(path: path, edits: []))
    let codex = Transcript.ToolCall(
      id: "c3", name: "Edit", input: .array([.object(["path": .string(path)])]),
      kind: .fileChange(path: path, edits: []))
    let read = Transcript.ToolCall(
      id: "c4", name: "Read", input: .object(["Path": .string(path)]),
      kind: .read(path: path))

    for call in [claude, agy, codex, read] {
      #expect(
        ToolCallView.displayedSummary(for: call, in: folder)
          == "apps/apple/Drakar/Services/AgentSession.swift")
      #expect(ToolCallView.filePath(for: call) == path)
    }
  }

  @Test func abbreviatesPathsOutsideSessionFolderFromHome() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    let path = home + ".agents/skills/demo/SKILL.md"
    let call = Transcript.ToolCall(
      id: "c1", name: "Read", input: .object(["Path": .string(path)]), kind: .read(path: path))
    #expect(
      ToolCallView.displayedSummary(for: call, in: folder) == "~/.agents/skills/demo/SKILL.md")
  }

  @Test func abbreviatesPathsInOtherToolCalls() {
    let targetFile = "/Users/me/Projects/drakar/apps/apple/Drakar/Views/TranscriptView.swift"
    let otherTool = Transcript.ToolCall(
      id: "c1", name: "Tool",
      input: .object(["TargetFile": .string(targetFile), "variant": .string("view_file_outline")]),
      kind: .other)
    #expect(
      ToolCallView.displayedSummary(for: otherTool, in: folder)
        == "apps/apple/Drakar/Views/TranscriptView.swift")
    #expect(ToolCallView.filePath(for: otherTool) == targetFile)

    let search = Transcript.ToolCall(
      id: "c2", name: "Find",
      input: .object([:]),
      kind: .search(pattern: "Search /Users/me/Projects/drakar/apps/apple"))
    #expect(ToolCallView.displayedSummary(for: search, in: folder) == "Search apps/apple")

    let shell = Transcript.ToolCall(
      id: "c3", name: "Shell",
      input: .object(["command": .string("cat /Users/me/Projects/drakar/scripts/build.sh")]),
      kind: .shell(command: "cat /Users/me/Projects/drakar/scripts/build.sh"))
    #expect(ToolCallView.displayedSummary(for: shell, in: folder) == "cat scripts/build.sh")
    #expect(ToolCallView.filePath(for: shell) == nil)
  }

  @Test func aggregatesDiffCountsAcrossFileChanges() {
    let edits = [
      FileEdit(path: "/p/a.swift", change: .replace(old: "one", new: "one\ntwo\nthree")),
      FileEdit(path: "/p/b.swift", change: .replace(old: "old\nline", new: "new")),
    ]
    let changes = FileChange.each(edits: edits)
    let counts = ToolCallView.diffCounts(for: changes)
    #expect(counts?.added == 3)
    #expect(counts?.removed == 2)
    #expect(ToolCallView.diffCounts(for: []) == nil)
  }

  @Test func formatsReadRangesAcrossProviders() {
    let agyRange = Transcript.ToolCall(
      id: "r1", name: "Read",
      input: .object([
        "Path": .string("/p/a.swift"), "StartLine": .number(10), "EndLine": .number(45),
      ]),
      kind: .read(path: "/p/a.swift"))
    #expect(ToolCallView.readRange(for: agyRange) == "L10–45")

    let agySingle = Transcript.ToolCall(
      id: "r2", name: "Read",
      input: .object([
        "Path": .string("/p/a.swift"), "StartLine": .number(12), "EndLine": .number(12),
      ]),
      kind: .read(path: "/p/a.swift"))
    #expect(ToolCallView.readRange(for: agySingle) == "L12")

    let agyOpenEnd = Transcript.ToolCall(
      id: "r3", name: "Read",
      input: .object(["Path": .string("/p/a.swift"), "StartLine": .number(45)]),
      kind: .read(path: "/p/a.swift"))
    #expect(ToolCallView.readRange(for: agyOpenEnd) == "L45–")

    let claudeRange = Transcript.ToolCall(
      id: "r4", name: "Read",
      input: .object([
        "file_path": .string("/p/a.swift"), "offset": .number(10), "limit": .number(50),
      ]),
      kind: .read(path: "/p/a.swift"))
    #expect(ToolCallView.readRange(for: claudeRange) == "L10–59")

    let claudeLimitOnly = Transcript.ToolCall(
      id: "r5", name: "Read",
      input: .object(["file_path": .string("/p/a.swift"), "limit": .number(100)]),
      kind: .read(path: "/p/a.swift"))
    #expect(ToolCallView.readRange(for: claudeLimitOnly) == "L1–100")

    let wholeFile = Transcript.ToolCall(
      id: "r6", name: "Read",
      input: .object(["file_path": .string("/p/a.swift")]),
      kind: .read(path: "/p/a.swift"))
    #expect(ToolCallView.readRange(for: wholeFile) == nil)
  }

  private func call(
    _ kind: ToolKind, name: String = "Bash", result: String?, isError: Bool = false
  ) -> Transcript.ToolCall {
    Transcript.ToolCall(
      id: "c1", name: name, input: .object([:]), kind: kind,
      result: result.map { .init(content: $0, isError: isError) })
  }

  @Test func aShellCallPreviewsItsFirstLines() {
    let shell = ToolKind.shell(command: "make")
    #expect(
      ToolResultPreview.of(call(shell, result: "\u{1B}[32mok\u{1B}[0m\ntwo"), task: nil)
        == .output(.init(text: "ok\ntwo", isClipped: false), isError: false))
    #expect(
      ToolResultPreview.of(call(shell, result: "1\n2\n3\n4"), task: nil)
        == .output(.init(text: "1\n2\n3", isClipped: true), isError: false))
    // An error shows more of itself.
    let error = (1...10).map(String.init).joined(separator: "\n")
    #expect(
      ToolResultPreview.of(call(shell, result: error, isError: true), task: nil)
        == .output(.init(text: "1\n2\n3\n4\n5\n6\n7\n8", isClipped: true), isError: true))
    #expect(ToolResultPreview.of(call(shell, result: ""), task: nil) == .empty)
    #expect(ToolResultPreview.of(call(shell, result: nil), task: nil) == nil)
  }

  /// Its task's own section reads a backgrounded call's output.
  @Test func aBackgroundedCallHasNoPreview() {
    let result =
      "Command running in background with ID: b1. Output is being written to: /tmp/b1.output"
    #expect(
      ToolResultPreview.of(call(.shell(command: "sleep 9"), result: result), task: nil) == nil)
  }

  @Test func aSearchSaysHowMuchItFound() {
    #expect(
      ToolResultPreview.of(
        call(.search(pattern: "*.swift"), name: "Glob", result: "/a\n/b"), task: nil)
        == .summary("Found 2 files"))
    #expect(
      ToolResultPreview.of(
        call(.search(pattern: "x"), name: "Grep", result: "a:1\nb:2\nc:3"), task: nil)
        == .summary("3 lines of output"))
  }

  @Test func aRefusalShowsOnlyItsReason() {
    let refused =
      "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). "
    #expect(
      ToolResultPreview.of(
        call(
          .shell(command: "rm"),
          result: refused + "The user provided the following reason for the rejection: no",
          isError: true), task: nil)
        == .refused(reason: "no"))
    #expect(
      ToolResultPreview.of(
        call(.shell(command: "rm"), result: refused + "STOP what you are doing.", isError: true),
        task: nil) == nil)
  }

  /// Reads and edits keep their result inside the card, as in the extension.
  @Test func otherCallsHaveNoPreview() {
    #expect(
      ToolResultPreview.of(call(.read(path: "/a"), name: "Read", result: "x"), task: nil) == nil)
  }
}
