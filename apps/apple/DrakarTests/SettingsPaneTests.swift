import DrakarKit
import Foundation
import SupportKit
import SupportKitSettings
import Testing

@testable import Drakar

/// A protocol cannot require an enum case, so the fleet convention — every app
/// ships an About pane, and the identifiers behind it never move — is pinned here
/// instead. The raw values are load-bearing: they are the stored pane, the
/// `settings.pane.*` accessibility identifiers and what a screenshot stage names.
@Suite("Settings panes")
struct SettingsPaneTests {

  @Test func shipsAnAboutPane() {
    #expect(SettingsPane.allCases.contains { $0.rawValue == "about" })
  }

  /// Add a pane here when it is added to the enum; never rename one that has shipped.
  @Test func keepsPaneIdentifiersStable() {
    #expect(
      SettingsPane.allCases.map(\.rawValue) == [
        "general", "transcript", "theme", "attention", "runner", "updates", "licence",
        "whatsNew", "about",
      ])
  }

  /// Nothing is sold yet, so every pane sits in the one ungrouped configuration
  /// list. This fails the day a Pro pane lands without a group, which is the point.
  @Test func drawsOneUngroupedList() {
    #expect(SettingsPane.allCases.allSatisfy { $0.group == .configuration })
  }

  /// The slug is the prefix of every defaults key and the tail of every support URL,
  /// so it is not free to drift from the repo's name. `@MainActor` because `Support`
  /// takes the app target's default isolation; without it this does not compile.
  @Test @MainActor func theSupportIdentityIsThisApps() {
    #expect(Support.app.slug == "drakar")
    #expect(Support.app.siteURL.host() == "drakar.mgcrea.io")
  }

  /// The default account is run with `CLAUDE_CONFIG_DIR` unset, because the CLI keys its
  /// keychain item by the variable: picking `~/.claude` must not name it.
  @Test @MainActor func picksTheDefaultAccountByLeavingTheVariableUnset() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    let standard = ClaudeChoice.account(at: home + ".claude")
    #expect(standard.isDefault)
    #expect(ClaudeChoice.account(at: home + ".claude/").isDefault)
    #expect(standard.environment(["CLAUDE_CONFIG_DIR": "/elsewhere"])["CLAUDE_CONFIG_DIR"] == nil)

    let other = ClaudeChoice.account(at: home + ".claude-work")
    #expect(!other.isDefault)
    #expect(other.name == "work")
    #expect(other.environment([:])["CLAUDE_CONFIG_DIR"] == home + ".claude-work")
  }
}

/// Settings › Runner (remote sessions spec §2, §3), its model over a defaults suite of each
/// test's own, never the person's: no test reaches their settings, their runner or their ssh.
/// A test that puts a host in `SessionHost.runner` puts back the one it found.
@MainActor
@Suite("Settings › Runner", .serialized, .timeLimit(.minutes(1)))
struct RunnerPaneTests {
  private let suite = "drakar-tests-\(UUID().uuidString)"
  private let defaults: UserDefaults
  private let root = URL(
    fileURLWithPath: "/tmp/dr-\(UUID().uuidString.prefix(6))", isDirectory: true)

  init() throws {
    defaults = try #require(UserDefaults(suiteName: suite))
  }

  private func finish() {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }

  /// An opt-in of this test's own, on a host no test reaches (no `testDirectory`).
  private func role() -> RunnerRole {
    RunnerRole(defaults: defaults, directory: root, host: SessionHost())
  }

  private func eventually(within limit: Duration = .seconds(5), _ condition: () -> Bool) async
    -> Bool
  {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
  }

  private func facts(from source: EnvironmentSource) -> RunnerFacts {
    RunnerFacts(
      drakar: "1.36.0", build: "136", hostMajors: [HostWire.major], home: "/Users/runner",
      user: "runner", hostname: "studio", environment: [:], environmentFrom: source,
      claude: [ClaudeCandidate(path: "/Users/runner/.local/bin/claude", version: "2.1.0")],
      accounts: ["/Users/runner/.claude"])
  }

  @Test func theRunnerPaneIsListed() throws {
    let panes = SettingsPane.allCases
    let runner = try #require(panes.firstIndex(of: .runner))
    let attention = try #require(panes.firstIndex(of: .attention))
    #expect(runner == attention + 1)
    #expect(SettingsPane.runner.title == "Runner")
    #expect(!SettingsPane.runner.systemImage.isEmpty)
  }

  /// Saving no destination removes the runner, and its host with it.
  @Test func anEmptyDestinationMeansNoRunner() {
    let before = SessionHost.runner
    defer {
      SessionHost.runner = before
      finish()
    }
    RunnerSettings.write(RunnerSettings(name: "Studio", destination: "studio.local"), to: defaults)
    let old = SessionHost(endpoint: .runner(RunnerSettings(name: "", destination: "studio.local")))
    SessionHost.runner = old
    let model = RunnerPaneModel(defaults: defaults, role: role())
    #expect(model.destination == "studio.local")
    model.destination = "  "
    #expect(model.canSave)
    model.save()
    #expect(RunnerSettings.read(from: defaults) == nil)
    #expect(SessionHost.runner == nil)
    #expect(old.isClosed)
    #expect(!model.canSave)
  }

  /// Saving replaces the runner's host, and lets the old one go; the same runner again keeps it.
  @Test func savingARunnerMakesItsHost() throws {
    let before = SessionHost.runner
    defer {
      SessionHost.runner = before
      finish()
    }
    let model = RunnerPaneModel(defaults: defaults, role: role())
    #expect(model.drakarPath == "/Applications/Drakar.app")
    #expect(!model.canSave)
    model.name = "Studio"
    model.destination = " me@studio.local "
    model.save()
    let saved = RunnerSettings(name: "Studio", destination: "me@studio.local")
    #expect(RunnerSettings.read(from: defaults) == saved)
    let host = try #require(SessionHost.runner)
    #expect(host.isRunner)
    #expect(host.endpoint == .runner(saved))

    model.save()
    #expect(SessionHost.runner === host)
    model.drakarPath = "~/Applications/Drakar.app"
    model.save()
    #expect(SessionHost.runner !== host)
    #expect(SessionHost.runner?.isRunner == true)
    #expect(host.isClosed)
    #expect(RunnerSettings.read(from: defaults)?.drakarPath == "~/Applications/Drakar.app")
  }

  /// Test reaches the runner as typed, unsaved: it shows the facts, names the runner after its
  /// hostname when no name was typed, and closes the connection and its ssh. The runner's
  /// host is not touched.
  @Test func testingShowsTheFactsAndLetsGo() async throws {
    var links: [(client: HostClient, peer: Int32, ssh: Process)] = []
    defer {
      for link in links {
        close(link.peer)
        if link.ssh.isRunning { link.ssh.terminate() }
      }
      finish()
    }
    let stated = facts(from: .ssh)
    var opened: [RunnerSettings] = []
    var installed = 0
    // A connection over a socket pair, carried by an ssh that would outlast the test.
    let model = RunnerPaneModel(
      defaults: defaults, role: role(), install: { _ in installed += 1 },
      open: { settings throws(RunnerFailure) in
        opened.append(settings)
        var ends: [Int32] = [0, 0]
        let ssh = Process()
        ssh.executableURL = URL(filePath: "/bin/sleep")
        ssh.arguments = ["30"]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0, (try? ssh.run()) != nil else {
          throw RunnerFailure(message: "no fake runner", stderr: "")
        }
        let client = HostClient.connect(fd: ends[0])
        links.append((client, ends[1], ssh))
        return (client, stated, ssh)
      })
    model.destination = "studio.local"
    await model.test()
    #expect(opened == [RunnerSettings(name: "", destination: "studio.local")])
    #expect(model.check == .passed(stated))
    #expect(model.name == "studio")
    let first = try #require(links.first)
    #expect(await eventually { first.client.isClosed })
    #expect(await eventually { !first.ssh.isRunning })
    #expect(installed == 0)
    #expect(RunnerSettings.read(from: defaults) == nil)

    // Facts of another destination are not shown for this one, and a name typed is kept.
    model.name = "Studio"
    model.destination = "other.local"
    #expect(model.check == .idle)
    await model.test()
    #expect(model.check == .passed(stated))
    #expect(model.name == "Studio")
    #expect(links.count == 2)
    #expect(await eventually { links.allSatisfy { $0.client.isClosed } })
  }

  @Test func aFailedTestSaysWhy() async {
    defer { finish() }
    let failure = RunnerFailure(
      message: "ssh to studio.local ended before Drakar answered there.",
      stderr: "Permission denied (publickey).")
    let model = RunnerPaneModel(
      defaults: defaults, role: role(), install: { _ in },
      open: { _ throws(RunnerFailure) in throw failure })
    model.destination = "studio.local"
    await model.test()
    #expect(model.check == .failed(failure))
    #expect(model.name.isEmpty)
  }

  /// Every change of the opt-in is applied: on, the runner's environment is written.
  @Test func theOptInIsAppliedOnEveryChange() async throws {
    let role = role()
    defer {
      role.accepts = false
      role.apply()
      finish()
    }
    let model = RunnerPaneModel(defaults: defaults, role: role)
    #expect(!model.accepts)
    let file = RunnerEnvironment.file(in: root).path(percentEncoded: false)
    model.accepts = true
    #expect(defaults.bool(forKey: RunnerRole.acceptsKey))
    #expect(await eventually(within: .seconds(15)) { FileManager.default.fileExists(atPath: file) })
    try FileManager.default.removeItem(atPath: file)
    model.accepts = false
    #expect(!defaults.bool(forKey: RunnerRole.acceptsKey))
    model.accepts = true
    #expect(await eventually(within: .seconds(15)) { FileManager.default.fileExists(atPath: file) })
  }
}
