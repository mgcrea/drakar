import DrakarKit
import Foundation
import Testing

@testable import Drakar

@Suite("Probing Antigravity quotas via PTY statusLine")
struct AgyLimitsProbeTests {

  private func writeFakeAgy(in root: URL, body: String) throws -> URL {
    let script = root.appending(path: "fake-agy")
    let contents = """
      #!/bin/sh
      SETTINGS=""
      while [ $# -gt 0 ]; do
        if [ "$1" = "--settings" ]; then
          shift
          SETTINGS="$1"
        fi
        shift
      done
      CMD=$(/usr/bin/python3 -c 'import json,sys; print(json.loads(sys.argv[1])["statusLine"]["command"])' "$SETTINGS")
      \(body)
      """
    try Data(contents.utf8).write(to: script)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
    return script
  }

  @Test func readsQuotaAndPlanTierFromStatusLineAndStopsChild() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-agy-probe-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let payload = #"""
      {"plan_tier":"Google AI Pro","quota":{"gemini-5h":{"remaining_fraction":0.65,"reset_time":"2099-01-01T15:00:00Z","reset_in_seconds":3600},"3p-weekly":{"remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z","reset_in_seconds":0}}}
      """#
    let fake = try writeFakeAgy(
      in: root,
      body: """
        printf '%s' '\(payload)' | "$CMD"
        sleep 30
        """)

    let result = await AgyLimitsProbe.limits(
      executable: fake, timeout: .seconds(5), tierGrace: .milliseconds(400),
      killGrace: .milliseconds(300))
    let usage = try #require(result)
    #expect(usage.plan == "Google AI Pro")
    #expect(usage.buckets.map(\.id) == ["gemini-5h", "3p-weekly"])
    #expect(usage.buckets[0].window.percent == 35)
    #expect(usage.buckets[1].window.percent == 0)
    #expect(usage.buckets[1].window.resetsAt == nil)
  }

  @Test func waitsBrieflyForPlanTierAfterQuotaArrives() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-agy-probe-tier-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = #"{"quota":{"gemini-5h":{"remaining_fraction":0.8,"reset_in_seconds":300}}}"#
    let second =
      #"{"plan_tier":"Google AI Ultra","quota":{"gemini-5h":{"remaining_fraction":0.8,"reset_in_seconds":300}}}"#
    let fake = try writeFakeAgy(
      in: root,
      body: """
        printf '%s' '\(first)' | "$CMD"
        sleep 0.25
        printf '%s' '\(second)' | "$CMD"
        sleep 30
        """)

    let result = await AgyLimitsProbe.limits(
      executable: fake, timeout: .seconds(5), tierGrace: .seconds(1),
      killGrace: .milliseconds(300))
    let usage = try #require(result)
    #expect(usage.plan == "Google AI Ultra")
    #expect(usage.buckets.first?.window.percent == 20)
  }

  @Test func returnsQuotaWithoutPlanTierAfterGracePeriod() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-agy-probe-notier-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let payload = #"{"quota":{"gemini-5h":{"remaining_fraction":0.5,"reset_in_seconds":300}}}"#
    let fake = try writeFakeAgy(
      in: root,
      body: """
        printf '%s' '\(payload)' | "$CMD"
        sleep 30
        """)

    let result = await AgyLimitsProbe.limits(
      executable: fake, timeout: .seconds(5), tierGrace: .milliseconds(250),
      killGrace: .milliseconds(300))
    let usage = try #require(result)
    #expect(usage.plan == nil)
    #expect(usage.buckets.first?.window.percent == 50)
  }

  @Test func returnsNilWhenChildExitsWithNoPayload() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-agy-probe-empty-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let fake = try writeFakeAgy(in: root, body: "exit 0")
    let result = await AgyLimitsProbe.limits(
      executable: fake, timeout: .seconds(2), tierGrace: .milliseconds(200),
      killGrace: .milliseconds(200))
    #expect(result == nil)
  }
}
