import DrakarKit
import Foundation
import Testing

@Suite("Linked worktrees")
struct GitCheckoutTests {

  private func entries(_ map: [String: GitEntry]) -> (String) -> GitEntry {
    { map[$0] ?? .none }
  }

  @Test func aRepositoryIsItsOwnMainCheckout() {
    let checkout = GitCheckout.locate(
      "/w/drakar/apps/apple", entry: entries(["/w/drakar/.git": .directory]))
    #expect(checkout == GitCheckout(root: "/w/drakar", main: "/w/drakar"))
    #expect(checkout?.inMain("/w/drakar/apps/apple") == "/w/drakar/apps/apple")
  }

  @Test func aLinkedWorktreeMovesIntoItsMainCheckout() {
    let checkout = GitCheckout.locate(
      "/w/drakar-feature/apps",
      entry: entries([
        "/w/drakar-feature/.git": .file("gitdir: /w/drakar/.git/worktrees/drakar-feature\n")
      ]))
    #expect(checkout == GitCheckout(root: "/w/drakar-feature", main: "/w/drakar"))
    #expect(checkout?.inMain("/w/drakar-feature/apps") == "/w/drakar/apps")
  }

  @Test func aRelativeGitDirIsReadFromTheWorktree() {
    let checkout = GitCheckout.locate(
      "/w/wt", entry: entries(["/w/wt/.git": .file("gitdir: ../drakar/.git/worktrees/wt")]))
    #expect(checkout?.main == "/w/drakar")
  }

  @Test func aSubmoduleIsItsOwnRepository() {
    let checkout = GitCheckout.locate(
      "/w/drakar/vendor/lib",
      entry: entries([
        "/w/drakar/vendor/lib/.git": .file("gitdir: ../../.git/modules/lib"),
        "/w/drakar/.git": .directory,
      ]))
    #expect(checkout == GitCheckout(root: "/w/drakar/vendor/lib", main: "/w/drakar/vendor/lib"))
  }

  @Test func outsideARepositoryThereIsNone() {
    #expect(GitCheckout.locate("/w/notes", entry: entries([:])) == nil)
  }

  @Test func readsARealWorktreeFile() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "wt-\(UUID())")
    let worktree = root.appending(path: "feature/apps")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appending(path: "main/.git/worktrees/feature"), withIntermediateDirectories: true)
    let rootPath = root.path(percentEncoded: false)
    try "gitdir: \(rootPath)/main/.git/worktrees/feature\n".write(
      to: root.appending(path: "feature/.git"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }
    let checkout = GitCheckout.locate(worktree.path(percentEncoded: false))
    #expect(checkout?.main == ProjectPath.normalize(rootPath + "/main"))
  }
}

@Suite("A project's row on home")
struct ProjectStatsTests {

  private let account = ClaudeAccount(directory: URL(filePath: "/a/.claude"), isDefault: true)
  private let other = ClaudeAccount(directory: URL(filePath: "/a/.claude-work"), isDefault: false)
  private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

  private func folder(
    _ cwd: String, ids: Set<String>, hoursAgo: Double, checkout: String? = nil,
    repository: String? = nil, account: ClaudeAccount? = nil
  ) -> TranscriptFolder {
    let account = account ?? self.account
    let name = cwd.replacingOccurrences(of: "/", with: "-")
    return TranscriptFolder(
      account: account, folder: account.directory.appending(path: "projects/\(name)"),
      sessionIDs: ids, newest: account.directory.appending(path: "projects/\(name)/n.jsonl"),
      newestModified: now.addingTimeInterval(-hoursAgo * 3600), cwd: cwd, checkout: checkout,
      repository: repository)
  }

  @Test func countsSessionsBelowTheProjectAndKeepsTheNewest() {
    let stats = ProjectStats.compute(
      projects: ["/w/drakar"],
      folders: [
        folder("/w/drakar", ids: ["a", "b"], hoursAgo: 5),
        folder("/w/drakar/apps/apple", ids: ["c"], hoursAgo: 1),
        folder("/w/drakar-old", ids: ["d"], hoursAgo: 0),
      ],
      live: [])
    let drakar = stats["/w/drakar"]
    #expect(drakar?.sessionCount == 3)
    #expect(drakar?.lastActivity == now.addingTimeInterval(-3600))
    #expect(drakar?.newest?.path(percentEncoded: false).contains("apps-apple") == true)
  }

  @Test func aProjectWithNoSessionIsListedEmpty() {
    let stats = ProjectStats.compute(projects: ["/w/new/"], folders: [], live: [])
    #expect(stats["/w/new"] == ProjectStats())
  }

  @Test func theDeepestTrackedProjectTakesItsSessions() {
    let stats = ProjectStats.compute(
      projects: ["/w/drakar", "/w/drakar/apps/apple"],
      folders: [
        folder("/w/drakar", ids: ["a"], hoursAgo: 5),
        folder("/w/drakar/apps/apple/Drakar", ids: ["c"], hoursAgo: 1),
      ],
      live: [])
    #expect(stats["/w/drakar"]?.sessionCount == 1)
    #expect(stats["/w/drakar/apps/apple"]?.sessionCount == 1)
  }

  @Test func aWorktreesSessionsCountUnderItsRepository() {
    let stats = ProjectStats.compute(
      projects: ["/w/drakar"],
      folders: [folder("/w/drakar-feature", ids: ["w"], hoursAgo: 1, checkout: "/w/drakar")],
      live: [LiveSession(pid: 1, sessionID: "w", status: "busy", cwd: "/w/drakar-feature")],
      checkout: { $0 == "/w/drakar-feature" ? "/w/drakar" : $0 })
    #expect(stats["/w/drakar"]?.sessionCount == 1)
    #expect(stats["/w/drakar"]?.running == 1)
  }

  @Test func oneSessionUnderTwoAccountsIsOne() {
    let stats = ProjectStats.compute(
      projects: ["/w/drakar"],
      folders: [
        folder("/w/drakar", ids: ["a", "b"], hoursAgo: 5),
        folder("/w/drakar", ids: ["b"], hoursAgo: 1, account: other),
      ],
      live: [])
    #expect(stats["/w/drakar"]?.sessionCount == 2)
    #expect(stats["/w/drakar"]?.newestAccount == other)
  }

  @Test func countsRunningAndWaitingOnce() {
    let stats = ProjectStats.compute(
      projects: ["/w/drakar"], folders: [],
      live: [
        LiveSession(pid: 1, sessionID: "a", status: "busy", cwd: "/w/drakar"),
        LiveSession(pid: 1, sessionID: "a", status: "busy", cwd: "/w/drakar"),
        LiveSession(pid: 2, sessionID: "b", status: "waiting", cwd: "/w/drakar/apps"),
        LiveSession(
          pid: 3, sessionID: "c", status: "idle", cwd: "/w/drakar",
          updatedAt: now),
        LiveSession(pid: 4, sessionID: "d", status: "busy", cwd: "/w/other"),
      ])
    #expect(stats["/w/drakar"]?.running == 1)
    #expect(stats["/w/drakar"]?.waiting == 1)
    #expect(stats["/w/drakar"]?.lastActivity == now)
  }
}

@Suite("Folders suggested on home")
struct FolderSuggestionsTests {

  private let account = ClaudeAccount(directory: URL(filePath: "/a/.claude"), isDefault: true)
  private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

  private func folder(
    _ cwd: String, ids: Set<String> = ["x"], daysAgo: Double, repository: String? = nil
  ) -> TranscriptFolder {
    TranscriptFolder(
      account: account, folder: URL(filePath: "/a/.claude/projects/\(cwd.hashValue)"),
      sessionIDs: ids, newest: URL(filePath: "/a/.claude/projects/n.jsonl"),
      newestModified: now.addingTimeInterval(-daysAgo * 86400), cwd: cwd,
      repository: repository)
  }

  private func suggest(
    _ folders: [TranscriptFolder], tracked: [String] = [], hidden: [String: Date] = [:]
  ) -> [String] {
    FolderSuggestions.compute(
      folders: folders, tracked: tracked, hidden: hidden, now: now,
      temporary: ["/private/tmp"], excluded: ["/Users/me", "/"]
    ).map(\.path)
  }

  @Test func suggestsRecentUntrackedFoldersNewestFirst() {
    #expect(
      suggest([
        folder("/w/older", daysAgo: 3),
        folder("/w/newer", daysAgo: 1),
        folder("/w/stale", daysAgo: 40),
      ]) == ["/w/newer", "/w/older"])
  }

  @Test func aSubfolderIsSuggestedAsItsRepository() {
    let suggestions = FolderSuggestions.compute(
      folders: [
        folder("/w/foo/apps/apple", ids: ["a"], daysAgo: 1, repository: "/w/foo"),
        folder("/w/foo", ids: ["b"], daysAgo: 2, repository: "/w/foo"),
      ],
      tracked: [], hidden: [:], now: now, temporary: [], excluded: [])
    #expect(suggestions.map(\.path) == ["/w/foo"])
    #expect(suggestions.first?.sessionCount == 2)
  }

  @Test func leavesOutTrackedTemporaryAndHomeFolders() {
    #expect(
      suggest(
        [
          folder("/w/drakar/apps", daysAgo: 1),
          folder("/private/tmp/scratch", daysAgo: 1),
          folder("/Users/me", daysAgo: 1),
          folder("/w/other", daysAgo: 1),
        ], tracked: ["/w/drakar"]) == ["/w/other"])
  }

  @Test func aRepositoryHoldingATrackedProjectIsNotSuggested() {
    #expect(
      suggest(
        [folder("/w/drakar/apps/apple", daysAgo: 1, repository: "/w/drakar")],
        tracked: ["/w/drakar"]) == [])
  }

  @Test func aHiddenFolderReturnsWithANewerSession() {
    let hiddenAt = now.addingTimeInterval(-2 * 86400)
    #expect(suggest([folder("/w/a", daysAgo: 3)], hidden: ["/w/a": hiddenAt]) == [])
    #expect(suggest([folder("/w/a", daysAgo: 1)], hidden: ["/w/a": hiddenAt]) == ["/w/a"])
  }
}

@Suite("The tracked projects")
struct TrackedProjectsTests {

  @Test func tracksOncePerFolderAndRoundTrips() {
    var tracked = TrackedProjects()
    let first = tracked.track("/w/drakar/")
    let second = tracked.track("/w/drakar")
    #expect(first)
    #expect(!second)
    tracked.hide("/w/other", at: Date(timeIntervalSinceReferenceDate: 5))
    #expect(TrackedProjects.decode(tracked.encoded) == tracked)
    #expect(tracked.paths == ["/w/drakar"])
  }

  @Test func aBrokenValueIsAnEmptyList() {
    #expect(TrackedProjects.decode(Data("nope".utf8)) == TrackedProjects())
    #expect(TrackedProjects.decode(nil) == TrackedProjects())
  }

  @Test func trackingASuggestionUnhidesIt() {
    var tracked = TrackedProjects()
    tracked.hide("/w/a")
    tracked.track("/w/a")
    #expect(tracked.hidden.isEmpty)
  }

  @Test func ordersByActivityThenByWhenAdded() {
    var tracked = TrackedProjects()
    tracked.track("/w/quiet", at: Date(timeIntervalSinceReferenceDate: 50))
    tracked.track("/w/busy", at: Date(timeIntervalSinceReferenceDate: 10))
    tracked.track("/w/new", at: Date(timeIntervalSinceReferenceDate: 200))
    var busy = ProjectStats()
    busy.lastActivity = Date(timeIntervalSinceReferenceDate: 100)
    #expect(
      tracked.ordered(by: ["/w/busy": busy]).map(\.path) == ["/w/new", "/w/busy", "/w/quiet"])
  }
}

@Suite("Transcript folders on disk")
struct TranscriptFoldersTests {

  @Test func readsIdsNewestAndCwdAndReusesAnUnchangedFolder() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "acct-\(UUID())")
    let projects = root.appending(path: "projects/-w-drakar")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = projects.appending(path: "a.jsonl")
    let new = projects.appending(path: "b.jsonl")
    try #"{"type":"user","cwd":"/w/drakar"}"#.write(to: old, atomically: true, encoding: .utf8)
    try #"{"type":"user","cwd":"/w/drakar/apps"}"#.write(to: new, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: old.path)
    let account = ClaudeAccount(directory: root, isDefault: true)
    var located = 0
    let folders = SessionIndex.folders(accounts: [account]) { _ in
      located += 1
      return nil
    }
    #expect(folders.count == 1)
    #expect(folders.first?.sessionIDs == ["a", "b"])
    #expect(folders.first?.newest.lastPathComponent == "b.jsonl")
    #expect(folders.first?.cwd == "/w/drakar/apps")
    #expect(folders.first?.projectPath == "/w/drakar/apps")
    #expect(located == 1)
    _ = SessionIndex.folders(accounts: [account], previous: folders) { _ in
      located += 1
      return nil
    }
    #expect(located == 1)
  }
}
