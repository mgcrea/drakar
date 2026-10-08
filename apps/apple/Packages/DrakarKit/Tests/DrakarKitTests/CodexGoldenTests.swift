import DrakarKit
import Foundation
import Testing

/// Every Codex capture, folded by the transcript as it was recorded on 2026-10-07 when Codex
/// sessions arrived. A failure here is a regression in what a Codex session shows. Re-record
/// (`DRAKAR_RECORD_GOLDENS=1 swift test --filter CodexGoldenTests`) only for a change meant to
/// be seen, reading the JSON diff before committing it.
@Suite("The transcript folds every Codex capture as it did")
struct CodexGoldenTests {
  enum Scenario: String, CaseIterable, CustomTestStringConvertible {
    case codexTurn, codexFileChanges, codexSteer, codexHistory

    var testDescription: String { rawValue }
  }

  static func fold(_ scenario: Scenario) throws -> (running: Transcript, exited: Transcript) {
    let start = TranscriptGoldenTests.start
    var transcript = Transcript()
    if scenario == .codexHistory {
      for event in CodexTranslator.history(try Fixture.codexItemsPage["data"]?.arrayValue ?? []) {
        transcript.apply(event, at: start)
      }
      return (transcript, transcript)
    }
    let fixture: Fixture =
      switch scenario {
      case .codexTurn: .codexTurn
      case .codexFileChanges: .codexFileChanges
      case .codexSteer, .codexHistory: .codexSteer
      }
    transcript.addPrompt("Run it", at: start)
    if scenario == .codexSteer {
      transcript.queue(
        QueuedPrompt(uuid: "prompt-2", text: "Also add the word BETA to your reply."))
    }
    var translator = CodexTranslator()
    for (offset, line) in try fixture.lines.enumerated() {
      let time = start.addingTimeInterval(Double(offset + 1))
      for event in translator.translate(try JSONValue.parse(line), at: time) {
        transcript.apply(event, at: time)
      }
    }
    var exited = transcript
    exited.processExited()
    return (transcript, exited)
  }

  static func goldenURL(_ scenario: Scenario) -> URL {
    URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "Goldens/\(scenario.rawValue).json")
  }

  @Test(arguments: Scenario.allCases)
  func foldsAsRecorded(_ scenario: Scenario) throws {
    let (running, exited) = try Self.fold(scenario)
    let now = TranscriptGoldenTests.now
    let golden = TranscriptGoldenTests.Golden(
      running: TranscriptSnapshot(running, now: now),
      exited: TranscriptSnapshot(exited, now: now))
    let url = Self.goldenURL(scenario)
    if ProcessInfo.processInfo.environment["DRAKAR_RECORD_GOLDENS"] == "1" {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(golden).write(to: url)
      // A recording run compares nothing, so it must never pass.
      Issue.record("recorded \(scenario.rawValue), not compared")
      return
    }
    let recorded = try JSONDecoder().decode(
      TranscriptGoldenTests.Golden.self, from: Data(contentsOf: url))
    #expect(golden.running == recorded.running)
    #expect(golden.exited == recorded.exited)
  }
}
