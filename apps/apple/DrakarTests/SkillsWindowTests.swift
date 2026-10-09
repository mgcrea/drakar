import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("How the Skills window words a skill")
struct SkillsWindowTests {
  private let home = "/Users/me"

  @Test func pathsUnderHomeStartWithATilde() {
    #expect(SkillText.path("/Users/me/.claude/skills/x/", home: home) == "~/.claude/skills/x")
    #expect(SkillText.path("/Users/me", home: home) == "~")
    #expect(SkillText.path("/Users/meadow/x", home: home) == "/Users/meadow/x")
  }

  @Test func aLinksLocationNamesItsTarget() {
    let linked = SkillRecord(
      name: "find-skills", description: "", kind: .skill, origin: .user,
      realPath: "/Users/me/.agents/skills/find-skills",
      sightings: [
        SkillSighting(agent: .claude, path: "/Users/me/.claude/skills/find-skills", isLink: true),
        SkillSighting(agent: .codex, path: "/Users/me/.agents/skills/find-skills"),
      ])
    #expect(
      SkillText.location(of: linked, home: home)
        == "~/.claude/skills/find-skills → ~/.agents/skills/find-skills")
    let plain = SkillRecord(
      name: "deploy", description: "", kind: .skill, origin: .project,
      realPath: "/Users/me/p/.agents/skills/deploy",
      sightings: [SkillSighting(agent: .codex, path: "/Users/me/p/.agents/skills/deploy")])
    #expect(SkillText.location(of: plain, home: home) == "~/p/.agents/skills/deploy")
    let unknown = SkillRecord(
      name: "mystery", description: "", kind: .skill, origin: .unknown, realPath: "",
      sightings: [SkillSighting(agent: .claude, path: nil)])
    #expect(SkillText.location(of: unknown, home: home) == "")
  }

  @Test func originsReadAsTheColumnSaysThem() {
    #expect(
      [SkillOrigin.user, .project, .plugin("tools@market"), .codexSystem, .codexAdmin, .unknown]
        .map(SkillText.origin) == [
          "Yours", "Project", "tools@market", "Codex system", "Codex admin", "Unknown",
        ])
  }

  @Test func theNameCellSaysWhatHoldsASkillBack() {
    var record = SkillRecord(
      name: "x", description: "", kind: .skill, origin: .user, realPath: "/x",
      sightings: [SkillSighting(agent: .claude, path: "/x")])
    #expect(SkillText.caption(of: record) == nil)
    #expect(SkillText.notes(of: record).isEmpty)
    record.notLoadedByClaude = true
    #expect(SkillText.caption(of: record) == "Not loaded by Claude Code")
    record.notLoadedByClaude = false
    record.sightings.append(SkillSighting(agent: .codex, path: "/x", isShadowed: true))
    #expect(SkillText.caption(of: record) == "Shadowed")
    record.sightings[1].isEnabled = false
    #expect(SkillText.notes(of: record).contains("Turned off for Codex"))
  }

  @Test func eachPlaceHasATitle() {
    #expect(
      SkillsPlace.allCases.map(\.title) == [
        "All", "Yours", "This project", "Plugins", "Codex built-in",
      ])
  }
}
