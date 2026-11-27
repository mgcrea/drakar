import DrakarKit
import Foundation
import Testing

@testable import Drakar

@Suite("Probing Grok Build allowance via ACP extension")
struct GrokLimitsProbeTests {

  private func writeFakeGrok(in root: URL, body: String) throws -> URL {
    let script = root.appending(path: "fake-grok")
    let contents = """
      #!/bin/sh
      \(body)
      """
    try Data(contents.utf8).write(to: script)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
    return script
  }

  @Test func resolvesGrokHomeFromEnvironmentOrDefault() {
    let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
    #expect(
      GrokLimitsProbe.resolveHome(environment: [:], home: home)
        == URL(filePath: "/Users/me/.grok", directoryHint: .isDirectory))
    #expect(
      GrokLimitsProbe.resolveHome(environment: ["GROK_HOME": "  "], home: home)
        == URL(filePath: "/Users/me/.grok", directoryHint: .isDirectory))
    #expect(
      GrokLimitsProbe.resolveHome(environment: ["GROK_HOME": "/tmp/grok-work"], home: home)
        == URL(filePath: "/tmp/grok-work", directoryHint: .isDirectory))
  }

  @Test func recognizesGrokBuildHomesAndIgnoresCommunityCLI() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-grok-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // Community superagent-ai/grok-cli only creates user-settings.json, with no sessions/.
    try Data("{}".utf8).write(to: root.appending(path: "user-settings.json"))
    #expect(!GrokLimitsProbe.isHomePresent(at: root))

    try FileManager.default.createDirectory(
      at: root.appending(path: "sessions"), withIntermediateDirectories: true)
    #expect(!GrokLimitsProbe.isHomePresent(at: root))

    try Data("{}".utf8).write(to: root.appending(path: "version.json"))
    #expect(GrokLimitsProbe.isHomePresent(at: root))
  }

  @Test func readsBillingUsageAndStopsChild() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-grok-probe-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let billing = #"""
      {"config":{"creditUsagePercent":27.6,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2099-01-01T00:00:00Z"}},"subscription_tier":"X Premium"}
      """#
    let fake = try writeFakeGrok(
      in: root,
      body: """
        [ "$1" = "agent" ] && [ "$2" = "stdio" ] || exit 1
        read -r init_line
        echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        read -r billing_line
        case "$billing_line" in *_x.ai/billing*) ;; *) exit 1 ;; esac
        printf '{"jsonrpc":"2.0","id":2,"result":%s}\n' '\(billing)'
        sleep 30
        """)

    let result = await GrokLimitsProbe.limits(
      executable: fake, directory: root, timeout: .seconds(5))
    let usage = try #require(result)
    #expect(usage.plan == "X Premium")
    #expect(usage.period == .weekly)
    #expect(usage.shortLabel == "7d")
    #expect(usage.window.percent == 28)
    #expect(usage.window.resetsAt == AccountUsage.parseISO8601("2099-01-01T00:00:00Z"))
  }

  @Test func returnsNilOnErrorOrEarlyExit() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-grok-probe-err-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let failing = try writeFakeGrok(
      in: root,
      body: """
        read -r init_line
        echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        read -r billing_line
        echo '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"not signed in"}}'
        """)
    #expect(
      await GrokLimitsProbe.limits(executable: failing, directory: root, timeout: .seconds(5))
        == nil)
  }
}
