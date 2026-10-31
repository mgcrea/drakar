import DrakarKit
import Foundation
import Testing

@Suite("Permission rules, their edits and the plan")
struct PermissionRulesTests {

  private func json(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

  /// A listing whose only rule is `rule`, as the CLI sends it.
  private func state(rule: String) throws -> PermissionRulesState {
    try #require(
      PermissionRulesState(
        try json(#"{"state": {"rules": [\#(rule)], "managedOnly": false}}"#)))
  }

  /// The spec's real reply (2.1.312): a project with a local allow and deny.
  @Test func decodesTheRealReply() throws {
    let state = try #require(
      PermissionRulesState(
        try json(
          #"""
          {"state": {"rules": [
            {"behavior": "allow", "source": "localSettings", "rule": "Bash(npm run test:*)",
             "description": {"prefix": "Any Bash command starting with ", "emphasis": "npm run test"},
             "editability": "persistent"},
            {"behavior": "deny", "source": "localSettings", "rule": "Read(./secrets/**)",
             "editability": "persistent"}],
           "workspaceDirectories": [], "originalCwd": "/p/rules", "managedOnly": false}}
          """#)))
    #expect(state.rules.count == 2)
    let allow = state.rules[0]
    #expect(allow.behavior == .allow)
    #expect(allow.source == "localSettings")
    #expect(allow.rule == "Bash(npm run test:*)")
    #expect(allow.description?.prefix == "Any Bash command starting with ")
    #expect(allow.description?.emphasis == "npm run test")
    #expect(allow.description?.suffix == nil)
    #expect(allow.editability == .persistent)
    #expect(!allow.notInEffect)
    #expect(allow.isRemovable)
    let deny = state.rules[1]
    #expect(deny.behavior == .deny)
    #expect(deny.rule == "Read(./secrets/**)")
    #expect(deny.description == nil)
    #expect(deny.isRemovable)
    #expect(!state.managedOnly)
    #expect(state.directories.isEmpty)
    #expect(state.errors.isEmpty)
  }

  /// A source, editability or behavior the CLI adds later never fails the listing.
  @Test func unknownValuesDoNotFail() throws {
    let state = try #require(
      PermissionRulesState(
        try json(
          #"""
          {"state": {"rules": [
            {"behavior": "allow", "source": "somethingNew", "rule": "A", "editability": "weird",
             "notInEffect": true},
            {"behavior": "maybe", "source": "localSettings", "rule": "B", "editability": "persistent"}],
           "workspaceDirectories": [{"path": "/extra", "source": "cliArg"}],
           "managedOnly": true,
           "errors": [{"file": "/p/.claude/settings.json", "message": "Invalid JSON"}, {"file": "/q"}]}}
          """#)))
    #expect(state.rules.count == 1)
    let rule = state.rules[0]
    #expect(rule.source == "somethingNew")
    #expect(rule.editability == .readonly)
    #expect(!rule.isRemovable)
    #expect(rule.notInEffect)
    #expect(state.directories == [.init(path: "/extra", source: "cliArg")])
    #expect(state.managedOnly)
    #expect(state.errors == ["Invalid JSON", #"{"file":"/q"}"#])
  }

  /// A persistent rule outside the three files the edit command writes is not removable
  /// either.
  @Test func sessionRulesAreNotRemovable() throws {
    let session = try state(
      rule: #"{"behavior": "allow", "source": "session", "rule": "A", "editability": "session"}"#)
    #expect(session.rules.first?.editability == .session)
    #expect(session.rules.first?.isRemovable == false)
    let policy = try state(
      rule:
        #"{"behavior": "deny", "source": "policySettings", "rule": "A", "editability": "persistent"}"#
    )
    #expect(policy.rules.first?.isRemovable == false)
  }

  /// Nil without `state.rules`: a reply Drakar cannot read is not an empty listing.
  @Test func aReplyWithoutRulesIsNotAListing() throws {
    #expect(PermissionRulesState(nil) == nil)
    #expect(PermissionRulesState(try json(#"{}"#)) == nil)
    #expect(PermissionRulesState(try json(#"{"state": {"managedOnly": false}}"#)) == nil)
  }

  /// One edit, as `claude edit-permission-rules --json` reads it on stdin.
  @Test func encodesEdits() throws {
    #expect(
      PermissionRuleEdit.add(rules: ["A", "B"], behavior: .allow, file: .localSettings).json
        == (try json(
          #"{"op":"add","rules":["A","B"],"behavior":"allow","destination":"localSettings"}"#)))
    #expect(
      PermissionRuleEdit.remove(rule: "R", behavior: .deny, file: .userSettings).json
        == (try json(#"{"op":"remove","rule":"R","behavior":"deny","source":"userSettings"}"#)))
    #expect(PermissionRuleEdit.arguments == ["edit-permission-rules", "--json"])
  }

  @Test func readsOutcomes() {
    #expect(
      PermissionRuleEditOutcome.read(
        status: 0, output: "noise\n{\"ok\":true,\"warnings\":[\"w\"],\"stored\":[\"S\"]}\n",
        errors: "") == .saved(warnings: ["w"], stored: ["S"]))
    #expect(
      PermissionRuleEditOutcome.read(status: 0, output: "{\"ok\":true}\n\n", errors: "")
        == .saved(warnings: [], stored: []))
    #expect(
      PermissionRuleEditOutcome.read(
        status: 1, output: "", errors: "Error: rule not found: no deny rule…\n")
        == .refused("rule not found: no deny rule…"))
    #expect(
      PermissionRuleEditOutcome.read(status: 1, output: "", errors: "")
        == .refused("Claude Code couldn't save the rule (exit status 1)."))
  }

  @Test func decodesPlans() throws {
    let none = try #require(PlanReply(try json(#"{"exists": false}"#)))
    #expect(!none.exists)
    #expect(none.content == nil)
    #expect(none.path == nil)
    let plan = try #require(
      PlanReply(try json(##"{"exists": true, "content": "# P", "path": "/p.md"}"##)))
    #expect(plan.exists)
    #expect(plan.content == "# P")
    #expect(plan.path == "/p.md")
    #expect(PlanReply(try json(#"{}"#)) == nil)
    #expect(PlanReply(nil) == nil)
  }

  /// Format and control characters show as escapes; the rule itself is never changed.
  @Test func escapesInvisibleCharacters() {
    #expect(PermissionRule.displayed("Bash(rm\u{200B} -rf)") == "Bash(rm\\u{200B} -rf)")
    #expect(PermissionRule.displayed("a\u{7}b") == "a\\u{0007}b")
    #expect(PermissionRule.displayed("a\u{E0041}b") == "a\\u{E0041}b")
    #expect(PermissionRule.displayed("héllo ✓") == "héllo ✓")
  }
}
