import DrakarKit
import Foundation
import Testing

@Suite("Codex's skills, listed and sent")
struct CodexSkillsTests {
  private func entries() throws -> [SkillEntry] {
    CodexSkillList.entries(try Fixture.codexSkillsList)
  }

  /// A disabled skill is not offered; the rest are sorted as Claude Code's are.
  @Test func listsTheEnabledSkillsSorted() throws {
    #expect(try entries().map(\.name) == ["data:analyze", "deploy", "skill-creator"])
  }

  /// A name listed twice is offered once: the repo's over the user's, the user's over the
  /// admin's, the admin's over the system's.
  @Test func aNameListedTwiceKeepsTheNearestScope() throws {
    let creator = try #require(try entries().first { $0.name == "skill-creator" })
    #expect(creator.path == "/Users/me/.agents/skills/skill-creator/SKILL.md")
    #expect(creator.description == "My own way to write a skill.")
    func skill(_ scope: String) -> JSONValue {
      .object([
        "name": .string("x"), "description": .string(scope), "path": .string("/\(scope)"),
        "scope": .string(scope), "enabled": .bool(true),
      ])
    }
    func kept(_ scopes: [String]) -> String? {
      let result: JSONValue = .object([
        "data": .array([.object(["skills": .array(scopes.map(skill))])])
      ])
      return CodexSkillList.entries(result).first?.description
    }
    #expect(kept(["system", "admin"]) == "admin")
    #expect(kept(["admin", "user"]) == "user")
    #expect(kept(["user", "repo", "system"]) == "repo")
    #expect(kept(["user", "user"]) == "user")
  }

  /// The interface's short description, else the legacy one, else the whole description.
  @Test func describesASkillByItsShortestDescription() throws {
    let byName = Dictionary(uniqueKeysWithValues: try entries().map { ($0.name, $0) })
    #expect(byName["deploy"]?.description == "Deploy to staging")
    #expect(byName["data:analyze"]?.description == "Analyze data")
    #expect(byName["data:analyze"]?.shortName == "analyze")
    #expect(byName["data:analyze"]?.namespace == "data")
  }

  /// A skill takes no arguments a click must wait for, is not a CLI's own command, and
  /// carries the SKILL.md a prompt names.
  @Test func aSkillCarriesItsPath() throws {
    let deploy = try #require(try entries().first { $0.name == "deploy" })
    #expect(!deploy.takesArguments)
    #expect(!deploy.isBuiltin)
    #expect(deploy.path == "/Users/me/project/.agents/skills/deploy/SKILL.md")
  }

  @Test func anAnswerWithoutSkillsListsNone() {
    #expect(CodexSkillList.entries(.null).isEmpty)
    #expect(CodexSkillList.entries(.object(["data": .array([])])).isEmpty)
  }

  private let deploy = SkillEntry(
    name: "deploy", description: "Deploy to staging",
    path: "/Users/me/project/.agents/skills/deploy/SKILL.md")
  private let analyze = SkillEntry(
    name: "data:analyze", path: "/Users/me/.codex/plugins/cache/data/skills/analyze/SKILL.md")

  private func skillItem(_ skill: SkillEntry) -> JSONValue {
    .object([
      "type": .string("skill"), "name": .string(skill.name), "path": .string(skill.path ?? ""),
    ])
  }

  /// `/deploy now` names the skill: the text as typed, then the skill item, then the
  /// attachments; the editor's context still comes first.
  @Test func aPromptNamingASkillSendsItsItem() throws {
    let selection = EditorSelection(
      filePath: "/p/a.swift", text: "", start: .init(line: 0, character: 0),
      end: .init(line: 0, character: 0))
    let image = try Attachment.image(
      try #require(Data(base64Encoded: CodexPolicyTests.redPixel)), name: "red.png")
    let items = try #require(
      CodexInput.make(
        text: "/deploy now", context: [selection], attachments: [image], skills: [analyze, deploy]
      ).arrayValue)
    #expect(items.count == 4)
    #expect(items[0]["text"]?.stringValue == selection.promptContext)
    #expect(items[1] == CodexInput.text("/deploy now"))
    #expect(items[2] == skillItem(deploy))
    #expect(items[3]["type"] == .string("image"))
  }

  /// The name alone, a plugin's full name, and a name ending the line all match.
  @Test func theNameMatchesWholeAndExactly() {
    func items(_ text: String) -> JSONValue {
      CodexInput.make(text: text, context: [], attachments: [], skills: [analyze, deploy])
    }
    #expect(items("/deploy") == .array([CodexInput.text("/deploy"), skillItem(deploy)]))
    #expect(
      items("/deploy\nto staging")
        == .array([CodexInput.text("/deploy\nto staging"), skillItem(deploy)]))
    #expect(
      items("/data:analyze sales.csv")
        == .array([CodexInput.text("/data:analyze sales.csv"), skillItem(analyze)]))
    for text in ["/deployed", "/analyze sales.csv", "deploy", "please /deploy", "/Deploy", "/"] {
      #expect(items(text) == .array([CodexInput.text(text)]))
    }
  }

  /// A skill without a path cannot be named, and no skills at all is today's input.
  @Test func withoutAPathTheTextGoesAlone() {
    let bare = SkillEntry(name: "deploy")
    #expect(
      CodexInput.make(text: "/deploy", context: [], attachments: [], skills: [bare])
        == .array([CodexInput.text("/deploy")]))
    #expect(
      CodexInput.make(text: "/deploy", context: [], attachments: [])
        == .array([CodexInput.text("/deploy")]))
  }

  /// History shows the prompt as typed: the skill item adds nothing to it.
  @Test func historyShowsASkillPromptAsTyped() {
    let entry: JSONValue = .object([
      "turnId": .string("turn-1"),
      "item": .object([
        "type": .string("userMessage"), "id": .string("u"), "clientId": .null,
        "content": .array([
          CodexInput.text("/probe beta"),
          .object([
            "type": .string("skill"), "name": .string("probe"),
            "path": .string("/Users/me/project/.agents/skills/probe/SKILL.md"),
          ]),
        ]),
      ]),
    ])
    var t = Transcript()
    for event in CodexTranslator.history([entry]) { t.apply(event) }
    let prompts = t.entries.filter { if case .prompt = $0.kind { true } else { false } }
    #expect(prompts.map(\.kind) == [.prompt("/probe beta")])
    #expect(prompts.first?.attachments.isEmpty == true)
    #expect(prompts.first?.context == nil)
  }
}
