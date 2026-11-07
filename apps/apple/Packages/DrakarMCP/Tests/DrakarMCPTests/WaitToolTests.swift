import DrakarKit
import Foundation
import MCPKit
import Testing

@testable import DrakarMCP

// Real time, polled every 10 ms: a wait that sees its move returns at once, and one that times
// out takes the 1 s the shortest timeout is held to.
@Suite("drakar_wait")
struct WaitToolTests {
  let source = FakeSessionSource()
  var table: ToolTable { Tools.table(source: source, pollInterval: .milliseconds(10)) }

  static let a = "aaaaaaaa-1111"
  static let b = "bbbbbbbb-2222"

  private func wait(_ arguments: MCPKit.JSONValue) async -> ToolResult {
    await table.call(name: "drakar_wait", arguments: arguments, allowWrites: false)
  }

  private static func row(_ id: String, _ state: SessionState) -> SessionRow {
    SessionRow(id: id, agent: .claude, folder: "/Users/me/app", state: state, place: .window)
  }

  private static func movedIDs(_ result: ToolResult) -> [MCPKit.JSONValue]? {
    result.structuredContent?["moved"]?.arrayValue?.map { $0["id"] ?? .null }
  }

  @Test("attention returns the session that newly wants the person")
  func waitAttention() async throws {
    let waiting = Self.row(Self.a, .waiting)
    source.sessions = [waiting, Self.row(Self.b, .working)]
    source.attentionThen = [[AttentionItem(session: waiting, kind: .askedInText, text: "Ship?")]]

    let result = await wait(["timeout_seconds": 5])
    #expect(!result.isError)
    #expect(Self.movedIDs(result) == [.string(Self.a)])
    #expect(result.structuredContent?["timedOut"] == false)
    #expect(result.structuredContent?["moved"]?[0]?["state"] == "waiting")
    #expect(result.text == "1 session moved.")
  }

  @Test("turn_end returns a session that stopped working; attention does not")
  func waitTurnEnd() async throws {
    source.sessions = [Self.row(Self.a, .working)]
    source.liveThen = [[Self.row(Self.a, .idle)]]
    var result = await wait(["until": "turn_end", "timeout_seconds": 5])
    #expect(Self.movedIDs(result) == [.string(Self.a)])
    #expect(result.structuredContent?["moved"]?[0]?["state"] == "idle")

    source.sessions = [Self.row(Self.a, .working)]
    source.liveThen = [[Self.row(Self.a, .idle)]]
    result = await wait(["until": "attention", "timeout_seconds": 1])
    #expect(result.structuredContent?["timedOut"] == true)
  }

  @Test("With nothing moving, the wait times out")
  func waitTimesOut() async throws {
    source.sessions = [Self.row(Self.a, .working)]
    let clock = ContinuousClock()
    let started = clock.now
    let result = await wait(["until": "change", "timeout_seconds": 0])
    #expect(clock.now - started >= .seconds(1))
    #expect(result.structuredContent == ["moved": [], "timedOut": true])
    #expect(result.text == "Nothing moved in 1 s.")
  }

  @Test("Only the named sessions are watched")
  func waitWatchesOnlyNamed() async throws {
    let before = [Self.row(Self.a, .idle), Self.row(Self.b, .working)]
    let after = [Self.row(Self.a, .idle), Self.row(Self.b, .idle)]
    source.sessions = before
    source.liveThen = [after]
    var result = await wait(["sessions": ["aaaaaaaa"], "until": "change", "timeout_seconds": 1])
    #expect(result.structuredContent?["timedOut"] == true)

    source.sessions = before
    source.liveThen = [after]
    result = await wait(["until": "change", "timeout_seconds": 1])
    #expect(Self.movedIDs(result) == [.string(Self.b)])
  }

  @Test("An unknown session to watch is refused")
  func unknownWatchedSession() async {
    let result = await wait(["sessions": ["cccccccc"]])
    #expect(result.isError)
    #expect(result.text == "No session cccccccc. drakar_list_sessions lists them.")
  }

  // MARK: - What moved

  @Test("change counts a state change, a session appearing and one going")
  func changeSeesAppearingAndGoing() {
    let moved = Waiting.moved(
      from: [Self.row(Self.a, .working), Self.row(Self.b, .idle)], attention: [],
      to: [Self.row(Self.a, .waiting), Self.row("cccccccc-3333", .working)], attention: [],
      until: .change, watched: nil)
    #expect(moved.map(\.id) == [Self.a, "cccccccc-3333", Self.b])
    #expect(moved.map(\.state) == [.waiting, .working, .ended])
  }

  @Test("turn_end: stopping to wait on the person is not an end; leaving that wait idle is")
  func turnEndSkipsWaiting() {
    let paused = Waiting.moved(
      from: [Self.row(Self.a, .working)], attention: [],
      to: [Self.row(Self.a, .waiting)], attention: [Self.a], until: .turnEnd, watched: nil)
    #expect(paused.isEmpty)

    let resumed = Waiting.moved(
      from: [Self.row(Self.a, .waiting)], attention: [Self.a],
      to: [Self.row(Self.a, .working)], attention: [], until: .turnEnd, watched: nil)
    #expect(resumed.isEmpty)

    let ended = Waiting.moved(
      from: [Self.row(Self.a, .waiting), Self.row(Self.b, .working)], attention: [Self.a],
      to: [Self.row(Self.a, .idle), Self.row(Self.b, .reconnecting)], attention: [],
      until: .turnEnd, watched: nil)
    #expect(ended.map(\.id) == [Self.a, Self.b])
    #expect(ended.map(\.state) == [.idle, .reconnecting])
  }

  @Test("turn_end counts a working session that went; attention only a newcomer to the set")
  func turnEndAndAttention() {
    let gone = Waiting.moved(
      from: [Self.row(Self.a, .working)], attention: [], to: [], attention: [],
      until: .turnEnd, watched: nil)
    #expect(gone.map(\.state) == [.ended])

    let still = Waiting.moved(
      from: [Self.row(Self.a, .waiting)], attention: [Self.a],
      to: [Self.row(Self.a, .waiting)], attention: [Self.a], until: .attention, watched: nil)
    #expect(still.isEmpty)
  }
}
