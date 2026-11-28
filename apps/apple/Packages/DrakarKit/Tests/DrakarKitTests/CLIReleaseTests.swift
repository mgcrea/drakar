import DrakarKit
import Foundation
import Testing

@Suite("CLI versions and releases")
struct CLIReleaseTests {
  @Test func readsEachCLIsVersionLine() {
    #expect(CLIVersion(versionOutput: "2.1.332 (Claude Code)\n")?.description == "2.1.332")
    #expect(CLIVersion(versionOutput: "codex-cli 0.172.0\n")?.description == "0.172.0")
    #expect(CLIVersion(versionOutput: "1.5.19\n")?.description == "1.5.19")
    #expect(
      CLIVersion(versionOutput: "grok 1.0.92 (b06756fd6256) [stable]")?.description == "1.0.92")
    #expect(CLIVersion(versionOutput: "0.1.151-alpha.2")?.description == "0.1.151")
    #expect(CLIVersion(versionOutput: "build 652") == nil)
    #expect(CLIVersion(versionOutput: "") == nil)
  }

  @Test func comparesNumerically() throws {
    let v = { (text: String) in try #require(CLIVersion(text)) }
    #expect(try v("2.1.99") < v("2.1.100"))
    #expect(try v("2.1") == v("2.1.0"))
    #expect(try v("1.0.92") > v("1.0.9"))
    #expect(try !(v("0.172.0") < v("0.172.0")))
  }

  @Test func claudeChannelComesFromSettings() {
    #expect(CLIRelease.claudeChannel(settings: nil) == "latest")
    #expect(CLIRelease.claudeChannel(settings: Data(#"{"model":"opus"}"#.utf8)) == "latest")
    #expect(
      CLIRelease.claudeChannel(settings: Data(#"{"autoUpdatesChannel":"stable"}"#.utf8))
        == "stable")
    #expect(CLIRelease.claudeChannel(settings: Data("not json".utf8)) == "latest")
  }

  @Test func readsEachSource() {
    #expect(CLIRelease.claudeLatest(Data("2.1.326\n".utf8))?.description == "2.1.326")
    #expect(CLIRelease.claudeLatest(Data("<html>".utf8)) == nil)
    #expect(
      CLIRelease.codexLatest(Data(#"{"name":"@openai/codex","version":"0.173.0"}"#.utf8))?
        .description == "0.173.0")
    #expect(
      CLIRelease.agyLatest(
        Data("Antigravity CLI auto updater is running! Stable Version: 1.5.19. Rolled out".utf8))?
        .description == "1.5.19")
    #expect(CLIRelease.agyLatest(Data("<h1>Not Found</h1>".utf8)) == nil)
    let grok = """
      warning: something
      {"currentVersion":"1.0.92","latestVersion":"1.0.93","updateAvailable":true,"error":null}
      """
    #expect(CLIRelease.grokLatest(Data(grok.utf8))?.description == "1.0.93")
  }

  @Test func summarizesAnUpdateRun() {
    let ok = ProcessRunner.Output(
      status: 0, output: Data("Checking…\n\u{1B}[32mUpdated to 2.1.333\u{1B}[0m\n\n".utf8),
      errors: Data(), timedOut: false)
    #expect(CLIRelease.summary(of: ok) == "Updated to 2.1.333")
    let failed = ProcessRunner.Output(
      status: 1, output: Data("Checking…\n".utf8),
      errors: Data("Error: permission denied\n".utf8), timedOut: false)
    #expect(CLIRelease.summary(of: failed) == "Error: permission denied")
    let silent = ProcessRunner.Output(status: 0, output: Data(), errors: Data(), timedOut: false)
    #expect(CLIRelease.summary(of: silent) == nil)
  }
}
