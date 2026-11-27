import DrakarKit
import Foundation
import Testing

@Suite("Agy ACP translator")
struct AgyTranslatorTests {
  private func json(_ text: String) throws -> JSONValue {
    try JSONValue.parse(Data(text.utf8))
  }

  @Test func translatesStreamingThinkingToolsDiffsAndText() throws {
    var translator = AgyTranslator()
    var transcript = Transcript()
    transcript.addPrompt("Edit note.txt and run ls")

    let updates: [String] = [
      #"{"sessionUpdate":"session_info_update","title":"Edit And List"}"#,
      #"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"First "}}"#,
      #"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"read it."}}"#,
      #"{"sessionUpdate":"usage_update","used":12000,"size":1048576}"#,
      #"{"sessionUpdate":"tool_call","toolCallId":"call_1","name":"edit_file","status":"in_progress","kind":"edit","locations":[{"path":"/p/note.txt"}],"rawInput":{"Path":"/p/note.txt","Target":"line2","Replacement":"LINE2"}}"#,
      #"{"sessionUpdate":"tool_call_update","toolCallId":"call_1","name":"edit_file","status":"completed","kind":"edit","rawInput":{"Path":"/p/note.txt","Target":"line2","Replacement":"LINE2"},"content":[{"type":"diff","path":"/p/note.txt","oldText":"line1\nline2\n","newText":"line1\nLINE2\n"}]}"#,
      #"{"sessionUpdate":"tool_call","toolCallId":"call_2","name":"run_command","status":"in_progress","kind":"execute","title":"ls -la","rawInput":{"CommandLine":"ls -la"}}"#,
      #"{"sessionUpdate":"tool_call_update","toolCallId":"call_2","name":"run_command","status":"completed","kind":"execute","title":"ls -la","rawInput":{"CommandLine":"ls -la"},"rawOutput":{"output":"note.txt\n","exit_code":0}}"#,
      #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done "}}"#,
      #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"now."}}"#,
    ]
    for raw in updates {
      for event in translator.translate(update: try json(raw)) {
        transcript.apply(event)
      }
    }
    for event in translator.finishOpenStream() { transcript.apply(event) }

    #expect(transcript.aiTitle == "Edit And List")
    #expect(transcript.contextWindow == 1_048_576)
    #expect(transcript.entries.count == 5)
    #expect(transcript.entries[1].kind == .thinking("First read it."))
    if case .tool(let editCall) = transcript.entries[2].kind {
      #expect(editCall.name == "Edit")
      #expect(
        editCall.kind
          == .fileChange(
            path: "/p/note.txt",
            edits: [
              FileEdit(
                path: "/p/note.txt", change: .replace(old: "line1\nline2\n", new: "line1\nLINE2\n"))
            ])
      )
      #expect(editCall.result?.isError == false)
    } else {
      Issue.record("Expected edit tool call")
    }
    if case .tool(let shellCall) = transcript.entries[3].kind {
      #expect(shellCall.name == "Shell")
      #expect(shellCall.kind == .shell(command: "ls -la"))
      #expect(shellCall.result == .init(content: "note.txt\n", isError: false))
    } else {
      Issue.record("Expected shell tool call")
    }
    #expect(transcript.entries[4].kind == .text("Done now."))
  }

  @Test func translatesPermissionRequestWithDiffAndSuggestions() throws {
    var translator = AgyTranslator()
    let params = try json(
      #"""
      {
        "sessionId": "s-1",
        "toolCall": {
          "toolCallId": "call_9",
          "name": "write_file",
          "kind": "edit",
          "rawInput": {"Path": "/p/a.txt", "Content": "hello"},
          "content": [{"type": "diff", "path": "/p/a.txt", "newText": "hello"}]
        },
        "options": [
          {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
          {"optionId": "always", "name": "Always Allow", "kind": "allow_always"},
          {"optionId": "deny", "name": "Deny", "kind": "reject_once"}
        ]
      }
      """#)
    let events = translator.permission(id: .string("7"), params: params)
    #expect(events.count == 1)
    guard case .permissionRequested(let pending) = events[0] else {
      Issue.record("Expected permissionRequested")
      return
    }
    #expect(pending.requestID == "7")
    #expect(pending.request.toolName == "Write")
    #expect(
      pending.request.kind
        == .fileChange(
          path: "/p/a.txt", edits: [FileEdit(path: "/p/a.txt", change: .write(content: "hello"))]))
    #expect(pending.request.parsedSuggestions.count == 1)
    #expect(
      pending.request.parsedSuggestions[0].kind == .agyOption(id: "always", name: "Always Allow"))
  }

  @Test func foldsSessionLoadHistoryIntoTurns() throws {
    let selection = EditorSelection(
      filePath: "/p/a.swift", text: "hi", start: .init(line: 0, character: 0),
      end: .init(line: 0, character: 2)
    ).promptContext
    let updates: [JSONValue] = [
      .object([
        "sessionUpdate": .string("user_message_chunk"),
        "content": .object(["type": .string("text"), "text": .string(selection)]),
      ]),
      .object([
        "sessionUpdate": .string("user_message_chunk"),
        "content": .object(["type": .string("text"), "text": .string("First question")]),
      ]),
      .object([
        "sessionUpdate": .string("user_message_chunk"),
        "content": .object([
          "type": .string("text"),
          "text": .string("<attachment name=\"notes.txt\">\nabc\n</attachment>"),
        ]),
      ]),
      try json(
        #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"First answer"}}"#
      ),
      try json(
        #"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Second question"}}"#
      ),
      try json(
        #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Second answer"}}"#
      ),
    ]
    let events = AgyTranslator.history(updates)
    #expect(events.turnsEnded == 2)
    var transcript = Transcript()
    for event in events { transcript.apply(event) }
    #expect(transcript.entries.count == 4)
    #expect(transcript.entries[0].kind == .prompt("First question"))
    #expect(transcript.entries[0].context == "a.swift:1")
    #expect(transcript.entries[0].attachments.map(\.name) == ["notes.txt"])
    #expect(transcript.entries[1].kind == .text("First answer"))
    #expect(transcript.entries[2].kind == .prompt("Second question"))
    #expect(transcript.entries[3].kind == .text("Second answer"))
  }

  @Test func translatesAskQuestionSuppressesFallbackAndPreservesEarlierAnswer() throws {
    var translator = AgyTranslator()
    var transcript = Transcript()
    transcript.addPrompt("Help me choose")

    let turn1: [String] = [
      #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"One thing:"}}"#,
      #"{"sessionUpdate":"tool_call","toolCallId":"call_q","name":"ask_question","args":{"questions":[{"question":"Color?","options":["Red","Blue"],"is_multi_select":false},{"question":"Toppings?","options":["Cheese","Olives"],"is_multi_select":true}]},"status":"in_progress","kind":"other","rawInput":{"questions":[{"question":"Color?","options":["Red","Blue"],"is_multi_select":false},{"question":"Toppings?","options":["Cheese","Olives"],"is_multi_select":true}]}}"#,
      #"{"sessionUpdate":"tool_call_update","toolCallId":"call_q","name":"ask_question","args":{"questions":[{"question":"Color?","options":["Red","Blue"],"is_multi_select":false},{"question":"Toppings?","options":["Cheese","Olives"],"is_multi_select":true}]},"status":"pending","kind":"other","rawInput":{"questions":[{"question":"Color?","options":["Red","Blue"],"is_multi_select":false},{"question":"Toppings?","options":["Cheese","Olives"],"is_multi_select":true}]}}"#,
      #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\nColor?\n- [1] Red\n- [2] Blue\n\nToppings?\n- [1] Cheese\n- [2] Olives\n"}}"#,
    ]
    for raw in turn1 {
      for event in translator.translate(update: try json(raw)) {
        transcript.apply(event)
      }
    }
    for event in translator.finishOpenStream() { transcript.apply(event) }
    transcript.apply(.turnEnded(.init(outcome: .completed)))

    #expect(transcript.entries.count == 3)
    #expect(transcript.entries[1].kind == .text("One thing:"))
    guard case .tool(let askCall) = transcript.entries[2].kind else {
      Issue.record("Expected ask_question tool call")
      return
    }
    #expect(askCall.kind == .question)
    #expect(askCall.name == "Question")
    #expect(transcript.unansweredQuestion?.id == "call_q")

    // Answering via earlierAnswerPrompt marks the call answered and survives `completed`.
    let reply = UserQuestion.earlierAnswerPrompt([
      ("Color?", "Blue"), ("Toppings?", "Cheese, Olives"),
    ])
    transcript.addPrompt(reply)
    let turn2: [String] = [
      #"{"sessionUpdate":"tool_call_update","toolCallId":"call_q","name":"ask_question","status":"in_progress","kind":"other"}"#,
      #"{"sessionUpdate":"tool_call_update","toolCallId":"call_q","name":"ask_question","status":"completed","kind":"other"}"#,
    ]
    for raw in turn2 {
      for event in translator.translate(update: try json(raw)) {
        transcript.apply(event)
      }
    }
    if case .tool(let updated) = transcript.entry(withID: "call_q")?.kind {
      #expect(
        updated.questionOutcome
          == .answered(["Color?": "Blue", "Toppings?": "Cheese, Olives"]))
    } else {
      Issue.record("Expected updated call_q")
    }
  }

  @Test func keepsTextAfterAskQuestionWhenItDiffersFromFallback() throws {
    var translator = AgyTranslator()
    var transcript = Transcript()
    transcript.addPrompt("Help")

    let updates: [String] = [
      #"{"sessionUpdate":"tool_call","toolCallId":"call_q","name":"ask_question","status":"pending","kind":"other","rawInput":{"questions":[{"question":"Color?","options":["Red","Blue"]}]}}"#,
      #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Please tell me your favorite."}}"#,
    ]
    for raw in updates {
      for event in translator.translate(update: try json(raw)) {
        transcript.apply(event)
      }
    }
    for event in translator.finishOpenStream() { transcript.apply(event) }

    #expect(transcript.entries.count == 3)
    #expect(transcript.entries[2].kind == .text("Please tell me your favorite."))
  }

  @Test func recognizesGrokAskUserQuestionMetaToolName() throws {
    var translator = AgyTranslator()
    var transcript = Transcript()
    transcript.addPrompt("Help")

    let update = try json(
      #"""
      {
        "sessionUpdate": "tool_call",
        "toolCallId": "call-1",
        "title": "ask_user_question",
        "rawInput": {"questions": [{"question": "Pick one", "options": [{"label": "A"}, {"label": "B"}]}]},
        "_meta": {"x.ai/tool": {"name": "ask_user_question"}}
      }
      """#)
    for event in translator.translate(update: update) { transcript.apply(event) }
    if case .tool(let call) = transcript.entry(withID: "call-1")?.kind {
      #expect(call.kind == .question)
      #expect(call.name == "Question")
    } else {
      Issue.record("Expected question tool call")
    }
  }
}
