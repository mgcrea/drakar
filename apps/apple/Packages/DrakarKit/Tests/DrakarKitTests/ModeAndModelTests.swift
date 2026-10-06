import DrakarKit
import Testing

@Suite("The modes and models a session can take")
struct ModeAndModelTests {

  private func initializeReply() throws -> JSONValue? {
    let responses = try Fixture.modeAndModel.messages.compactMap { message -> ControlResponse? in
      if case .controlResponse(let response) = message { return response }
      return nil
    }
    return try #require(responses.first { $0.requestID == "r1" }).response
  }

  /// The account's own list, in the CLI's order: never one written into Drakar.
  @Test func readsTheModelsInitializeLists() throws {
    let models = try #require(ModelOption.list(fromInitialize: try initializeReply()))
    #expect(models.count == 12)
    #expect(models.prefix(5).map(\.value) == ["default", "opus", "fable", "sonnet", "haiku"])
    #expect(models[0].displayName == "Default (recommended)")
    #expect(models[0].resolvedModel == "claude-opus-5-5")
    #expect(models[0].supportsAutoMode)
    #expect(models.first { $0.value == "haiku" }?.supportsAutoMode == false)
    #expect(ModelOption.list(fromInitialize: .object([:])) == nil)
  }

  @Test func theProbeKeepsTheModels() throws {
    var replies = CapabilityReplies(initializeID: "r1", statusID: "none")
    for message in try Fixture.modeAndModel.messages {
      if case .controlResponse(let response) = message { replies.take(response) }
    }
    #expect(replies.capabilities.models?.count == 12)
  }

  @Test func cyclesThroughWhatIsOffered() {
    let offered: [PermissionMode] = [.ask, .acceptEdits, .plan]
    #expect(PermissionMode.next(after: .ask, among: offered) == .acceptEdits)
    #expect(PermissionMode.next(after: .plan, among: offered) == .ask)
    // A mode no longer offered (Bypass, after Settings turned it off) goes to the first.
    #expect(PermissionMode.next(after: .bypass, among: offered) == .ask)
    #expect(PermissionMode.allCases == [.ask, .acceptEdits, .plan, .auto, .bypass])
  }

  @Test func namesModes() {
    #expect(PermissionMode.title(of: "default") == "Ask before edits")
    #expect(PermissionMode.title(of: "bypassPermissions") == "Bypass permissions")
    #expect(PermissionMode.title(of: "dontAsk") == "dontAsk")
  }
}
