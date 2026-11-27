import DrakarKit
import Foundation
import Observation

/// The models each account offers, as the newest `initialize` reply listed them: a
/// session's, or the capability probe's. In memory; no list is written into Drakar.
@Observable
final class ModelCatalog {
  static let shared = ModelCatalog()

  private var lists: [String: [ModelOption]] = [:]

  /// Codex's models, from the newest `model/list`: one list until Codex accounts (slice 4).
  private(set) var codexModels: [ModelOption]?
  @ObservationIgnored private var isLoadingCodex = false

  /// Antigravity's models, from the newest `session/new` or `config_option_update`.
  private(set) var agyModels: [ModelOption]?
  @ObservationIgnored private var isLoadingAgy = false

  /// Grok's models, from `grok models` or the newest `session/new`.
  private(set) var grokModels: [ModelOption]?
  @ObservationIgnored private var isLoadingGrok = false

  func recordCodex(_ models: [ModelOption]) { codexModels = models }

  func recordAgy(_ models: [ModelOption]) { agyModels = models }

  func recordGrok(_ models: [ModelOption]) { grokModels = models }

  /// Asks a short-lived `agy acp` for its models, once, when no list is known yet:
  /// the pill lists them before an Antigravity session's first prompt.
  func loadAgy() {
    guard agyModels == nil, !isLoadingAgy else { return }
    isLoadingAgy = true
    Task {
      defer { isLoadingAgy = false }
      let environment = await AgentSession.environment.value
      guard let executable = AgyLaunch.locate(path: environment["PATH"]) else { return }
      let folder = FileManager.default.homeDirectoryForCurrentUser
      let configuration = AgyLaunch.configuration(
        executable: executable, environment: environment, folder: folder)
      if let snapshot = try? await AgyProbe.read(folder: folder, configuration: configuration),
        !snapshot.models.isEmpty
      {
        recordAgy(snapshot.models)
      }
    }
  }

  /// Asks `grok models` for its available models, once, when no list is known yet:
  /// Settings and the pill list them before a Grok session starts.
  func loadGrok() {
    guard grokModels == nil, !isLoadingGrok else { return }
    isLoadingGrok = true
    Task {
      defer { isLoadingGrok = false }
      let environment = await AgentSession.environment.value
      guard let executable = AgyLaunch.locate(path: environment["PATH"], binary: "grok") else {
        return
      }
      let home = FileManager.default.homeDirectoryForCurrentUser
      guard
        let result = try? await ProcessRunner.run(
          executable, ["models"], environment: environment, readsErrors: false,
          currentDirectory: home, timeout: .seconds(10)),
        !result.timedOut, result.status == 0
      else { return }
      let models = GrokModels.list(fromOutput: String(decoding: result.output, as: UTF8.self))
      if !models.isEmpty, grokModels == nil { recordGrok(models) }
    }
  }

  /// Asks a short-lived `codex app-server` for its models, once, when no list is known yet:
  /// the pill lists them before a Codex session's first prompt.
  func loadCodex() {
    guard codexModels == nil, !isLoadingCodex else { return }
    isLoadingCodex = true
    Task {
      defer { isLoadingCodex = false }
      let environment = await AgentSession.environment.value
      guard let executable = CodexLaunch.locate(path: environment["PATH"]) else { return }
      let configuration = CodexLaunch.configuration(
        executable: executable, environment: environment,
        folder: FileManager.default.homeDirectoryForCurrentUser)
      let results = try? await CodexOneShot(configuration: configuration).run { previous in
        previous == nil ? ("model/list", .object([:])) : nil
      }
      if let list = results?.first { recordCodex(CodexModels.list(list)) }
    }
  }

  func models(for account: ClaudeAccount) -> [ModelOption]? { lists[account.key] }

  func record(_ models: [ModelOption], for account: ClaudeAccount) {
    lists[account.key] = models
  }

  /// Asks the probe for `folder` under `account` when no list is known for the account yet.
  func load(folder: URL, account: ClaudeAccount) {
    guard lists[account.key] == nil else { return }
    CapabilityStore.shared.capabilities(for: folder, account: account).loadIfNeeded()
  }
}
