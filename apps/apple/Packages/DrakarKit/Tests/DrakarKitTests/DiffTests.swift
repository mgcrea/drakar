import DrakarKit
import Testing

@Suite("Diffing a change")
struct DiffTests {

  private func render(_ lines: [DiffLine]) -> [String] {
    lines.map { line in
      switch line.kind {
      case .context: " \(line.text)"
      case .added: "+\(line.text)"
      case .removed: "-\(line.text)"
      case .gap(let count): "… \(count)"
      }
    }
  }

  @Test func marksTheChangedLineBetweenItsNeighbours() {
    let old = "a\nb\nc\n"
    let new = "a\nB\nc\n"
    #expect(render(LineDiff.lines(old: old, new: new)) == [" a", "-b", "+B", " c"])
  }

  @Test func findsTheCommonSubsequenceInTheMiddle() {
    let old = "x\none\ntwo\nthree\ny"
    let new = "x\none\ninserted\nthree\ny"
    #expect(
      render(LineDiff.lines(old: old, new: new)) == [
        " x", " one", "-two", "+inserted", " three", " y",
      ])
  }

  @Test func treatsEmptySidesAsWhollyAddedOrRemoved() {
    #expect(render(LineDiff.lines(old: "", new: "a\nb")) == ["+a", "+b"])
    #expect(render(LineDiff.lines(old: "a", new: "")) == ["-a"])
    #expect(LineDiff.lines(old: "", new: "").isEmpty)
  }

  @Test func foldsUnchangedRunsIntoGaps() {
    let old = (1...20).map(String.init).joined(separator: "\n")
    let new = old.replacingOccurrences(of: "\n10\n", with: "\nten\n")
    #expect(
      render(LineDiff.hunks(old: old, new: new, context: 2)) == [
        "… 7", " 8", " 9", "-10", "+ten", " 11", " 12", "… 8",
      ])
    #expect(LineDiff.hunks(old: old, new: old).isEmpty)
  }

  /// The shapes the CLI sends: Edit's two strings, MultiEdit's list, Write's content.
  @Test func readsEachEditingTool() throws {
    let edit = try #require(
      FileChange(
        toolName: "Edit",
        input: .object([
          "file_path": .string("/p/a.swift"), "old_string": .string("let x = 1"),
          "new_string": .string("let x = 2\nlet y = 3"),
        ])))
    #expect(edit.path == "/p/a.swift")
    #expect(edit.removedCount == 1)
    #expect(edit.addedCount == 2)

    let multi = try #require(
      FileChange(
        toolName: "MultiEdit",
        input: .object([
          "file_path": .string("/p/a.swift"),
          "edits": .array([
            .object(["old_string": .string("a"), "new_string": .string("b")]),
            .object(["old_string": .string("c"), "new_string": .string("d")]),
          ]),
        ])))
    #expect(multi.diffs.count == 2)

    let input: JSONValue = .object(["file_path": .string("/p/new.txt"), "content": .string("hi\n")])
    let created = try #require(FileChange(toolName: "Write", input: input))
    #expect(created.isNewFile)
    #expect(render(created.diffs[0]) == ["+hi"])
    let rewritten = try #require(FileChange(toolName: "Write", input: input, existing: "hello\n"))
    #expect(!rewritten.isNewFile)
    #expect(render(rewritten.diffs[0]) == ["-hello", "+hi"])

    #expect(FileChange(toolName: "Bash", input: .object(["command": .string("ls")])) == nil)
  }
}
