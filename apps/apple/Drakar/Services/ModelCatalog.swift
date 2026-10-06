import DrakarKit
import Foundation
import Observation

/// The models each account offers, as the newest `initialize` reply listed them: a
/// session's, or the capability probe's. In memory; no list is written into Drakar.
@Observable
final class ModelCatalog {
  static let shared = ModelCatalog()

  private var lists: [String: [ModelOption]] = [:]

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
