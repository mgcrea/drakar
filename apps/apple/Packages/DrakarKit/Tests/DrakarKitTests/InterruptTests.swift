import DrakarKit
import Foundation
import Testing

@Suite("Interrupting a turn")
struct InterruptTests {

  private var results: [TurnResult] {
    get throws {
      try Fixture.interruptThenTurn.messages.compactMap { message in
        if case .result(let result) = message { return result }
        return nil
      }
    }
  }

  @Test func theCLIAcknowledgesTheInterrupt() throws {
    let responses = try Fixture.interruptThenTurn.messages.compactMap {
      message -> ControlResponse? in
      if case .controlResponse(let response) = message { return response }
      return nil
    }
    #expect(responses.map(\.requestID) == ["req_init", "req_int"])
    #expect(responses.allSatisfy { $0.isSuccess })
  }

  /// An error by every field but its reason, which is the one the UI must read.
  @Test func anInterruptedTurnIsAnErrorByItsFieldsOnly() throws {
    let results = try results
    #expect(results.count == 2)
    guard results.count == 2 else { return }
    #expect(results[0].isError)
    #expect(results[0].subtype == "error_during_execution")
    #expect(results[0].wasInterrupted)
    #expect(!results[1].isError)
    #expect(!results[1].wasInterrupted)
    #expect(results[1].text == "ready")
  }

  @Test func theTranscriptShowsTheInterruptAndCarriesOn() throws {
    var transcript = Transcript()
    transcript.addPrompt("Write a story")
    var sawInterruptedResult = false
    for message in try Fixture.interruptThenTurn.messages {
      transcript.apply(message)
      if case .result(let result) = message, result.wasInterrupted {
        sawInterruptedResult = true
        #expect(!transcript.isRunning)
        transcript.addPrompt("Reply with ready")
      }
    }
    #expect(sawInterruptedResult)
    let kinds = transcript.entries.map(\.kind)
    #expect(kinds.contains(.notice("Request interrupted by user")))
    #expect(kinds.contains(.text("# The Last Command")))
    #expect(kinds.last == .text("ready"))
    #expect(!transcript.isRunning)
  }
}
