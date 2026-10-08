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

  func recordCodex(_ models: [ModelOption]) { codexModels = models }

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
