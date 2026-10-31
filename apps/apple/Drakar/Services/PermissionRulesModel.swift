import DrakarKit
import Foundation
import Observation

/// What the Permissions tab shows: the selected session's permission rules, from its own
/// process when Drakar drives one, else from a rules probe, and the rules it adds and
/// removes through `claude edit-permission-rules`. The command writes a settings file, which
/// a running process reads on its own time, so after an edit the listing is read again until
/// it shows the change.
@MainActor @Observable
final class PermissionRulesModel {
  /// Where one session's listing comes from and where its edits go. Stands in for the
  /// session in tests.
  struct Source {
    /// The session's id: showing the same one again reads nothing.
    var key: AnyHashable
    var isCodex: Bool
    /// `list` asks the session's own process, which has its session approvals too, and
    /// reads an edited settings file a moment after it is written.
    var isLive: Bool
    /// Nil when nothing answered.
    var list: () async -> PermissionRulesAnswer?
    var edit: (PermissionRuleEdit) async -> PermissionRuleEditOutcome
  }

  enum Listing: Equatable {
    case idle, loading, codex
    case listed(PermissionRulesState, live: Bool)
    /// The CLI's refusal, or why there was no reply.
    case failed(String)
  }

  static let noAnswer = String(localized: "Claude Code didn't answer.")
  static let notListedYet = String(localized: "Saved; not in the list yet.")

  private(set) var listing: Listing = .idle
  /// Rules a remove was sent for, until a listing no longer has them or the rereads give up.
  private(set) var removing: Set<PermissionRule> = []
  /// What the last edit has to say under the list: its warnings, that it does not show yet,
  /// or a remove's refusal. An add's refusal goes back to its sheet instead.
  private(set) var note: String?

  /// How many times, and how far apart, a live listing is read again after an edit.
  @ObservationIgnored var rereadAttempts = 14
  @ObservationIgnored var rereadInterval: Duration = .milliseconds(300)
  /// The read `show` or `refresh` started; tests wait on it.
  @ObservationIgnored private(set) var reading: Task<Void, Never>?
  @ObservationIgnored private var source: Source?
  /// Bumped by each read: an answer for an older one, another session's or one a later read
  /// overtook, is dropped.
  @ObservationIgnored private var generation = 0

  /// The listing for `item`: its process when Drakar drives one (`hasLiveRules`, read now),
  /// else a probe in its folder under its account. Edits go through the command either way.
  static func source(for item: ProjectSession) -> Source {
    let session = item.session
    let isLive = session.hasLiveRules
    return Source(
      key: item.id, isCodex: session.agent == .codex, isLive: isLive,
      list: {
        if isLive { return await session.listPermissionRules() }
        return await PermissionRulesProbe.run(
          folder: session.folder, account: session.effectiveAccount,
          executableOverride: session.executableOverride)
      },
      edit: {
        await PermissionRuleEditor.apply(
          $0, folder: session.folder, account: session.effectiveAccount,
          executableOverride: session.executableOverride)
      })
  }

  /// Reads `source`'s listing, unless it is the session already shown. That one's source is
  /// still taken, for the next refresh or edit: its process may have started or gone.
  func show(_ source: Source) {
    let isShown = isShowing(source)
    self.source = source
    guard !isShown else { return }
    removing = []
    note = nil
    listing = .idle
    read()
  }

  /// Reads the shown session's listing again, keeping the rules on screen meanwhile.
  func refresh() {
    read()
  }

  /// Adds each non-blank line of `text`, trimmed, as a rule. Nil once saved, or with nothing
  /// to add; else the CLI's refusal, for the sheet to show.
  func add(_ text: String, behavior: PermissionBehavior, file: PermissionRuleFile) async
    -> String?
  {
    let rules = text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard let source, !rules.isEmpty else { return nil }
    note = nil
    let before: [PermissionRule]? =
      if case .listed(let state, _) = listing { state.rules } else { nil }
    switch await source.edit(.add(rules: rules, behavior: behavior, file: file)) {
    case .refused(let reason):
      return reason
    case .saved(let warnings, let stored):
      guard isShowing(source) else { return nil }
      note = Self.note(warnings)
      // The rules as the file holds them, which can differ from what was typed; a reply
      // without them says nothing to look for, so any change to the list is the add.
      let shows = await reread(source) { state in
        stored.isEmpty
          ? state.rules != before
          : stored.allSatisfy { text in
            state.rules.contains {
              $0.rule == text && $0.behavior == behavior && $0.source == file.rawValue
            }
          }
      }
      if shows == false { note = Self.note(warnings + [Self.notListedYet]) }
      return nil
    }
  }

  /// Takes `rule` out of its settings file, verbatim as listed. Nothing goes for a rule the
  /// command cannot edit, nor while a remove of it waits.
  func remove(_ rule: PermissionRule) async {
    guard let source, rule.isRemovable, let file = PermissionRuleFile(rawValue: rule.source),
      !removing.contains(rule)
    else { return }
    removing.insert(rule)
    note = nil
    let outcome = await source.edit(.remove(rule: rule.rule, behavior: rule.behavior, file: file))
    // Another session shown meanwhile cleared `removing` and the note: this one's are gone.
    guard isShowing(source) else { return }
    switch outcome {
    case .refused(let reason):
      note = reason
    case .saved(let warnings, _):
      note = Self.note(warnings)
      let gone = await reread(source) { state in
        !state.rules.contains {
          $0.rule == rule.rule && $0.behavior == rule.behavior && $0.source == rule.source
        }
      }
      guard let gone else { return }
      if !gone { note = Self.note(warnings + [Self.notListedYet]) }
    }
    removing.remove(rule)
  }

  private func isShowing(_ source: Source) -> Bool {
    self.source?.key == source.key
  }

  /// A read of the shown session in the background. A failed or empty listing shows as
  /// loading until it answers; a listed one stays on screen.
  private func read() {
    guard let source else { return }
    guard !source.isCodex else {
      generation += 1
      listing = .codex
      return
    }
    if case .listed = listing {} else { listing = .loading }
    reading = Task { _ = await list(source) }
  }

  /// Reads `source`'s listing and shows it, unless another read started meanwhile. The
  /// state shown, nil for a failure or an answer dropped.
  private func list(_ source: Source) async -> PermissionRulesState? {
    generation += 1
    let current = generation
    let answer = await source.list()
    guard current == generation else { return nil }
    switch answer {
    case .listed(let state)?:
      listing = .listed(state, live: source.isLive)
      return state
    case .refused(let reason)?:
      listing = .failed(reason)
    case nil:
      listing = .failed(Self.noAnswer)
    }
    return nil
  }

  /// Reads `source` again after an edit until its listing `shows` the change: from a live
  /// process up to `rereadAttempts` times, `rereadInterval` apart, since it reads the file a
  /// moment after the command wrote it; from a probe once, a new process reading it fresh.
  /// Nil when another session was shown meanwhile.
  private func reread(_ source: Source, until shows: (PermissionRulesState) -> Bool) async
    -> Bool?
  {
    let attempts = source.isLive ? max(1, rereadAttempts) : 1
    for attempt in 0..<attempts {
      if attempt > 0 { try? await Task.sleep(for: rereadInterval) }
      guard isShowing(source) else { return nil }
      if let state = await list(source), shows(state) { return true }
    }
    return isShowing(source) ? false : nil
  }

  private static func note(_ lines: [String]) -> String? {
    lines.isEmpty ? nil : lines.joined(separator: "\n")
  }
}
