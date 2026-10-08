import DrakarKit
import Foundation
import Testing

@Suite("Codex's policies, models and input")
struct CodexPolicyTests {
  private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

  @Test func modesMapOntoPolicyAndSandbox() throws {
    #expect(
      CodexPolicy.threadSettings(.ask)
        == ["approvalPolicy": .string("untrusted"), "sandbox": .string("workspace-write")])
    #expect(
      CodexPolicy.threadSettings(.acceptEdits)
        == ["approvalPolicy": .string("on-request"), "sandbox": .string("workspace-write")])
    #expect(
      CodexPolicy.threadSettings(.bypass)
        == ["approvalPolicy": .string("never"), "sandbox": .string("danger-full-access")])
    // Codex has no plan or auto mode here: they ask, as Ask before edits does.
    #expect(CodexPolicy.threadSettings(.plan) == CodexPolicy.threadSettings(.ask))
    #expect(
      CodexPolicy.turnSettings(.ask)["sandboxPolicy"]
        == (try json(
          #"{"type":"workspaceWrite","writableRoots":[],"networkAccess":false,"excludeTmpdirEnvVar":false,"excludeSlashTmp":false}"#
        )))
    #expect(
      CodexPolicy.turnSettings(.bypass)
        == [
          "approvalPolicy": .string("never"),
          "sandboxPolicy": .object(["type": .string("dangerFullAccess")]),
        ])
  }

  @Test func offersThreeModesAtMost() {
    #expect(CodexPolicy.offeredModes(allowsBypass: true) == [.ask, .acceptEdits, .bypass])
    #expect(CodexPolicy.offeredModes(allowsBypass: false) == [.ask, .acceptEdits])
  }

  @Test func aModeLetsThroughWhatItRunsUnasked() {
    let command = "item/commandExecution/requestApproval"
    let file = "item/fileChange/requestApproval"
    #expect(CodexPolicy.letsThrough(command, in: .bypass))
    #expect(CodexPolicy.letsThrough(file, in: .bypass))
    #expect(CodexPolicy.letsThrough(file, in: .acceptEdits))
    #expect(!CodexPolicy.letsThrough(command, in: .acceptEdits))
    #expect(!CodexPolicy.letsThrough(file, in: .ask))
    #expect(!CodexPolicy.letsThrough(command, in: .ask))
  }

  @Test func decisionsMapOntoCodexs() {
    #expect(CodexPolicy.decision(.allow(updatedInput: .null)) == .string("accept"))
    #expect(
      CodexPolicy.decision(
        .allow(updatedInput: .null, updatedPermissions: [CodexPolicy.acceptForSession]))
        == .string("acceptForSession"))
    #expect(CodexPolicy.decision(.deny(message: "no")) == .string("decline"))
    #expect(CodexPolicy.decision(.deny(message: "no", interrupt: true)) == .string("cancel"))
  }

  @Test func theSessionSuggestionHasAKindOfItsOwn() {
    let suggestion = PermissionSuggestion(CodexPolicy.acceptForSession, id: 0)
    #expect(suggestion?.kind == .codexDecision("acceptForSession"))
    #expect(suggestion?.isPersistent == false)
  }

  @Test func listsVisibleModelsWithTheirEfforts() throws {
    let models = CodexModels.list(
      try json(
        #"{"data":[{"id":"gpt-6.1-sol","model":"gpt-6.1-sol","displayName":"GPT-6.1-Sol","description":"Workhorse","hidden":false,"isDefault":true,"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},{"reasoningEffort":"ultra","description":"Max"}]},{"id":"old","model":"old","displayName":"Old","hidden":true,"supportedReasoningEfforts":[]}],"nextCursor":null}"#
      ))
    #expect(
      models == [
        ModelOption(
          value: "gpt-6.1-sol", resolvedModel: "gpt-6.1-sol", displayName: "GPT-6.1-Sol",
          description: "Workhorse", effortLevels: ["low", "ultra"])
      ])
    #expect(EffortLevel.title(of: "ultra") == "Ultra")
  }

  @Test func aPromptBecomesCodexInput() throws {
    let selection = EditorSelection(
      filePath: "/p/a.swift", text: "", start: .init(line: 0, character: 0),
      end: .init(line: 0, character: 0))
    let image = try Attachment.image(
      try #require(Data(base64Encoded: Self.redPixel)), name: "red.png")
    let input = CodexInput.make(text: "Look", context: [selection], attachments: [image])
    let items = try #require(input.arrayValue)
    #expect(items.count == 3)
    #expect(items[0]["text"]?.stringValue == selection.promptContext)
    #expect(items[1] == CodexInput.text("Look"))
    #expect(items[2]["type"] == .string("image"))
    #expect(items[2]["url"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)
  }

  @Test func aTextFileGoesInline() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "codex-input-\(UUID()).txt")
    try "hello\n".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try Attachment.file(at: url)
    let items = try #require(CodexInput.make(text: "", context: [], attachments: [file]).arrayValue)
    #expect(
      items == [
        CodexInput.text("<attachment name=\"\(url.lastPathComponent)\">\nhello\n\n</attachment>")
      ])
  }

  /// A 1×1 red PNG.
  static let redPixel =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
}
