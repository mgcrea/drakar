import DrakarKit
import Foundation
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

  /// Haiku takes no effort: its entry lists none.
  @Test func readsEachModelsEffortLevels() throws {
    let models = try #require(ModelOption.list(fromInitialize: try initializeReply()))
    #expect(models[0].effortLevels == ["low", "medium", "high", "xhigh", "max"])
    #expect(models.first { $0.value == "haiku" }?.effortLevels == [])
  }

  /// The aliases and the models they stand for stay; pinned older ids go, but for one kept.
  @Test func leavesOutLegacyModels() throws {
    let models = try #require(ModelOption.list(fromInitialize: try initializeReply()))
    let current = ["default", "opus", "fable", "sonnet", "haiku"]
    #expect(ModelOption.withoutLegacy(models).map(\.value) == current)
    #expect(
      ModelOption.withoutLegacy(models, keeping: "claude-opus-4-8").map(\.value)
        == current + ["claude-opus-4-8"])
    // A pinned id an alias stands for today is not legacy.
    let pinned = ModelOption(
      value: "claude-opus-5-5", resolvedModel: "claude-opus-5-5", displayName: "Opus 5.5")
    #expect(ModelOption.withoutLegacy(models + [pinned]).map(\.value) == current + [pinned.value])
  }

  /// A list of pinned ids only, as a cloud provider's may be, has nothing to tell apart.
  @Test func keepsAListWithoutAliases() {
    let models = [
      ModelOption(value: "default", displayName: "Default"),
      ModelOption(value: "claude-opus-4-8", displayName: "Opus 4.8"),
      ModelOption(value: "claude-sonnet-4-6", displayName: "Sonnet 4.6"),
    ]
    #expect(ModelOption.withoutLegacy(models) == models)
  }

  @Test func readsTheAppliedEffort() {
    let reply: JSONValue = .object([
      "applied": .object(["model": .string("claude-opus-5-5"), "effort": .string("high")])
    ])
    #expect(EffortLevel.applied(fromSettings: reply) == "high")
    #expect(
      EffortLevel.applied(fromSettings: .object(["applied": .object(["effort": .null])])) == nil)
  }

  @Test func namesEffortLevels() {
    #expect(EffortLevel.title(of: "low") == "Low")
    #expect(EffortLevel.title(of: "xhigh") == "Extra high")
    #expect(EffortLevel.title(of: "max") == "Max")
    #expect(EffortLevel.title(of: "turbo") == "turbo")
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

  /// `get_settings`' `applied`: the model the process runs, whatever was asked of it.
  /// Settings can turn auto mode off while every model still says it takes it: the reply to
  /// `get_settings` says so in its `effective` settings, under `permissions` or at the top, as
  /// the extension reads them (2.1.312, 2026-10-28, a project `settings.json` holding
  /// `{"permissions":{"disableAutoMode":"disable"}}`).
  @Test func readsWhetherSettingsTurnAutoModeOff() throws {
    let off = try JSONValue.parse(
      Data(
        #"{"effective":{"permissions":{"disableAutoMode":"disable"}},"applied":{"model":"claude-opus-5-5","effort":"high"}}"#
          .utf8))
    #expect(AutoMode.isDisabled(bySettings: off))
    #expect(
      AutoMode.isDisabled(
        bySettings: .object(["effective": .object(["disableAutoMode": .string("disable")])])))
    #expect(
      !AutoMode.isDisabled(
        bySettings: .object(["effective": .object(["permissions": .object([:])])])))
    #expect(
      !AutoMode.isDisabled(
        bySettings: .object([
          "effective": .object(["permissions": .object(["disableAutoMode": .string("enable")])])
        ])))
    #expect(!AutoMode.isDisabled(bySettings: nil))
  }

  @Test func readsTheModelTheProcessRuns() throws {
    let reply = try JSONValue.parse(
      Data(#"{"applied":{"model":"claude-haiku-4-5-20251001","effort":null}}"#.utf8))
    #expect(ModelName.applied(fromSettings: reply) == "claude-haiku-4-5-20251001")
    #expect(EffortLevel.applied(fromSettings: reply) == nil)
    #expect(ModelName.applied(fromSettings: .object([:])) == nil)
  }
}
