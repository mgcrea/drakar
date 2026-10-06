import DrakarKit
import Foundation
import Testing

@Suite("Todos")
struct TodoListTests {

  private func transcript() throws -> Transcript {
    var transcript = Transcript()
    transcript.addPrompt("Run it")
    for message in try Fixture.subagentAndTodos.messages { transcript.apply(message) }
    return transcript
  }

  @Test func readsAToDoWrite() throws {
    let todos = try #require(try transcript().todos)
    #expect(
      todos == [
        Todo(content: "check a.txt", activeForm: "Checking a.txt", status: .completed),
        Todo(content: "check b.txt", activeForm: "Checking b.txt", status: .inProgress),
      ])
    #expect(TodoList.current(todos)?.activeForm == "Checking b.txt")
    #expect(TodoList.progress(todos) == "1/2")
  }

  /// The newest list is the one that holds; a subagent's own is not the session's.
  @Test func theNewestMainThreadListHolds() throws {
    var transcript = Transcript()
    transcript.addPrompt("Run it")
    func write(_ id: String, _ status: String, parent: String? = nil) throws {
      let parentJSON = parent.map { "\"\($0)\"" } ?? "null"
      let line =
        #"{"type":"assistant","message":{"id":"m-\#(id)","role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"TodoWrite","input":{"todos":[{"content":"one","activeForm":"Doing one","status":"\#(status)"}]}}]},"parent_tool_use_id":\#(parentJSON),"session_id":"s"}"#
      transcript.apply(try StreamMessage(line: Data(line.utf8)))
    }
    try write("t1", "pending")
    try write("t2", "completed")
    try write("t3", "pending", parent: "agent")
    #expect(transcript.todos?.map(\.status) == [.completed])
    #expect(TodoList.current(transcript.todos ?? []) == nil)
  }

  @Test func anUnreadableItemIsLeftOut() {
    let input: JSONValue = .object([
      "todos": .array([
        .object(["content": .string("kept"), "status": .string("pending")]),
        .object(["status": .string("pending")]),
      ])
    ])
    #expect(TodoList.todos(input) == [Todo(content: "kept", activeForm: nil, status: .pending)])
  }
}
