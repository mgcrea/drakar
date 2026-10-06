import DrakarKit
import Foundation
import Testing

/// Every capture, folded by the transcript as it is on 2026-10-06, before the agent went
/// behind a protocol: what each refactoring commit must reproduce exactly. Record once with
/// `DRAKAR_RECORD_GOLDENS=1 swift test --filter TranscriptGoldenTests`; never again in this
/// branch (the plan's Global Constraints).
@Suite("The transcript folds every capture as it did")
struct TranscriptGoldenTests {
  static let start = Date(timeIntervalSince1970: 1_800_000_000)
  static let now = start.addingTimeInterval(600)

  enum Scenario: String, CaseIterable, CustomTestStringConvertible {
    case turnWithTool, permissionRequest, interruptThenTurn, contextUsage, modeAndModel
    case subagentAndTodos, planRequest, queuedPrompts
    case historyWithTool, historyWithAttachments

    var testDescription: String { rawValue }

    var fixture: Fixture {
      switch self {
      case .turnWithTool: .turnWithTool
      case .permissionRequest: .permissionRequest
      case .interruptThenTurn: .interruptThenTurn
      case .contextUsage: .contextUsage
      case .modeAndModel: .modeAndModel
      case .subagentAndTodos: .subagentAndTodos
      case .planRequest: .planRequest
      case .queuedPrompts: .queuedPrompts
      case .historyWithTool: .historyWithTool
      case .historyWithAttachments: .historyWithAttachments
      }
    }

    var isHistory: Bool { self == .historyWithTool || self == .historyWithAttachments }
  }

  struct Golden: Codable, Equatable {
    var running: TranscriptSnapshot
    var exited: TranscriptSnapshot
  }

  /// The one line later tasks change: what folds the capture.
  static func fold(_ scenario: Scenario) throws -> (running: Transcript, exited: Transcript) {
    if scenario.isHistory {
      let history = Transcript.history(lines: try scenario.fixture.lines)
      return (history, history)
    }
    var transcript = ClaudeFeed()
    if scenario == .queuedPrompts {
      transcript.addPrompt("Count to five.", at: start)
      transcript.queue(
        QueuedPrompt(
          uuid: "bbbbbbbb-2222-4222-8222-222222222222", text: "Now say the word banana."))
      transcript.queue(
        QueuedPrompt(
          uuid: "cccccccc-3333-4333-8333-333333333333", text: "Now say the word cherry."))
    } else {
      transcript.addPrompt("Run it", at: start)
    }
    for (offset, message) in try scenario.fixture.messages.enumerated() {
      transcript.apply(message, at: start.addingTimeInterval(Double(offset + 1)))
    }
    var exited = transcript
    exited.processExited()
    return (transcript.transcript, exited.transcript)
  }

  static func goldenURL(_ scenario: Scenario) -> URL {
    URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "Goldens/\(scenario.rawValue).json")
  }

  @Test(arguments: Scenario.allCases)
  func foldsAsRecorded(_ scenario: Scenario) throws {
    let (running, exited) = try Self.fold(scenario)
    let golden = Golden(
      running: TranscriptSnapshot(running, now: Self.now),
      exited: TranscriptSnapshot(exited, now: Self.now))
    let url = Self.goldenURL(scenario)
    if ProcessInfo.processInfo.environment["DRAKAR_RECORD_GOLDENS"] == "1" {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encoder.encode(golden).write(to: url)
      // A recording run compares nothing, so it must never pass.
      Issue.record("recorded \(scenario.rawValue), not compared")
      return
    }
    let recorded = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    #expect(golden.running == recorded.running)
    #expect(golden.exited == recorded.exited)
  }
}
