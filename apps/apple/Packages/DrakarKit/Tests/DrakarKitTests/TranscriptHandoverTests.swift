import Foundation
import Testing

@testable import DrakarKit

@Suite("Serializing a transcript for provider handover")
struct TranscriptHandoverTests {
  @Test func emptyOrNoticeOnlyTranscriptProducesNil() {
    var transcript = Transcript()
    #expect(TranscriptHandover(from: transcript, from: "Claude Code", to: "Codex") == nil)

    transcript.noteColdCache(at: .distantPast)
    transcript.addNotice("Some note")
    #expect(TranscriptHandover(from: transcript, from: "Claude Code", to: "Codex") == nil)
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

    let handover = try! #require(
      TranscriptHandover(from: transcript, title: "Login fix", from: "Claude Code", to: "Codex"))
    #expect(handover.prompt.contains("moved here from Claude Code"))
    #expect(handover.prompt.contains("handover.md"))
    #expect(!handover.prompt.contains("Fix the login bug"))
    let text = handover.document
    #expect(text.hasPrefix("# Login fix\n"))
    #expect(text.contains("held with Claude Code, moved to Codex"))
    #expect(text.contains("## User"))
    #expect(text.contains("Context: Auth.swift:10-20"))
    #expect(text.contains("Attachments: trace.log"))
    #expect(text.contains("Fix the login bug"))
    #expect(text.contains("## Assistant\n\nChecking Auth.swift first."))
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

    let handover = try! #require(
      TranscriptHandover(from: transcript, from: "Codex", to: "Claude Code", maxCharacters: 450))
    let text = handover.document
    #expect(text.hasPrefix("# Session handover\n"))
    #expect(text.contains("Initial task: build the parser"))
    #expect(text.contains("Final follow-up question"))
    #expect(text.contains("earlier entries omitted"))
  }

  @Test func documentGoesAsATextAttachment() throws {
    let attachment = try Attachment.text("# Notes\n\nHello", name: TranscriptHandover.documentName)
    #expect(attachment.kind == .text)
    #expect(attachment.preview.name == "handover.md")
    #expect(attachment.block["source"]?["data"]?.stringValue == "# Notes\n\nHello")
    #expect(throws: AttachmentError.self) { try Attachment.text("", name: "empty.md") }
  }

  @Test func aSessionMovedTwiceHandsOverEveryPart() throws {
    var first = Transcript()
    first.addPrompt("Plan the migration", running: false)
    first.apply(.itemCompleted(.init(id: "a1", parent: nil, kind: .text("Three steps."))))
    var second = Transcript()
    second.addPrompt(
      "This conversation moved here from Claude Code.",
      attachments: [AttachmentPreview(kind: .text, name: "handover.md", thumbnail: nil)],
      running: false)
    second.apply(.itemCompleted(.init(id: "b1", parent: nil, kind: .text("Got it."))))
    second.addPrompt("Do step two", running: false)

    let handover = try #require(
      TranscriptHandover(
        from: second, earlier: [(provider: "Claude Code", transcript: first)],
        from: "Codex", to: "Grok"))
    let text = handover.document
    #expect(text.contains("held with Claude Code, then Codex, moved to Grok"))
    #expect(text.contains("Plan the migration"))
    #expect(text.contains("_Moved from Claude Code to Codex._"))
    #expect(text.contains("Do step two"))
    // The first move's own prompt is not handed over again.
    #expect(!text.contains("This conversation moved here from Claude Code."))
    #expect(handover.prompt.contains("moved here from Codex"))
  }
}
