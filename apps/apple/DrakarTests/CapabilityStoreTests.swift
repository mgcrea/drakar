import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("A project's skills and servers, kept for the launch")
struct CapabilityStoreTests {

  final class Calls { var count = 0 }

  private let folder = FileManager.default.temporaryDirectory.appending(
    path: "drakar-store-\(UUID().uuidString)", directoryHint: .isDirectory)

  private func outcome(_ skills: [String], _ servers: [MCPServerEntry] = []) -> ProbeOutcome {
    ProbeOutcome(
      capabilities: ProjectCapabilities(
        skills: skills.map { SkillEntry(name: $0) }, mcpServers: servers))
  }

  private func settle(_ entry: Capabilities) async throws {
    for _ in 0..<100 where entry.isLoading {
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  /// Three refreshes asked while one probe runs make one more probe, not three.
  @Test func refreshesAskedDuringAProbeRunOnceAfterIt() async throws {
    let entry = Capabilities(folder: folder, accountKey: "a")
    let calls = Calls()
    entry.probe = { _ in
      calls.count += 1
      try? await Task.sleep(for: .milliseconds(100))
      return self.outcome(["s\(calls.count)"])
    }
    entry.refresh()
    entry.refresh()
    entry.refresh()
    entry.refresh()
    try await settle(entry)
    #expect(calls.count == 2)
    #expect(entry.lists.skills?.map(\.name) == ["s2"])
    #expect(entry.hasLoaded)
  }

  @Test func loadsOnlyOnceIfNeeded() async throws {
    let entry = Capabilities(folder: folder, accountKey: "a")
    let calls = Calls()
    entry.probe = { _ in
      calls.count += 1
      return self.outcome(["s"])
    }
    entry.loadIfNeeded()
    try await settle(entry)
    entry.loadIfNeeded()
    try await settle(entry)
    #expect(calls.count == 1)
  }

  /// A reload that fails keeps the lists shown, and says why beside them.
  @Test func aFailedReloadKeepsTheLastLists() async throws {
    let entry = Capabilities(folder: folder, accountKey: "a")
    entry.probe = { _ in self.outcome(["kept"]) }
    entry.refresh()
    try await settle(entry)
    entry.probe = { _ in .failed("Claude Code exited with status 1.") }
    entry.refresh()
    try await settle(entry)
    #expect(entry.lists.skills?.map(\.name) == ["kept"])
    #expect(entry.skillsProblem == "Claude Code exited with status 1.")
  }

  @Test func theFirstListsMarkNothingAndANewSkillDoes() async throws {
    let entry = Capabilities(folder: folder, accountKey: "a")
    var seen: [CapabilityChanges] = []
    _ = entry.observe { seen.append($0) }
    entry.probe = { _ in self.outcome(["a"]) }
    entry.refresh()
    try await settle(entry)
    #expect(seen.isEmpty)
    entry.probe = { _ in self.outcome(["a", "b"]) }
    entry.refresh()
    try await settle(entry)
    #expect(seen == [CapabilityChanges(addedSkills: ["b"])])
  }

  /// A session's `initialize` knows skills, not servers.
  @Test func aSessionsSkillsReplaceOnlyTheSkills() async throws {
    let entry = Capabilities(folder: folder, accountKey: "a")
    let server = MCPServerEntry(name: "armada", status: .connected)
    entry.probe = { _ in self.outcome(["old"], [server]) }
    entry.refresh()
    try await settle(entry)
    entry.sessionReported(skills: [SkillEntry(name: "new")])
    #expect(entry.lists.skills?.map(\.name) == ["new"])
    #expect(entry.lists.mcpServers == [server])
  }

  /// A file change refreshes only lists something asked for: never one nobody loaded.
  @Test func refreshIfLoadedLeavesAnUnloadedEntryAlone() async throws {
    let entry = Capabilities(folder: folder, accountKey: "a")
    let calls = Calls()
    entry.probe = { _ in
      calls.count += 1
      return self.outcome(["s"])
    }
    entry.refreshIfLoaded()
    try await settle(entry)
    #expect(calls.count == 0)
  }

  @Test func cancellingStopsTheProbe() async throws {
    let entry = Capabilities(folder: folder, accountKey: "a")
    entry.probe = { _ in
      try? await Task.sleep(for: .seconds(5))
      return self.outcome(["late"])
    }
    entry.refresh()
    #expect(entry.isLoading)
    entry.cancel()
    #expect(!entry.isLoading)
    try await Task.sleep(for: .milliseconds(100))
    #expect(entry.lists.skills == nil)
  }

  @Test func oneEntryPerFolderAndAccount() {
    let store = CapabilityStore()
    let a = ClaudeAccount(directory: URL(filePath: "/tmp/.claude-a"), isDefault: false)
    let b = ClaudeAccount(directory: URL(filePath: "/tmp/.claude-b"), isDefault: false)
    let first = store.capabilities(for: folder, account: a)
    #expect(store.capabilities(for: folder.appending(path: ""), account: a) === first)
    #expect(store.capabilities(for: folder, account: b) !== first)
  }
}
