import DrakarKit
import Foundation
import Testing

@Suite("Presenting messages")
struct PresentationTests {

  private func call(_ name: String, _ input: [String: JSONValue]) -> Transcript.ToolCall {
    Transcript.ToolCall(
      id: "t", name: name, input: .object(input),
      kind: ClaudeTools.kind(name: name, input: .object(input)))
  }

  @Test func summarisesEachToolByWhatItActsOn() {
    #expect(
      call("Bash", ["command": .string("ls -la"), "description": .string("List")]).summary
        == "ls -la")
    #expect(
      call("Edit", ["file_path": .string("/a/b.swift"), "old_string": .string("x")]).summary
        == "/a/b.swift")
    #expect(call("Grep", ["pattern": .string("TODO"), "path": .string("src")]).summary == "TODO")
    #expect(
      call("Task", ["description": .string("Find usages"), "prompt": .string("…")]).summary
        == "Find usages")
  }

  /// A plan by its title, a todo list by how far along it is: never their whole text.
  @Test func summarisesAPlanAndATodoList() {
    #expect(
      call("ExitPlanMode", ["plan": .string("\n# Add hello.txt\n\n## Context\nMore")]).summary
        == "Add hello.txt")
    let todos: JSONValue = .array([
      .object(["content": .string("a"), "status": .string("completed")]),
      .object(["content": .string("b"), "activeForm": .string("Doing b"), "status": .string("in_progress")]),
    ])
    #expect(call("TodoWrite", ["todos": todos]).summary == "1/2 done · Doing b")
    #expect(call("TodoWrite", ["todos": .array([])]).summary == "0/0 done")
  }

  /// An MCP tool nobody taught this file about still gets a stable summary.
  @Test func summarisesAnUnknownToolByItsFirstStringArgument() {
    let summary = call(
      "mcp__github__get_issue", ["repo": .string("mgcrea/drakar"), "number": .number(3)]
    ).summary
    #expect(summary == "mgcrea/drakar")
    #expect(call("Mystery", ["n": .number(1)]).summary == "")
  }

  @Test func prettyPrintsWithSortedKeys() {
    let json: JSONValue = .object(["b": .number(2), "a": .string("x/y")])
    #expect(json.prettyPrinted == "{\n  \"a\" : \"x/y\",\n  \"b\" : 2\n}")
  }

  /// The three suggestions the real CLI offered for `touch amiral-probe.txt`.
  @Test func readsTheCapturedSuggestions() throws {
    let request = try #require(
      try Fixture.permissionRequest.messages.lazy.compactMap { message -> PermissionRequest? in
        if case .controlRequest(let request) = message,
          case .canUseTool(let permission) = request.kind
        {
          return permission
        }
        return nil
      }.first)
    #expect(request.summary == "touch amiral-probe.txt")
    let suggestions = request.parsedSuggestions
    #expect(
      suggestions.map(\.kind) == [
        .addRules(["Bash(touch amiral-probe.txt)"]),
        .addDirectories(["/Users/me/project"]),
        .setMode("acceptEdits"),
      ])
    #expect(suggestions.map(\.isPersistent) == [true, false, false])
    // Sent back exactly as received.
    #expect(suggestions.map(\.raw) == request.suggestions)
  }

  @Test func aDeadProcessLeavesNothingRunningOrPending() throws {
    var transcript = ClaudeFeed()
    transcript.addPrompt("Touch it")
    for message in try Fixture.permissionRequest.messages {
      transcript.apply(message)
      if case .controlRequest = message { break }
    }
    #expect(transcript.isRunning)
    #expect(!transcript.pendingPermissions.isEmpty)
    transcript.processExited()
    #expect(!transcript.isRunning)
    #expect(transcript.pendingPermissions.isEmpty)
  }
}
