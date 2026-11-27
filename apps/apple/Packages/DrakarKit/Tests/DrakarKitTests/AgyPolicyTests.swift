import DrakarKit
import Foundation
import Testing

@Suite("Agy policy, models and input")
struct AgyPolicyTests {
  private static let redPixel =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

  private func json(_ text: String) throws -> JSONValue {
    try JSONValue.parse(Data(text.utf8))
  }

  @Test func mapsPermissionModesBothWays() {
    #expect(AgyPolicy.offeredModes(allowsBypass: false) == [.ask, .acceptEdits, .plan, .auto])
    #expect(
      AgyPolicy.offeredModes(allowsBypass: true) == [.ask, .acceptEdits, .plan, .auto, .bypass])
    #expect(AgyPolicy.modeID(.ask) == "default")
    #expect(AgyPolicy.modeID(.acceptEdits) == "accept-edits")
    #expect(AgyPolicy.modeID(.plan) == "plan")
    #expect(AgyPolicy.modeID(.auto) == "auto")
    #expect(AgyPolicy.modeID(.bypass) == "auto")

    #expect(AgyPolicy.permissionMode(from: "default") == .ask)
    #expect(AgyPolicy.permissionMode(from: "accept-edits") == .acceptEdits)
    #expect(AgyPolicy.permissionMode(from: "plan") == .plan)
    #expect(AgyPolicy.permissionMode(from: "auto") == .auto)
    #expect(AgyPolicy.permissionMode(from: "unknown") == nil)

    #expect(AgyPolicy.letsThrough(in: .bypass))
    #expect(!AgyPolicy.letsThrough(in: .ask))
    #expect(!AgyPolicy.letsThrough(in: .auto))
  }

  @Test func mapsPermissionDecisionsAndSuggestions() throws {
    let options = [
      AgyPolicy.Option(optionID: "allow_once_id", name: "Allow", kind: "allow_once"),
      AgyPolicy.Option(optionID: "allow_always_id", name: "Always Allow", kind: "allow_always"),
      AgyPolicy.Option(optionID: "deny_once_id", name: "Deny", kind: "reject_once"),
    ]
    let suggestions = AgyPolicy.suggestions(from: options)
    #expect(suggestions.count == 1)
    let parsed = try #require(PermissionSuggestion(suggestions[0], id: 0))
    #expect(parsed.kind == .agyOption(id: "allow_always_id", name: "Always Allow"))

    #expect(
      AgyPolicy.result(.allow(updatedInput: .null), options: options)
        == AgyPolicy.selected("allow_once_id"))
    #expect(
      AgyPolicy.result(
        .allow(updatedInput: .null, updatedPermissions: suggestions), options: options)
        == AgyPolicy.selected("allow_always_id"))
    #expect(
      AgyPolicy.result(.deny(message: "no", interrupt: false), options: options)
        == AgyPolicy.selected("deny_once_id"))
    #expect(
      AgyPolicy.result(.deny(message: "no", interrupt: true), options: options)
        == AgyPolicy.cancelled)
  }

  @Test func parsesModelsAndEffortLevelsFromSessionNew() throws {
    let payload = try json(
      #"""
      {
        "sessionId": "s-1",
        "models": {
          "currentModelId": "gemini-4-neon-high",
          "availableModels": [
            {"modelId": "gemini-4-neon-high", "name": "Gemini 4 Neon (High)"},
            {"modelId": "gemini-4-neon-xhigh", "name": "Gemini 4 Neon (XHigh)"},
            {"modelId": "gemini-4-neon-low", "name": "Gemini 4 Neon (Low)"},
            {"modelId": "gemini-3.8-flash-medium", "name": "Gemini 3.8 Flash (Medium)"},
            {"modelId": "gemini-3.8-flash-low", "name": "Gemini 3.8 Flash (Low)"},
            {"modelId": "gemini-pro-orchestrator-neon", "name": "Orchestrator (Neon)"}
          ]
        },
        "modes": {"currentModeId": "accept-edits"},
        "configOptions": [
          {
            "id": "model",
            "currentValue": "gemini-4-neon",
            "options": [
              {"value": "gemini-4-neon", "name": "Gemini 4 Neon"},
              {"value": "gemini-3.8-flash", "name": "Gemini 3.8 Flash"},
              {"value": "gemini-pro-orchestrator-neon", "name": "Orchestrator (Neon)"}
            ]
          },
          {
            "id": "thought_level",
            "currentValue": "high",
            "options": [
              {"value": "low", "name": "Low"},
              {"value": "high", "name": "High"},
              {"value": "xhigh", "name": "Extra"}
            ]
          },
          {
            "id": "mode",
            "currentValue": "accept-edits"
          }
        ]
      }
      """#)
    let snap = AgyModels.snapshot(from: payload)
    #expect(snap.currentModel == "gemini-4-neon")
    #expect(snap.currentEffort == "high")
    #expect(snap.currentMode == .acceptEdits)
    #expect(snap.models.count == 3)
    #expect(snap.models[0].value == "gemini-4-neon")
    #expect(snap.models[0].displayName == "Gemini 4 Neon")
    #expect(snap.models[0].effortLevels == ["low", "high", "xhigh"])
    #expect(snap.models[0].supportsAutoMode == true)
    #expect(snap.models[1].effortLevels == ["low", "medium"])
    #expect(snap.models[2].effortLevels == [])
  }

  @Test func buildsPromptWithContextImageAndTextAttachment() throws {
    let selection = EditorSelection(
      filePath: "/p/main.swift", text: "let x = 1", start: .init(line: 2, character: 0),
      end: .init(line: 2, character: 9))
    let image = try Attachment.image(
      try #require(Data(base64Encoded: Self.redPixel)), name: "red.png")
    let temp = FileManager.default.temporaryDirectory.appending(path: "agy-note-\(UUID()).txt")
    try "hello\n".write(to: temp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: temp) }
    let file = try Attachment.file(at: temp)

    let blocks = try #require(
      AgyInput.make(text: "Check this", context: [selection], attachments: [image, file])
        .arrayValue)
    #expect(blocks.count == 4)
    #expect(blocks[0] == AgyInput.text(selection.promptContext))
    #expect(blocks[1] == AgyInput.text("Check this"))
    #expect(blocks[2]["type"] == .string("image"))
    #expect(blocks[2]["mimeType"] == .string("image/png"))
    #expect(blocks[2]["data"] == .string(Self.redPixel))
    #expect(
      blocks[3]
        == AgyInput.text("<attachment name=\"\(temp.lastPathComponent)\">\nhello\n\n</attachment>")
    )
  }

  @Test func parsesAvailableCommands() throws {
    let update = try json(
      #"""
      {
        "sessionUpdate": "available_commands_update",
        "availableCommands": [
          {"name": "plan", "description": "Plan first."},
          {"name": "goal", "description": "Run until done.", "input": {"hint": "<goal>"}}
        ]
      }
      """#)
    let list = try #require(AgyInput.commands(from: update))
    #expect(list.map(\.name) == ["goal", "plan"])
    #expect(list[0].argumentHint == "<goal>")
    #expect(list[0].takesArguments)
    #expect(!list[1].takesArguments)
  }
}
