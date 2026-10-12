import DrakarKit
import Foundation
import Testing

@Suite("Which subfolders Claude Code finds a skill in")
struct SkillReachTests {
  private let root: URL
  private let account: URL
  private let parent: URL
  private let one: URL
  private let two: URL

  init() throws {
    root = URL(
      filePath: SkillPath.real(FileManager.default.temporaryDirectory.path(percentEncoded: false)),
      directoryHint: .isDirectory
    ).appending(path: "drakar-reach-\(UUID().uuidString)", directoryHint: .isDirectory)
    account = root.appending(path: ".claude-test", directoryHint: .isDirectory)
    parent = root.appending(path: "apps", directoryHint: .isDirectory)
    one = parent.appending(path: "one", directoryHint: .isDirectory)
    two = parent.appending(path: "two", directoryHint: .isDirectory)
    for folder in [account, one, two] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
  }

  private func skill(_ name: String, in folder: URL) throws {
    let dir = folder.appending(path: "skills/\(name)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("---\nname: \(name)\n---\n".utf8).write(to: dir.appending(path: "SKILL.md"))
  }

  private func missing(_ name: String, builtin: Bool = false) -> Set<URL> {
    SkillReach.claudeMissing(
      name: name, isBuiltin: builtin, account: account, parent: parent, folders: [one, two])
  }

  /// The account's skills reach every folder.
  @Test func aUserSkillIsEverywhere() throws {
    try skill("check", in: account)
    try skill("check", in: parent.appending(path: ".claude"))
    #expect(missing("check").isEmpty)
  }

  /// The CLI's own reach every folder.
  @Test func aBuiltinIsEverywhere() throws {
    try skill("compact", in: parent.appending(path: ".claude"))
    #expect(missing("compact", builtin: true).isEmpty)
  }

  /// One from the parent's `.claude/skills` reaches only the folders holding their own.
  @Test func aParentProjectSkillIsMissingWhereNotHeld() throws {
    try skill("deploy", in: parent.appending(path: ".claude"))
    try skill("deploy", in: one.appending(path: ".claude"))
    #expect(missing("deploy") == [two])
  }

  /// A project command counts as held too.
  @Test func aCommandCountsAsHeld() throws {
    try skill("ship", in: parent.appending(path: ".claude"))
    let commands = two.appending(path: ".claude/commands", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
    try Data("Ship it\n".utf8).write(to: commands.appending(path: "ship.md"))
    #expect(missing("ship") == [one])
  }

  /// One Drakar finds nowhere (managed settings, a source it doesn't read) is not marked
  /// missing everywhere: unknown is reachable.
  @Test func anUnknownSkillIsReachableEverywhere() {
    #expect(missing("mystery").isEmpty)
  }
}
