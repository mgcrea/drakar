import DrakarKit
import Foundation
import Testing

@Suite("Finding skills to install")
struct SkillInstallSearchTests {
  private let root = URL(
    filePath: SkillPath.real(FileManager.default.temporaryDirectory.path(percentEncoded: false)),
    directoryHint: .isDirectory
  ).appending(path: "drakar-search-\(UUID().uuidString)", directoryHint: .isDirectory)

  private func cleanUp() { try? FileManager.default.removeItem(at: root) }

  private func skill(_ relative: String) throws {
    let folder = root.appending(path: relative, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("---\nname: x\n---\n".utf8).write(to: folder.appending(path: "SKILL.md"))
  }

  /// Each found folder below `root`, as a relative path.
  private func names(_ found: [URL]) -> [String] {
    let base = root.path(percentEncoded: false)
    return found.map {
      String($0.path(percentEncoded: false).dropFirst(base.count))
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
  }

  @Test func aFolderHoldingASkillIsThatSkill() throws {
    defer { cleanUp() }
    try skill("one")
    try skill("one/inner")
    #expect(
      names(
        SkillFolderSearch.skills(
          in: root.appending(path: "one", directoryHint: .isDirectory), depth: 3))
        == ["one"])
  }

  /// A skill's own folders are not searched, nor hidden ones; nothing deeper than `depth`.
  @Test func aFolderOfSkillsOffersEachDownToTheDepth() throws {
    defer { cleanUp() }
    for relative in [
      "a", "group/b", "deep/x/c", "deeper/x/y/d", "a/nested", ".git/e", "node/.hidden/f",
    ] {
      try skill(relative)
    }
    #expect(names(SkillFolderSearch.skills(in: root, depth: 3)) == ["a", "deep/x/c", "group/b"])
    #expect(
      names(SkillFolderSearch.skills(in: root, depth: 4)) == [
        "a", "deep/x/c", "deeper/x/y/d", "group/b",
      ])
    #expect(SkillFolderSearch.skills(in: root.appending(path: "missing"), depth: 3).isEmpty)
  }

  @Test func readsWhereAGitAddressClonesTo() {
    let skills = GitSource(host: "github.com", owner: "me", repo: "skills")
    #expect(GitSource("https://github.com/me/skills") == skills)
    #expect(GitSource("https://GitHub.com/me/skills.git/") == skills)
    #expect(GitSource("git@github.com:me/skills.git") == skills)
    #expect(GitSource("  https://github.com/me/skills \n") == skills)
    #expect(
      GitSource("ssh://git@gitlab.example.com/team/sub/tools.git")
        == GitSource(host: "gitlab.example.com", owner: "sub", repo: "tools"))
    #expect(
      GitSource("file:///Users/me/src/skills")
        == GitSource(host: "local", owner: "src", repo: "skills"))
  }

  /// Nothing that would put a clone outside its folder, or is not a repository's address.
  @Test func refusesWhatIsNotARepository() {
    for text in [
      "skills please", "github.com/me/skills", "https://github.com/me",
      "https://github.com/me/../../etc", "ftp://host/me/skills", "git@github.com:skills", "",
    ] {
      #expect(GitSource(text) == nil, "\(text)")
    }
  }

  @Test func aCloneGoesUnderHostOwnerAndRepo() {
    let sources = URL(filePath: "/Users/me/.agents/skill-sources", directoryHint: .isDirectory)
    #expect(
      GitSource("git@github.com:me/skills.git")?.folder(in: sources).path(percentEncoded: false)
        == "/Users/me/.agents/skill-sources/github.com/me/skills/")
  }
}
