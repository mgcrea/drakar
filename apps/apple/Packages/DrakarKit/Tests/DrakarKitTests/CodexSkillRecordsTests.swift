import DrakarKit
import Foundation
import Testing

@Suite("Codex's skills, every one kept")
struct CodexSkillRecordsTests {
  private func records() throws -> [CodexSkillRecord] {
    CodexSkillList.records(try Fixture.codexSkillsList)
  }

  /// Shadowed and disabled skills are kept, in the order Codex listed them.
  @Test func keepsEverySkillListed() throws {
    #expect(
      try records().map(\.name) == [
        "skill-creator", "deploy", "skill-creator", "data:analyze", "legacy-notes",
      ])
  }

  @Test func keepsWhereEachComesFrom() throws {
    let all = try records()
    #expect(all.map(\.scope) == [.system, .repo, .user, .user, .repo])
    #expect(all.map(\.origin) == [.codexSystem, .project, .user, .plugin("data"), .project])
    #expect(all[1].path == "/Users/me/project/.agents/skills/deploy/SKILL.md")
    #expect(all[3].pluginID == "data")
    #expect(all[0].pluginID == nil)
  }

  /// The system skill-creator loses to the user's; a disabled skill is off, not shadowed.
  @Test func marksTheShadowedAndTheDisabled() throws {
    let all = try records()
    #expect(all.map(\.isShadowed) == [true, false, false, false, false])
    #expect(all.map(\.isEnabled) == [true, true, true, true, false])
  }

  /// The whole description, for the manager; a shorter one only when there is no other.
  @Test func describesASkillInFull() throws {
    let all = try records()
    #expect(
      all[1].description
        == "Deploy the project to staging once the checks pass, then say where it runs.")
    let bare: JSONValue = .object([
      "data": .array([
        .object([
          "skills": .array([
            .object([
              "name": .string("x"), "path": .string("/x/SKILL.md"), "scope": .string("user"),
              "enabled": .bool(true), "shortDescription": .string("Short"),
            ])
          ])
        ])
      ])
    ])
    #expect(CodexSkillList.records(bare).first?.description == "Short")
  }

  /// An admin skill, a scope this version does not know, and entries without a name or path.
  @Test func readsOddEntries() {
    let result: JSONValue = .object([
      "data": .array([
        .object([
          "skills": .array([
            .object([
              "name": .string("a"), "path": .string("/a/SKILL.md"), "scope": .string("admin"),
              "enabled": .bool(true),
            ]),
            .object([
              "name": .string("b"), "path": .string("/b/SKILL.md"), "scope": .string("team"),
              "enabled": .bool(true),
            ]),
            .object(["name": .string(""), "path": .string("/c/SKILL.md")]),
            .object(["name": .string("d")]),
          ])
        ])
      ])
    ])
    let all = CodexSkillList.records(result)
    #expect(all.map(\.name) == ["a", "b"])
    #expect(all.map(\.origin) == [.codexAdmin, .unknown])
    #expect(all[1].scope == .other("team"))
    #expect(CodexSkillList.records(.null).isEmpty)
  }

  /// One answer serves the `/` menu and the manager.
  @Test func aListingCarriesBoth() throws {
    let result = try Fixture.codexSkillsList
    let listing = CodexSkillList.listing(result)
    #expect(listing.entries == CodexSkillList.entries(result))
    #expect(listing.records == CodexSkillList.records(result))
    #expect(CodexSkillList.Listing().entries.isEmpty)
  }

  @Test func eachAgentKnowsTheOther() {
    #expect(SkillAgent.claude.other == .codex)
    #expect(SkillAgent.codex.other == .claude)
    #expect(SkillOrigin.user.isOwn && SkillOrigin.project.isOwn)
    #expect(!SkillOrigin.plugin("x").isOwn && !SkillOrigin.codexSystem.isOwn)
  }
}
