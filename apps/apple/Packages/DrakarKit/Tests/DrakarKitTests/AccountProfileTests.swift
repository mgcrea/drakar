import DrakarKit
import Foundation
import Testing

@Suite("An account's name and plan")
struct AccountProfileTests {

  private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

  /// The personal account as it is on disk: the organization Claude generates from the email.
  @Test func aGeneratedOrganizationIsPersonal() throws {
    let profile = AccountProfile(
      json: try json(
        #"{"oauthAccount":{"emailAddress":"me@example.com","organizationName":"me@example.com's Organization","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x","userRateLimitTier":null},"cachedUsageUtilization":{"fetchedAtMs":1,"utilization":{"five_hour":{"utilization":37,"resets_at":"2026-10-04T10:29:59.633102+00:00"}}}}"#
      ), fallbackName: "default")
    #expect(profile.name == "Personal")
    #expect(profile.plan == "Max 20x")
    #expect(profile.cachedUsage?.fiveHour?.percent == 37)
  }

  /// A team account's tier names nothing Drakar knows; its type does.
  @Test func aTeamKeepsItsName() throws {
    let profile = AccountProfile(
      json: try json(
        #"{"oauthAccount":{"emailAddress":"me@example.com","organizationName":"Skitrust","organizationType":"claude_team","organizationRateLimitTier":"default_raven"}}"#
      ), fallbackName: "skitrust")
    #expect(profile.name == "Skitrust")
    #expect(profile.plan == "Team")
    #expect(profile.cachedUsage == nil)
  }

  @Test func noFileFallsBackToTheDirectoryName() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: ".claude-nowhere-\(UUID().uuidString)", directoryHint: .isDirectory)
    let account = ClaudeAccount(directory: directory, isDefault: false)
    let profile = AccountProfile(reading: account)
    #expect(profile.name == account.name)
    #expect(profile.plan == nil)
    #expect(profile.cachedUsage == nil)
  }

  @Test func readsTheFileInsideAnOtherAccount() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: ".claude-t\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"oauthAccount":{"organizationName":"Acme","organizationType":"claude_pro"}}"#.utf8)
      .write(to: directory.appending(path: ".claude.json"))
    let profile = AccountProfile(reading: ClaudeAccount(directory: directory, isDefault: false))
    #expect(profile.name == "Acme")
    #expect(profile.plan == "Pro")
  }

  @Test(
    arguments: [
      ("default_claude_max_20x", nil, "Max 20x"),
      ("default_claude_max_5x", nil, "Max 5x"),
      ("default_claude_pro", nil, "Pro"),
      ("default_raven", "claude_team", "Team"),
      (nil, "claude_max", "Max"),
      (nil, "claude_enterprise", "Enterprise"),
      ("something_new", "something_else", nil),
    ] as [(String?, String?, String?)])
  func namesThePlan(_ tier: String?, _ type: String?, _ plan: String?) throws {
    var oauth: [String: JSONValue] = ["organizationName": .string("Acme")]
    if let tier { oauth["organizationRateLimitTier"] = .string(tier) }
    if let type { oauth["organizationType"] = .string(type) }
    let profile = AccountProfile(
      json: .object(["oauthAccount": .object(oauth)]), fallbackName: "x")
    #expect(profile.plan == plan)
  }

  /// The default account's file sits beside its folder, every other one's inside it.
  @Test func findsTheConfigFile() {
    let home = URL(filePath: "/Users/me/", directoryHint: .isDirectory)
    let standard = ClaudeAccount(
      directory: home.appending(path: ".claude", directoryHint: .isDirectory), isDefault: true)
    let other = ClaudeAccount(
      directory: home.appending(path: ".claude-work", directoryHint: .isDirectory),
      isDefault: false)
    #expect(standard.configFile.path(percentEncoded: false) == "/Users/me/.claude.json")
    #expect(other.configFile.path(percentEncoded: false) == "/Users/me/.claude-work/.claude.json")
  }
}

@Suite("One account, two spellings")
struct ClaudeAccountKeyTests {
  /// A `ResumeTarget` stores the path without its slash; discovery builds it with one.
  @Test func theTrailingSlashDoesNotMakeAnotherAccount() {
    let a = ClaudeAccount(directory: URL(filePath: "/Users/me/.claude-work"), isDefault: false)
    let b = ClaudeAccount(
      directory: URL(filePath: "/Users/me/.claude-work/", directoryHint: .isDirectory),
      isDefault: false)
    #expect(a.key == b.key)
    #expect(a.key == "/Users/me/.claude-work")
  }

  /// `claude auth status` under `CLAUDE_CONFIG_DIR=~/.claude-x/` reports signed out, and
  /// under `~/.claude-x` signed in (Claude Code 2.1.288): the slash is not cosmetic.
  @Test func namesTheDirectoryToTheCLIWithoutItsTrailingSlash() {
    let account = ClaudeAccount(
      directory: URL(filePath: "/Users/me/.claude-work/", directoryHint: .isDirectory),
      isDefault: false)
    #expect(account.environment([:])["CLAUDE_CONFIG_DIR"] == "/Users/me/.claude-work")
  }
}
