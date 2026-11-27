import Foundation
import Testing

@testable import DrakarKit

@Suite("Serializing a transcript for provider handover")
struct TranscriptHandoverTests {
  @Test func emptyOrNoticeOnlyTranscriptProducesNil() {
    var transcript = Transcript()
    #expect(
      TranscriptHandover.prompt(from: transcript, from: "Claude Code", to: "Codex") == nil)

    transcript.noteColdCache(at: .distantPast)
    transcript.addNotice("Some note")
    #expect(
      TranscriptHandover.prompt(from: transcript, from: "Claude Code", to: "Codex") == nil)
  }

  @Test func formatsPromptsAssistantToolCallsAndOmitsThinkingAndSubagents() {
    var transcript = Transcript()
    transcript.addPrompt(
      "Fix the login bug", context: "Auth.swift:10-20",
      attachments: [AttachmentPreview(kind: .text, name: "trace.log", thumbnail: nil)],
      running: false)
    transcript.apply(
      .itemCompleted(.init(id: "t1", parent: nil, kind: .thinking("Internal chain of thought"))))
    transcript.apply(
      .itemCompleted(.init(id: "m1", parent: nil, kind: .text("Checking Auth.swift first."))))
    transcript.apply(
      .itemCompleted(
        .init(
          id: "tool-1", parent: nil,
          kind: .tool(
            .init(
              id: "tool-1", name: "Read", input: .object(["file_path": .string("Auth.swift")]),
              kind: .read(path: "Auth.swift"))))))
    transcript.apply(
      .toolResult(
        callID: "tool-1", .init(content: String(repeating: "x", count: 500), isError: false))
    )
    // Subagent child entry should stay out of the main handover.
    transcript.apply(
      .itemCompleted(
        .init(id: "sub-1", parent: "tool-1", kind: .text("Subagent internal text"))))
    transcript.noteColdCache(at: .distantPast)

    let prompt = TranscriptHandover.prompt(
      from: transcript, title: "Login fix", from: "Claude Code", to: "Codex")
    let text = try! #require(prompt)
    #expect(text.contains("Claude Code to Codex"))
    #expect(text.contains("Title: Login fix"))
    #expect(text.contains("### User"))
    #expect(text.contains("Context: Auth.swift:10-20"))
    #expect(text.contains("Attachments: trace.log"))
    #expect(text.contains("Fix the login bug"))
    #expect(text.contains("### Assistant\nChecking Auth.swift first."))
    #expect(text.contains("- [Tool] Read: Auth.swift -> ok (500 chars)"))
    #expect(!text.contains("Internal chain of thought"))
    #expect(!text.contains("Subagent internal text"))
    #expect(!text.contains("Prompt cache"))
  }

  @Test func truncatesLongTranscriptKeepingFirstAndMostRecentEntries() {
    var transcript = Transcript()
    transcript.addPrompt("Initial task: build the parser", running: false)
    for idx in 1...10 {
      transcript.apply(
        .itemCompleted(
          .init(
            id: "msg-\(idx)", parent: nil,
            kind: .text("Turn \(idx) " + String(repeating: "a", count: 120)))))
    }
    transcript.addPrompt("Final follow-up question", running: false)

    let prompt = TranscriptHandover.prompt(
      from: transcript, from: "Codex", to: "Claude Code", maxCharacters: 450)
    let text = try! #require(prompt)
    #expect(text.contains("Initial task: build the parser"))
    #expect(text.contains("Final follow-up question"))
    #expect(text.contains("earlier entries omitted"))
  }
}
