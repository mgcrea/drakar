import DrakarKit
import Foundation
import Testing

/// The `/` menu: every command the CLI lists, its own included, matched as the name is typed.
@Suite("The slash menu")
struct SlashCommandTests {

  private let reply: JSONValue = .object([
    "commands": .array([
      .object([
        "name": .string("compact"), "description": .string("Free up context"),
        "argumentHint": .string("<instructions>"), "builtin": .bool(true),
      ]),
      .object(["name": .string("clear"), "builtin": .bool(true)]),
      .object(["name": .string("__remote-workflow"), "builtin": .bool(true)]),
      .object([
        "name": .string("superpowers:brainstorming"), "description": .string("Before creating"),
      ]),
      .object(["name": .string("check"), "description": .string("Fixes all failing tests")]),
    ])
  ])

  @Test func listsTheCLIsOwnCommandsButNotItsInternalOnes() throws {
    let commands = try #require(ProjectCapabilities.commands(fromInitialize: reply))
    #expect(
      commands.map(\.name) == ["superpowers:brainstorming", "check", "clear", "compact"])
    #expect(commands.first { $0.name == "compact" }?.isBuiltin == true)
    // The inspector's list stays the skills alone.
    #expect(
      ProjectCapabilities.skills(fromInitialize: reply)?.map(\.name)
        == ["superpowers:brainstorming", "check"])
  }

  /// `commands_changed` carries the list bare.
  @Test func readsABareList() throws {
    let list = try #require(reply["commands"])
    #expect(ProjectCapabilities.commands(fromInitialize: list)?.count == 4)
  }

  @Test func onlyAtTheStartOfTheDraftBeforeASpace() {
    #expect(SlashCommand.query(in: "/") == "")
    #expect(SlashCommand.query(in: "/comp") == "comp")
    #expect(SlashCommand.query(in: "/compact now") == nil)
    #expect(SlashCommand.query(in: "say /comp") == nil)
    #expect(SlashCommand.query(in: "") == nil)
  }

  /// The start of the name, or of the part after a namespace, before anywhere inside it.
  @Test func matchesStartsFirst() throws {
    let commands = try #require(ProjectCapabilities.commands(fromInitialize: reply))
    #expect(SlashCommand.matches("c", in: commands).map(\.name) == ["check", "clear", "compact"])
    #expect(
      SlashCommand.matches("brain", in: commands).map(\.name) == ["superpowers:brainstorming"])
    #expect(SlashCommand.matches("pact", in: commands).map(\.name) == ["compact"])
    #expect(SlashCommand.matches("", in: commands).count == 4)
    #expect(SlashCommand.matches("zzz", in: commands).isEmpty)
  }
}
