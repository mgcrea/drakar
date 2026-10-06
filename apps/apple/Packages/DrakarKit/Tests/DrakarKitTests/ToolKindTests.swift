import DrakarKit
import Testing

@Suite("What a tool call is for")
struct ToolKindTests {
  private func kind(_ name: String, _ input: [String: String] = [:]) -> ToolKind {
    ClaudeTools.kind(name: name, input: .object(input.mapValues(JSONValue.string)))
  }

  @Test func readsEveryClaudeToolItKnows() {
    #expect(kind("Bash", ["command": "ls"]) == .shell(command: "ls"))
    #expect(kind("Read", ["file_path": "/a"]) == .read(path: "/a"))
    #expect(kind("Grep", ["pattern": "x"]) == .search(pattern: "x"))
    #expect(kind("Glob", ["pattern": "*.swift"]) == .search(pattern: "*.swift"))
    #expect(kind("WebFetch", ["url": "https://e.com"]) == .web("https://e.com"))
    #expect(kind("WebSearch", ["query": "swift"]) == .web("swift"))
    #expect(kind("Agent", ["description": "Look"]) == .subagent(description: "Look"))
    #expect(kind("Task") == .subagent(description: nil))
    #expect(kind("AskUserQuestion") == .question)
    #expect(kind("ExitPlanMode") == .planApproval)
    #expect(kind("TodoWrite") == .todos)
    #expect(kind("mcp__github__get_me") == .mcp(server: "github", tool: "get_me"))
    #expect(kind("NotebookEdit", ["notebook_path": "/n"]) == .other)
  }

  @Test func readsTheEditingTools() {
    let edit = FileEdit(path: "/a", change: .replace(old: "x", new: "y"))
    #expect(
      kind("Edit", ["file_path": "/a", "old_string": "x", "new_string": "y"])
        == .fileChange(path: "/a", edits: [edit]))
    #expect(
      kind("Write", ["file_path": "/a", "content": "hi"])
        == .fileChange(path: "/a", edits: [FileEdit(path: "/a", change: .write(content: "hi"))]))
    let multi = ClaudeTools.kind(
      name: "MultiEdit",
      input: .object([
        "file_path": .string("/a"),
        "edits": .array([
          .object(["old_string": .string("a"), "new_string": .string("b")]), .object([:]),
        ]),
      ]))
    #expect(
      multi
        == .fileChange(
          path: "/a", edits: [FileEdit(path: "/a", change: .replace(old: "a", new: "b"))]))
    #expect(kind("Edit", ["file_path": "/a"]) == .fileChange(path: "/a", edits: []))
  }

  /// A known tool missing the argument it is known by reads as any other tool, which is what
  /// the summary did before kinds: its first string argument.
  @Test func aKnownToolMissingItsArgumentIsOther() {
    #expect(kind("Bash", ["description": "d"]) == .other)
    #expect(kind("Read") == .other)
    #expect(kind("Edit", ["old_string": "x"]) == .other)
  }

  @Test func summarisesByKindThenByFirstStringArgument() {
    #expect(ToolKind.shell(command: "ls").summary(input: .object([:])) == "ls")
    #expect(
      ToolKind.subagent(description: nil).summary(input: .object(["prompt": .string("p")])) == "p")
    #expect(
      ToolKind.other.summary(input: .object(["b": .string("2"), "a": .string("1")])) == "1")
    #expect(ToolKind.question.summary(input: .null) == "")
  }

  @Test func readsCodexPatches() {
    let added = PatchText.lines("hi\nthere\n")
    #expect(added.isNewFile)
    #expect(added.lines == [DiffLine(.added, "hi"), DiffLine(.added, "there")])
    let update = PatchText.lines("@@ -1,2 +1,2 @@\n a\n-b\n+c\n")
    #expect(!update.isNewFile)
    #expect(
      update.lines == [DiffLine(.context, "a"), DiffLine(.removed, "b"), DiffLine(.added, "c")])
    let change = FileChange(path: "/a", edits: [FileEdit(path: "/a", change: .patch("hi\n"))])
    #expect(change?.isNewFile == true)
    #expect(change?.addedCount == 1)
    #expect(FileChange(path: "/a", edits: []) == nil)
  }

  @Test func separatesCodexHunksByTheirGap() {
    let update = PatchText.lines("@@ -1,2 +1,2 @@\n a\n-b\n+c\n@@ -10,2 +10,3 @@\n x\n+y\n z\n")
    #expect(
      update.lines == [
        DiffLine(.context, "a"), DiffLine(.removed, "b"), DiffLine(.added, "c"),
        DiffLine(.gap(7), ""),
        DiffLine(.context, "x"), DiffLine(.added, "y"), DiffLine(.context, "z"),
      ])
    let adjacent = PatchText.lines("@@ -1 +1 @@\n-a\n+b\n@@ -2 +2 @@\n-c\n+d\n")
    #expect(!adjacent.lines.contains { if case .gap = $0.kind { true } else { false } })
    // An insertion's hunk names the line before it: line 2 is left out.
    let insertion = PatchText.lines("@@ -1 +1 @@\n-a\n+b\n@@ -2,0 +3 @@\n+c\n")
    #expect(insertion.lines[2] == DiffLine(.gap(1), ""))
  }
}
