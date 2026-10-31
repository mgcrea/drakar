import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// The Permissions tab's model against a fake source: what it reads, what it sends, and how
/// it reads again after an edit.
@MainActor
@Suite("The Permissions tab's listing and edits")
struct PermissionRulesModelTests {
  /// A session's rules as the fake lists them, and what was asked of it.
  private final class Fake {
    var state = PermissionRulesState(rules: [])
    /// Answers `list()` in place of `state` when set.
    var answer: PermissionRulesAnswer??
    var reads = 0
    var edits: [PermissionRuleEdit] = []
    var outcome: PermissionRuleEditOutcome = .saved(warnings: [], stored: [])
    /// Called on each read, after `reads` counts it and before the state is answered.
    var onRead: (Fake) -> Void = { _ in }
    /// Called on each edit, before the outcome is answered.
    var onEdit: (PermissionRuleEdit) -> Void = { _ in }
  }

  private func source(
    _ fake: Fake, key: String = "a", live: Bool = true, codex: Bool = false
  ) -> PermissionRulesModel.Source {
    PermissionRulesModel.Source(
      key: key, isCodex: codex, isLive: live,
      list: {
        fake.reads += 1
        fake.onRead(fake)
        if let answer = fake.answer { return answer }
        return .listed(fake.state)
      },
      edit: {
        fake.edits.append($0)
        fake.onEdit($0)
        return fake.outcome
      })
  }

  private func model() -> PermissionRulesModel {
    let model = PermissionRulesModel()
    model.rereadInterval = .milliseconds(1)
    return model
  }

  /// Shows `source` and waits for its read.
  private func shown(_ model: PermissionRulesModel, _ source: PermissionRulesModel.Source) async {
    model.show(source)
    await model.reading?.value
  }

  private static let npm = PermissionRule(
    behavior: .allow, source: "localSettings", rule: "Bash(npm run test:*)",
    editability: .persistent)

  @Test func listsOnShow() async {
    let fake = Fake()
    fake.state = PermissionRulesState(rules: [Self.npm])
    let model = model()
    #expect(model.listing == .idle)
    await shown(model, source(fake))
    #expect(model.listing == .listed(fake.state, live: true))
    #expect(fake.reads == 1)
    // The same session again reads nothing; Refresh does.
    await shown(model, source(fake, live: false))
    #expect(fake.reads == 1)
    model.refresh()
    await model.reading?.value
    #expect(fake.reads == 2)
  }

  @Test func codexSaysSo() async {
    let fake = Fake()
    let model = model()
    await shown(model, source(fake, codex: true))
    #expect(model.listing == .codex)
    #expect(fake.reads == 0)
  }

  @Test func aRefusalFails() async {
    let fake = Fake()
    fake.answer = .some(.refused("no rules for you"))
    let model = model()
    await shown(model, source(fake))
    #expect(model.listing == .failed("no rules for you"))
    fake.answer = .some(nil)
    model.refresh()
    await model.reading?.value
    #expect(model.listing == .failed("Claude Code didn't answer."))
  }

  @Test func addTrimsAndDropsBlankLines() async {
    let fake = Fake()
    let model = model()
    await shown(model, source(fake, live: false))
    #expect(await model.add("  A  \n\n B\n", behavior: .deny, file: .projectSettings) == nil)
    #expect(fake.edits == [.add(rules: ["A", "B"], behavior: .deny, file: .projectSettings)])
    #expect(await model.add(" \n ", behavior: .allow, file: .localSettings) == nil)
    #expect(fake.edits.count == 1)
  }

  @Test func addRereadsUntilTheRuleShows() async {
    let fake = Fake()
    fake.outcome = .saved(warnings: [], stored: [Self.npm.rule])
    // The third read after the edit is the first to have the rule.
    fake.onRead = { fake in
      if fake.reads == 4 { fake.state = PermissionRulesState(rules: [Self.npm]) }
    }
    let model = model()
    await shown(model, source(fake))
    #expect(await model.add(Self.npm.rule, behavior: .allow, file: .localSettings) == nil)
    #expect(model.listing == .listed(PermissionRulesState(rules: [Self.npm]), live: true))
    #expect(model.note == nil)
    #expect(fake.reads == 1 + 3)
  }

  /// A rule stored with another behavior, or in another file, is not the one added.
  @Test func anAddThatNeverShowsSaysSo() async {
    let fake = Fake()
    fake.outcome = .saved(warnings: [], stored: [Self.npm.rule])
    var elsewhere = Self.npm
    elsewhere.source = "projectSettings"
    var denied = Self.npm
    denied.behavior = .deny
    fake.state = PermissionRulesState(rules: [elsewhere, denied])
    let model = model()
    model.rereadAttempts = 5
    await shown(model, source(fake))
    #expect(await model.add(Self.npm.rule, behavior: .allow, file: .localSettings) == nil)
    #expect(model.note == "Saved; not in the list yet.")
    #expect(fake.reads == 1 + 5)
  }

  /// With nothing stored to look for, any change to the list is the add showing.
  @Test func anAddWithNothingStoredLooksForAChange() async {
    let fake = Fake()
    fake.onRead = { fake in
      if fake.reads == 3 { fake.state = PermissionRulesState(rules: [Self.npm]) }
    }
    let model = model()
    await shown(model, source(fake))
    #expect(await model.add(Self.npm.rule, behavior: .allow, file: .localSettings) == nil)
    #expect(model.note == nil)
    #expect(fake.reads == 1 + 2)
  }

  @Test func notLiveReadsOnceAfterAnEdit() async {
    let fake = Fake()
    fake.outcome = .saved(warnings: [], stored: [Self.npm.rule])
    let model = model()
    await shown(model, source(fake, live: false))
    #expect(await model.add(Self.npm.rule, behavior: .allow, file: .localSettings) == nil)
    #expect(fake.reads == 1 + 1)
    #expect(model.note == "Saved; not in the list yet.")
    #expect(model.listing == .listed(fake.state, live: false))
  }

  @Test func aRefusedAddReturnsTheWords() async {
    let fake = Fake()
    fake.state = PermissionRulesState(rules: [Self.npm])
    fake.outcome = .refused("dup")
    let model = model()
    await shown(model, source(fake))
    #expect(await model.add(Self.npm.rule, behavior: .allow, file: .localSettings) == "dup")
    #expect(model.listing == .listed(PermissionRulesState(rules: [Self.npm]), live: true))
    #expect(model.note == nil)
    #expect(fake.reads == 1)
  }

  @Test func removeSendsTheRuleVerbatim() async {
    let rule = PermissionRule(
      behavior: .deny, source: "localSettings", rule: "Bash(rm\u{200B} -rf)",
      editability: .persistent)
    let fake = Fake()
    fake.state = PermissionRulesState(rules: [Self.npm, rule])
    let model = model()
    var removingSeen: [Bool] = []
    fake.onEdit = { _ in removingSeen.append(model.removing.contains(rule)) }
    // The first read after the edit still has the rule; the second has it gone.
    fake.onRead = { fake in
      if fake.reads > 1 { removingSeen.append(model.removing.contains(rule)) }
      if fake.reads == 3 { fake.state = PermissionRulesState(rules: [Self.npm]) }
    }
    await shown(model, source(fake))
    await model.remove(rule)
    #expect(
      fake.edits == [.remove(rule: "Bash(rm\u{200B} -rf)", behavior: .deny, file: .localSettings)])
    #expect(removingSeen == [true, true, true])
    #expect(model.removing.isEmpty)
    #expect(model.note == nil)
    #expect(model.listing == .listed(PermissionRulesState(rules: [Self.npm]), live: true))
  }

  @Test func aRefusedRemoveSaysWhy() async {
    let fake = Fake()
    fake.state = PermissionRulesState(rules: [Self.npm])
    fake.outcome = .refused("Rule not found")
    let model = model()
    await shown(model, source(fake))
    await model.remove(Self.npm)
    #expect(model.note == "Rule not found")
    #expect(model.removing.isEmpty)
    #expect(fake.reads == 1)
  }

  @Test func aRemoveThatNeverShowsSaysSo() async {
    let fake = Fake()
    fake.state = PermissionRulesState(rules: [Self.npm])
    let model = model()
    model.rereadAttempts = 3
    await shown(model, source(fake))
    await model.remove(Self.npm)
    #expect(model.note == "Saved; not in the list yet.")
    #expect(model.removing.isEmpty)
    #expect(fake.reads == 1 + 3)
  }

  @Test func warningsBecomeTheNote() async {
    let fake = Fake()
    fake.outcome = .saved(warnings: ["w1", "w2"], stored: [Self.npm.rule])
    fake.onRead = { fake in fake.state = PermissionRulesState(rules: [Self.npm]) }
    let model = model()
    await shown(model, source(fake))
    #expect(await model.add(Self.npm.rule, behavior: .allow, file: .localSettings) == nil)
    #expect(model.note == "w1\nw2")
  }

  @Test func aLateListingForAnotherSessionIsDropped() async {
    let a = PermissionRulesState(rules: [Self.npm])
    let b = PermissionRulesState(rules: [])
    var held: CheckedContinuation<PermissionRulesAnswer?, Never>?
    let slow = PermissionRulesModel.Source(
      key: "a", isCodex: false, isLive: true,
      list: { await withCheckedContinuation { held = $0 } },
      edit: { _ in .saved(warnings: [], stored: []) })
    let fake = Fake()
    fake.state = b
    let model = model()
    model.show(slow)
    let readingA = model.reading
    while held == nil { await Task.yield() }
    await shown(model, source(fake, key: "b"))
    #expect(model.listing == .listed(b, live: true))
    held?.resume(returning: .listed(a))
    await readingA?.value
    #expect(model.listing == .listed(b, live: true))
  }
}
