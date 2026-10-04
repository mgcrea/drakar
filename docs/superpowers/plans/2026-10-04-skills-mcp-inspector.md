# Skills and MCP Servers Inspector — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A project window gets a right-hand inspector listing the skills and MCP servers its
`claude` would load. A click runs a skill in a new session, a right click runs it in the
current one, and each server shows its status.

**Architecture:** DrakarKit decodes the CLI's `initialize` and `mcp_status` replies
(`ProjectCapabilities`) and diffs two readings (`CapabilityChanges`), all against a
captured fixture. The app runs a short `claude` per project (`CapabilityProbe`) through the
same launch path sessions use (`ClaudeLaunch`). It keeps the result per folder and account
for the launch (`CapabilityStore`), lets a project's own sessions refresh the skills, and
marks changes per window. `InspectorView` draws it in an `.inspector` column.

**Tech Stack:** Swift 6 (tools 6.3), SwiftUI + AppKit on macOS 26, Swift Testing.
DrakarKit stays Foundation-only.

**Spec:** `docs/superpowers/specs/2026-10-04-skills-mcp-inspector-design.md`

**Where:** worktree `/Users/olivier/Projects/apps/drakar-skills-inspector`, branch
`feat/skills-inspector`, from `main`. All paths below are relative to `apps/apple/` unless
they start with `docs/`.

## Global Constraints

- DrakarKit has zero dependencies and imports nothing above Foundation. `make test` (in
  `apps/apple`) resolves nothing and runs offline.
- Protocol shapes are tested against captured output or minimal synthetic lines of shapes
  already captured (`docs/claude-stream-json.md`).
- The app target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; kit code is
  nonisolated by default. The Xcode project uses synchronized folders: a new file under
  `Drakar/` or `DrakarTests/` is in the target without touching the project file.
- Drakar opens no connection: `make audit` (repo root) must still pass. No model is called:
  the probe sends no prompt.
- **An MCP server's `config` is never decoded, stored, logged or committed.** It carries
  headers and tokens in clear.
- Commits: `feat(kit): …`, `feat(apple): …`, `docs: …`, `test(kit): …`, a lowercase
  sentence; a prose body when the why is not obvious. No trailers.
- Before each commit: `make -C apps/apple format-swift`.
- Probe request ids: `probe-init` and `probe-mcp`. Probe timeout 20 s; after input is
  closed, terminate only if the process is still there 2 s later. Never a hard kill first.
- File-change refresh: 2 s after the last change under the project's `.claude/skills/`,
  `.claude/commands/`, `.claude/settings*.json` or `.mcp.json`.
- Scene storage keys: `drakar.inspectorShown` (false), `drakar.skillsFraction` (0.6),
  `drakar.skillsCollapsed` (false), `drakar.mcpCollapsed` (false).
- Shortcut: View › Show Inspector / Hide Inspector is ⌥⌘0.
- Built-in commands (`builtin: true`) are never listed, the bundled skills among them.
- Server order: failed, needs auth, then the rest; alphabetical within each. Skill order:
  alphabetical by the name without its namespace.

## Review Focus

1. **A probe outliving its window**: closing the tab mid-probe, or quitting, leaves no
   `claude` running and no `sessions/<pid>.json` behind. Pinned in Task 4
   (`aCancelledProbeLetsTheProcessGo`) and Task 7 (`closingTheWindowCancelsItsProbe`).
2. **A token in a server's config** reaching anything Drakar keeps. Pinned in Task 1
   (`neverKeepsAServersConfig`).
3. **Running a skill into a session that has a draft, is mid-turn, or is read-only**: the
   draft is kept after the name; the run is refused rather than queued. Pinned in Task 6.
4. **A CLI that answers `initialize` but never `mcp_status`** (an older one), or answers
   with an error: the skills show and the servers pane says why. Pinned in Task 2
   (`anErrorAnswerIsKept`) and Task 4 (`keepsTheSkillsWhenTheStatusNeverComes`).
5. **A filter with surrounding spaces, other case or accents** ("  BRAIN", "sèo"): it
   matches as a person expects, and blank shows everything. Pinned in Task 2.

The composer taking focus with `/name ` in it must leave the cursor at the end, not select
the text, or the first key typed replaces the name. That is AppKit behaviour no hosted test
sees; it is checked live in Task 9.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Packages/DrakarKit/Sources/DrakarKit/Capabilities.swift` (new) | `SkillEntry`, `MCPServerStatus`, `MCPTool`, `MCPServerEntry`, `ProjectCapabilities`, `CapabilityName`, `CapabilityChanges`, `CapabilityReplies` |
| `Packages/DrakarKit/Sources/DrakarKit/ClientMessage.swift` | `.mcpStatus(requestID:)` |
| `Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/capabilities.jsonl` (new) | the two replies, trimmed and scrubbed |
| `Packages/DrakarKit/Tests/DrakarKitTests/Fixture.swift` | `case capabilities` |
| `Packages/DrakarKit/Tests/DrakarKitTests/CapabilitiesTests.swift` (new) | decoding, names, filter, order, diff, replies |
| `docs/claude-stream-json.md` | "Skills and MCP status" |
| `Drakar/Services/ClaudeLaunch.swift` (new) | executable, environment and account for a `claude` in a folder |
| `Drakar/Services/ClaudeSession.swift` | spawn through `ClaudeLaunch`; `onInitialized` |
| `Drakar/Services/CapabilityProbe.swift` (new) | `ProbeOutcome`, `CapabilityProbe.run` |
| `Drakar/Services/Capabilities.swift` (new) | `Capabilities` (one entry), `CapabilityStore`, `CapabilityMarks`, status and source labels |
| `Drakar/Services/Project.swift` | binding, `run(_:in:)`, prefill, marks, live feed, file refresh, release |
| `Drakar/Services/Workspace.swift` | `onCapabilityFilesChanged`, `touchesCapabilities`, `FocusedValues.inspectorShown` |
| `Drakar/Views/ComposerView.swift` | hint line, focus request |
| `Drakar/Views/SessionView.swift` | passes them |
| `Drakar/Views/InspectorView.swift` (new) | the column, its panes, rows, toolbar toggle |
| `Drakar/ContentView.swift` | `.inspector`, toolbar item, first load, marks cleared on hide |
| `Drakar/DrakarApp.swift` | `InspectorCommand` |
| `DrakarTests/ClaudeLaunchTests.swift` (new), `DrakarTests/CapabilityProbeTests.swift` (new), `DrakarTests/CapabilityStoreTests.swift` (new), `DrakarTests/SkillRunTests.swift` (new), `DrakarTests/ClaudeSessionTests.swift` | hosted tests |

---

### Task 0: Worktree

- [ ] **Step 1: Create the worktree and check the suites are green before anything changes**

```bash
cd /Users/olivier/Projects/apps/drakar
git worktree add ../drakar-skills-inspector -b feat/skills-inspector main
cd ../drakar-skills-inspector/apps/apple
make test && make test-app
```

Expected: both pass. If either fails on `main`, stop and report it; do not fix unrelated
failures in this branch.

---

### Task 1: Decode the two replies (kit)

**Files:**
- Create: `Packages/DrakarKit/Sources/DrakarKit/Capabilities.swift`
- Modify: `Packages/DrakarKit/Sources/DrakarKit/ClientMessage.swift`
- Create: `Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/capabilities.jsonl`
- Modify: `Packages/DrakarKit/Tests/DrakarKitTests/Fixture.swift`
- Create: `Packages/DrakarKit/Tests/DrakarKitTests/CapabilitiesTests.swift`
- Modify: `Packages/DrakarKit/Tests/DrakarKitTests/ClientMessageTests.swift`
- Modify: `docs/claude-stream-json.md`

**Interfaces:**
- Produces:
  - `public struct SkillEntry: Sendable, Hashable, Identifiable { name, description, argumentHint: String; init(name:description:argumentHint:); var id: String; var takesArguments: Bool }`
  - `public enum MCPServerStatus: Sendable, Hashable { connected, needsAuth, failed, pending, other(String); init(_ raw: String) }`
  - `public struct MCPTool: Sendable, Hashable { name: String; isReadOnly, isDestructive: Bool }`
  - `public struct MCPServerEntry: Sendable, Hashable, Identifiable { name: String; status: MCPServerStatus; source, version: String?; tools: [MCPTool]; error: String?; init(name:status:source:version:tools:error:) }`
  - `public struct ProjectCapabilities: Sendable, Equatable { skills: [SkillEntry]?; mcpServers: [MCPServerEntry]?; init(skills:mcpServers:); static func skills(fromInitialize: JSONValue?) -> [SkillEntry]?; static func servers(fromMCPStatus: JSONValue?) -> [MCPServerEntry]? }`
  - `ClientMessage.mcpStatus(requestID: String)`

- [ ] **Step 1: Add the fixture**

`Packages/DrakarKit/Tests/DrakarKitTests/Fixtures/capabilities.jsonl`, exactly two lines.
They are trimmed from a real 2.1.288 capture (2026-10-04). Every header, env value and
URL that could hold a token is replaced by `drakar-fixture-secret`, and the `account` block
of the `initialize` reply (an email) is dropped:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"probe-init","response":{"commands":[{"name":"check","description":"Fixes all failing tests, lint errors, formatting issues, and type errors (user)","argumentHint":""},{"name":"compact","description":"Free up context by summarizing the conversation so far","argumentHint":"<optional custom summarization instructions>","builtin":true},{"name":"simplify","description":"Review the changed code for reuse, simplification, efficiency, and altitude cleanups, then apply the fixes.","argumentHint":"[<target>]","builtin":true},{"name":"superpowers:brainstorming","description":"(superpowers) You MUST use this before any creative work - creating features, building components, adding functionality, or modifying behavior.","argumentHint":"","aliases":["brainstorming"]},{"name":"marketing:seo-audit","description":"(marketing) Run a comprehensive SEO audit.","argumentHint":"<url or topic> [audit type]"},{"name":"distill","description":"Distill the session into notes","argumentHint":"[optional focus, e.g. 'the tile cache work']"}],"agents":[],"models":[],"pid":0},"pending_permission_requests":[],"pending_user_dialog_requests":[]}}
{"type":"control_response","response":{"subtype":"success","request_id":"probe-mcp","response":{"mcpServers":[{"name":"armada","status":"connected","serverInfo":{"name":"armada","title":"Armada","version":"1.9.0"},"config":{"type":"http","url":"http://127.0.0.1:8790/mcp","headers":{"Authorization":"Bearer drakar-fixture-secret"}},"scope":"user","source":"user","tools":[{"name":"armada_get_fleet","annotations":{"readOnly":true}},{"name":"armada_close_session","annotations":{"destructive":true}},{"name":"armada_send_message","annotations":{}}]},{"name":"cupertino-calendar","status":"connected","serverInfo":{"name":"@mgcrea/mcp-apple-calendar","version":"1.25.0"},"config":{"type":"stdio","command":"/Applications/Cupertino.app/Contents/Helpers/cupertino-bridge","args":["--server=calendar"],"env":{"API_KEY":"drakar-fixture-secret"}},"scope":"user","source":"user","tools":[{"name":"apple_calendar_list_events","annotations":{"readOnly":true}}]},{"name":"tracker","status":"failed","error":"the token request failed: Grant not found","config":{"type":"http","url":"https://tracker.example/mcp?key=drakar-fixture-secret"},"scope":"user","source":"user"},{"name":"plugin:stripe:stripe","status":"needs-auth","config":{"type":"http","url":"https://mcp.stripe.com"},"scope":"dynamic","source":"plugin"},{"name":"claude.ai Gmail","status":"needs-auth","scope":"claudeai","source":"claudeai"},{"name":"claude.ai Claude Docs","status":"pending","scope":"claudeai","source":"claudeai"},{"name":"later","status":"disabled","config":{"type":"stdio","command":"later"},"scope":"project","source":"project"},{"status":"connected","source":"user"}]}}}
```

In `Fixture.swift`, after `case closingEndings`:

```swift
  /// What a `claude` with no prompt answers to `initialize` and `mcp_status` (2.1.288,
  /// 2026-10-04, the skills inspector's spike): a few commands, the CLI's own among them,
  /// and servers in every status seen. Trimmed, and every header, env value and URL token
  /// replaced by `drakar-fixture-secret`, the `initialize` reply's account dropped.
  case capabilities = "capabilities"
```

- [ ] **Step 2: Write the failing tests**

`Packages/DrakarKit/Tests/DrakarKitTests/CapabilitiesTests.swift`:

```swift
import DrakarKit
import Foundation
import Testing

@Suite("What a project's claude would load")
struct CapabilitiesTests {

  private func reply(_ id: String) throws -> JSONValue? {
    let responses = try Fixture.capabilities.messages.compactMap { message -> ControlResponse? in
      if case .controlResponse(let response) = message { return response }
      return nil
    }
    return try #require(responses.first { $0.requestID == id }).response
  }

  private func skills() throws -> [SkillEntry] {
    try #require(ProjectCapabilities.skills(fromInitialize: try reply("probe-init")))
  }

  private func servers() throws -> [MCPServerEntry] {
    try #require(ProjectCapabilities.servers(fromMCPStatus: try reply("probe-mcp")))
  }

  /// The CLI's own commands, `/compact` and the bundled `/simplify` alike, are not skills
  /// the project brings.
  @Test func listsSkillsWithoutTheCLIsOwn() throws {
    #expect(
      Set(try skills().map(\.name))
        == ["check", "superpowers:brainstorming", "marketing:seo-audit", "distill"])
  }

  /// An empty hint is a skill a click sends at once.
  @Test func anEmptyHintTakesNoArguments() throws {
    let skills = try skills()
    let check = try #require(skills.first { $0.name == "check" })
    let audit = try #require(skills.first { $0.name == "marketing:seo-audit" })
    #expect(!check.takesArguments)
    #expect(audit.takesArguments)
    #expect(audit.argumentHint == "<url or topic> [audit type]")
  }

  /// No `commands` is not an empty list: the CLI did not say, and the pane says so.
  @Test func aReplyWithoutCommandsListsNothing() {
    #expect(ProjectCapabilities.skills(fromInitialize: nil) == nil)
    #expect(ProjectCapabilities.skills(fromInitialize: .object([:])) == nil)
    #expect(ProjectCapabilities.skills(fromInitialize: .object(["commands": .array([])])) == [])
    #expect(ProjectCapabilities.servers(fromMCPStatus: .object([:])) == nil)
  }

  @Test func readsEveryServerStatus() throws {
    let status = Dictionary(uniqueKeysWithValues: try servers().map { ($0.name, $0.status) })
    #expect(status["armada"] == .connected)
    #expect(status["tracker"] == .failed)
    #expect(status["plugin:stripe:stripe"] == .needsAuth)
    #expect(status["claude.ai Gmail"] == .needsAuth)
    #expect(status["claude.ai Claude Docs"] == .pending)
    #expect(status["later"] == .other("disabled"))
  }

  /// A server without a name is dropped, not shown as a blank row.
  @Test func skipsAServerWithoutAName() throws {
    #expect(try servers().count == 7)
  }

  @Test func readsToolsVersionSourceAndError() throws {
    let servers = try servers()
    let armada = try #require(servers.first { $0.name == "armada" })
    #expect(armada.version == "1.9.0")
    #expect(armada.source == "user")
    #expect(
      armada.tools == [
        MCPTool(name: "armada_get_fleet", isReadOnly: true, isDestructive: false),
        MCPTool(name: "armada_close_session", isReadOnly: false, isDestructive: true),
        MCPTool(name: "armada_send_message", isReadOnly: false, isDestructive: false),
      ])
    let tracker = try #require(servers.first { $0.name == "tracker" })
    #expect(tracker.error == "the token request failed: Grant not found")
    #expect(tracker.tools.isEmpty)
  }

  /// `config` holds headers, env values and URLs with tokens in them, in clear. Nothing
  /// decoded may hold any of it.
  @Test func neverKeepsAServersConfig() throws {
    let kept = String(describing: try servers())
    #expect(!kept.contains("drakar-fixture-secret"))
    #expect(!kept.contains("Bearer"))
    #expect(!kept.contains("127.0.0.1"))
    #expect(!kept.contains("cupertino-bridge"))
  }
}
```

In `ClientMessageTests.swift`, after `encodesInitialize`:

```swift
  @Test func encodesMCPStatus() throws {
    #expect(
      try text(.mcpStatus(requestID: "probe-mcp"))
        == #"{"request":{"subtype":"mcp_status"},"request_id":"probe-mcp","type":"control_request"}"#
        + "\n")
  }
```

- [ ] **Step 3: Run them to see them fail**

Run: `make test`
Expected: the build fails: `cannot find 'ProjectCapabilities' in scope` and `type
'ClientMessage' has no member 'mcpStatus'`.

- [ ] **Step 4: Add `mcpStatus`**

In `ClientMessage.swift`, after `case contextUsage(requestID: String)`:

```swift
  /// Every MCP server the process would connect, with its status and tools. Answered before
  /// any prompt (docs/claude-stream-json.md, "Skills and MCP status").
  case mcpStatus(requestID: String)
```

and in `json`, after the `.contextUsage` case:

```swift
    case .mcpStatus(let id):
      Self.controlRequest(id, ["subtype": .string("mcp_status")])
```

- [ ] **Step 5: Write the decoders**

`Packages/DrakarKit/Sources/DrakarKit/Capabilities.swift`:

```swift
import Foundation

/// A skill or command the project's `claude` offers: one entry of the `initialize` reply's
/// `commands` (docs/claude-stream-json.md, "Skills and MCP status").
public struct SkillEntry: Sendable, Hashable, Identifiable {
  public var name: String
  public var description: String
  /// What the skill takes after its name; empty when it takes nothing.
  public var argumentHint: String

  public init(name: String, description: String = "", argumentHint: String = "") {
    self.name = name
    self.description = description
    self.argumentHint = argumentHint
  }

  public var id: String { name }

  /// A click sends a skill that takes nothing at once, and puts one that does in the
  /// composer.
  public var takesArguments: Bool {
    !argumentHint.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// An entry of `commands`; nil for one without a name, or for the CLI's own (`builtin`),
  /// which covers the skills it bundles too.
  init?(_ json: JSONValue) {
    guard let name = json["name"]?.stringValue, !name.isEmpty,
      json["builtin"]?.boolValue != true
    else { return nil }
    self.init(
      name: name, description: json["description"]?.stringValue ?? "",
      argumentHint: json["argumentHint"]?.stringValue ?? "")
  }
}

/// A server's state, in the CLI's words.
public enum MCPServerStatus: Sendable, Hashable {
  case connected
  case needsAuth
  case failed
  case pending
  /// A status this version of Drakar does not know, as the CLI wrote it.
  case other(String)

  public init(_ raw: String) {
    switch raw {
    case "connected": self = .connected
    case "needs-auth": self = .needsAuth
    case "failed": self = .failed
    case "pending": self = .pending
    default: self = .other(raw)
    }
  }
}

public struct MCPTool: Sendable, Hashable {
  public var name: String
  public var isReadOnly: Bool
  public var isDestructive: Bool

  public init(name: String, isReadOnly: Bool, isDestructive: Bool) {
    self.name = name
    self.isReadOnly = isReadOnly
    self.isDestructive = isDestructive
  }
}

/// One server of the `mcp_status` reply. Its `config` is never read: it carries the
/// server's headers, env values and URLs, tokens among them, in clear.
public struct MCPServerEntry: Sendable, Hashable, Identifiable {
  public var name: String
  public var status: MCPServerStatus
  /// Where it is configured, in the CLI's words: `user`, `project`, `local`, `plugin`,
  /// `claudeai`.
  public var source: String?
  public var version: String?
  public var tools: [MCPTool]
  /// Why it failed, for a failed server.
  public var error: String?

  public init(
    name: String, status: MCPServerStatus, source: String? = nil, version: String? = nil,
    tools: [MCPTool] = [], error: String? = nil
  ) {
    self.name = name
    self.status = status
    self.source = source
    self.version = version
    self.tools = tools
    self.error = error
  }

  public var id: String { name }

  init?(_ json: JSONValue) {
    guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
    self.init(
      name: name, status: MCPServerStatus(json["status"]?.stringValue ?? ""),
      source: json["source"]?.stringValue,
      version: json["serverInfo"]?["version"]?.stringValue,
      tools: (json["tools"]?.arrayValue ?? []).compactMap { tool in
        guard let name = tool["name"]?.stringValue else { return nil }
        return MCPTool(
          name: name, isReadOnly: tool["annotations"]?["readOnly"]?.boolValue == true,
          isDestructive: tool["annotations"]?["destructive"]?.boolValue == true)
      },
      error: json["error"]?.stringValue)
  }
}

/// What a project's `claude` would load: its skills and its MCP servers, each nil until a
/// reply listed it.
public struct ProjectCapabilities: Sendable, Equatable {
  public var skills: [SkillEntry]?
  public var mcpServers: [MCPServerEntry]?

  public init(skills: [SkillEntry]? = nil, mcpServers: [MCPServerEntry]? = nil) {
    self.skills = skills
    self.mcpServers = mcpServers
  }

  /// The skills an `initialize` reply lists, the CLI's own left out; nil when it has no
  /// `commands` at all, which is not the same as an empty list.
  public static func skills(fromInitialize reply: JSONValue?) -> [SkillEntry]? {
    guard let commands = reply?["commands"]?.arrayValue else { return nil }
    return commands.compactMap(SkillEntry.init)
  }

  /// The servers an `mcp_status` reply lists; nil when it has no `mcpServers`.
  public static func servers(fromMCPStatus reply: JSONValue?) -> [MCPServerEntry]? {
    guard let servers = reply?["mcpServers"]?.arrayValue else { return nil }
    return servers.compactMap(MCPServerEntry.init)
  }
}
```

- [ ] **Step 6: Run the tests**

Run: `make test`
Expected: PASS, the new suite and `encodesMCPStatus` included.

- [ ] **Step 7: Write down what the spike found**

In `docs/claude-stream-json.md`, in the paragraph listing "Other control subtypes the
extension sends, unverified here", remove `mcp_status` from the list. Then add this section
before "## Observed details worth knowing":

```markdown
## Skills and MCP status (verified 2026-10-04, 2.1.288)

A process started with Drakar's arguments answers two control requests before any prompt,
in 1.2 to 1.8 s, and writes no transcript:

- **`initialize`**: the reply's `response.commands` lists every command, each
  `{name, description, argumentHint}`, with `builtin: true` on the CLI's own (58 of 161 on
  the spike's Mac) and `aliases` on some. `argumentHint` is always there; `""` means the
  command takes no arguments. `builtin` covers the skills the CLI bundles too (`simplify`,
  `code-review`, `loop`): nothing tells them from `compact`. Plugin skills are namespaced
  (`superpowers:brainstorming`), and their description starts `(superpowers) `.
- **`mcp_status`**, sent as `{"type":"control_request","request_id":"…","request":
  {"subtype":"mcp_status"}}`: the reply's `response.mcpServers` lists every server, each
  `{name, status, source, scope, config}`, plus `serverInfo` (`name`, `title`, `version`)
  and `tools` (`[{name, annotations: {readOnly, destructive}}]`) once connected, and `error`
  when failed. Statuses seen: `connected`, `needs-auth`, `failed`, `pending`. Sources:
  `user`, `plugin` (scope `dynamic`), `claudeai`.

**`config` is the server's configuration as written, secrets included**: a user server's
`headers.Authorization` came back as `Bearer …` in clear. Drakar never decodes it.

**The process registers as a live session** while it runs: `<config>/sessions/<pid>.json`
appears (`status: idle`, `entrypoint: claude-vscode`, a derived name) and is removed when it
exits after its stdin closes. A process killed outright leaves it behind. Drakar's own lists
skip its children (`LiveSession.read`); Armada shows it as an idle session for a second or two.

Captured as the `capabilities` fixture, trimmed, every secret replaced.
```

- [ ] **Step 8: Format and commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit docs/claude-stream-json.md
git commit -m "feat(kit): a project's skills and mcp servers from the replies to initialize and mcp_status"
```

---

### Task 2: Names, filter, order, changes and the probe's replies (kit)

**Files:**
- Modify: `Packages/DrakarKit/Sources/DrakarKit/Capabilities.swift`
- Modify: `Packages/DrakarKit/Tests/DrakarKitTests/CapabilitiesTests.swift`

**Interfaces:**
- Consumes: Task 1's types.
- Produces:
  - `public enum CapabilityName { static func namespace(of: String) -> String?; static func shortName(of: String) -> String }`
  - `SkillEntry.namespace: String?`, `.shortName: String`, `.displayDescription: String`, `.matches(_ query: String) -> Bool`
  - `MCPServerEntry.namespace`, `.shortName`, `.isProblem: Bool`, `.matches(_:)`
  - `ProjectCapabilities.skills(fromInitialize:)` and `.servers(fromMCPStatus:)` return sorted lists; `static func sorted(_: [SkillEntry]) -> [SkillEntry]`, `static func sorted(_: [MCPServerEntry]) -> [MCPServerEntry]`
  - `public struct CapabilityChanges: Sendable, Equatable { addedSkills: [String]; worsenedServers: [String]; var isEmpty: Bool; static func diff(from: ProjectCapabilities?, to: ProjectCapabilities) -> CapabilityChanges }`
  - `public struct CapabilityReplies: Sendable, Equatable { init(initializeID:statusID:); capabilities: ProjectCapabilities; hasInitialize, hasStatus: Bool; initializeError, statusError: String?; isComplete: Bool; mutating func take(_ response: ControlResponse) }`

- [ ] **Step 1: Write the failing tests**

Append to `CapabilitiesTests`:

```swift
  // MARK: Names, filter, order

  @Test func splitsANamespaceOffTheName() {
    #expect(CapabilityName.namespace(of: "superpowers:brainstorming") == "superpowers")
    #expect(CapabilityName.shortName(of: "superpowers:brainstorming") == "brainstorming")
    #expect(CapabilityName.namespace(of: "plugin:stripe:stripe") == "plugin:stripe")
    #expect(CapabilityName.shortName(of: "plugin:stripe:stripe") == "stripe")
    #expect(CapabilityName.namespace(of: "check") == nil)
    #expect(CapabilityName.shortName(of: "check") == "check")
    // A trailing colon leaves no short name to show: the whole name stands.
    #expect(CapabilityName.shortName(of: "odd:") == "odd:")
    #expect(CapabilityName.namespace(of: "odd:") == nil)
  }

  /// The row shows the namespace already; its description does not repeat it.
  @Test func dropsTheNamespaceFromThePluginsDescription() throws {
    let skill = try #require(try skills().first { $0.name == "superpowers:brainstorming" })
    #expect(skill.displayDescription.hasPrefix("You MUST use this"))
    let check = try #require(try skills().first { $0.name == "check" })
    #expect(check.displayDescription == check.description)
  }

  /// Case, accents and stray spaces do not matter; a blank filter keeps everything.
  @Test func filtersAsAPersonTypes() {
    let skill = SkillEntry(
      name: "superpowers:brainstorming", description: "Explores intent before the design")
    #expect(skill.matches(""))
    #expect(skill.matches("   "))
    #expect(skill.matches("  BRAIN"))
    #expect(skill.matches("intent"))
    #expect(!skill.matches("deploy"))
    let audit = SkillEntry(name: "marketing:seo-audit", description: "Audit the site")
    #expect(audit.matches("sèo"))
    let server = MCPServerEntry(name: "plugin:stripe:stripe", status: .needsAuth)
    #expect(server.matches("Stripe"))
    #expect(!server.matches("armada"))
  }

  @Test func sortsSkillsByTheirShortName() throws {
    #expect(
      try skills().map(\.name)
        == ["superpowers:brainstorming", "check", "distill", "marketing:seo-audit"])
  }

  /// What needs the person comes first.
  @Test func sortsServersByWhatNeedsThePersonFirst() throws {
    #expect(
      try servers().map(\.name) == [
        "tracker", "claude.ai Gmail", "plugin:stripe:stripe", "armada", "claude.ai Claude Docs",
        "cupertino-calendar", "later",
      ])
  }

  // MARK: Changes

  private func lists(_ skills: [String], _ servers: [(String, MCPServerStatus)])
    -> ProjectCapabilities
  {
    ProjectCapabilities(
      skills: skills.map { SkillEntry(name: $0) },
      mcpServers: servers.map { MCPServerEntry(name: $0.0, status: $0.1) })
  }

  /// The first reading of a list is not news.
  @Test func aFirstReadingMarksNothing() {
    let new = lists(["a"], [("s", .failed)])
    #expect(CapabilityChanges.diff(from: nil, to: new).isEmpty)
    #expect(CapabilityChanges.diff(from: ProjectCapabilities(), to: new).isEmpty)
  }

  @Test func marksAddedSkillsAndServersGoneWrong() {
    let old = lists(["a"], [("up", .connected), ("waiting", .pending), ("bad", .failed)])
    let new = lists(
      ["a", "b"],
      [
        ("up", .failed), ("waiting", .needsAuth), ("bad", .connected), ("fresh", .needsAuth),
        ("fine", .connected),
      ])
    let changes = CapabilityChanges.diff(from: old, to: new)
    #expect(changes.addedSkills == ["b"])
    // `waiting` was never connected, `bad` got better, `fine` is new and well: no mark.
    #expect(changes.worsenedServers == ["up", "fresh"])
  }

  @Test func aRemovedRowMarksNothing() {
    let changes = CapabilityChanges.diff(
      from: lists(["a", "b"], [("s", .connected)]), to: lists(["a"], []))
    #expect(changes.isEmpty)
  }

  // MARK: The probe's replies

  private func response(_ line: String) throws -> ControlResponse {
    guard case .controlResponse(let response) = try StreamMessage(line: Data(line.utf8)) else {
      Issue.record("not a control response: \(line)")
      throw CancellationError()
    }
    return response
  }

  @Test func collectsBothRepliesByTheirIDs() throws {
    var replies = CapabilityReplies(initializeID: "probe-init", statusID: "probe-mcp")
    for message in try Fixture.capabilities.messages {
      if case .controlResponse(let response) = message { replies.take(response) }
    }
    #expect(replies.isComplete)
    #expect(replies.capabilities.skills?.count == 4)
    #expect(replies.capabilities.mcpServers?.count == 7)
  }

  /// A session's own context reply, or anything else, is not the probe's.
  @Test func ignoresOtherReplies() throws {
    var replies = CapabilityReplies(initializeID: "probe-init", statusID: "probe-mcp")
    replies.take(
      try response(
        #"{"type":"control_response","response":{"subtype":"success","request_id":"context-1","response":{"commands":[]}}}"#
      ))
    #expect(!replies.hasInitialize)
    #expect(replies.capabilities == ProjectCapabilities())
  }

  /// An older CLI that refuses `mcp_status` answers with an error: kept, for the pane.
  @Test func anErrorAnswerIsKept() throws {
    var replies = CapabilityReplies(initializeID: "probe-init", statusID: "probe-mcp")
    replies.take(
      try response(
        #"{"type":"control_response","response":{"subtype":"error","request_id":"probe-mcp","error":"Unknown request subtype: mcp_status"}}"#
      ))
    #expect(replies.hasStatus)
    #expect(replies.capabilities.mcpServers == nil)
    #expect(replies.statusError == "Unknown request subtype: mcp_status")
  }
```

- [ ] **Step 2: Run them to see them fail**

Run: `make test`
Expected: the build fails: `cannot find 'CapabilityName' in scope`, `value of type
'SkillEntry' has no member 'matches'`, `cannot find 'CapabilityChanges' in scope`, `cannot
find 'CapabilityReplies' in scope`.

- [ ] **Step 3: Implement**

In `Capabilities.swift`, change the two decoders' returns to sort:

```swift
    return sorted(commands.compactMap(SkillEntry.init))
```

```swift
    return sorted(servers.compactMap(MCPServerEntry.init))
```

and append:

```swift
/// A plugin's skills and servers are namespaced: `superpowers:brainstorming`,
/// `plugin:stripe:stripe`. Rows show the namespace quieter than the name.
public enum CapabilityName {
  /// Everything before the last colon; nil without one, or when nothing follows it.
  public static func namespace(of name: String) -> String? {
    guard let colon = name.lastIndex(of: ":"), name.index(after: colon) != name.endIndex
    else { return nil }
    return String(name[..<colon])
  }

  /// What follows the last colon, or the whole name.
  public static func shortName(of name: String) -> String {
    guard namespace(of: name) != nil, let colon = name.lastIndex(of: ":") else { return name }
    return String(name[name.index(after: colon)...])
  }

  /// Case- and accent-insensitive, the query trimmed; a blank query matches everything.
  static func matches(_ query: String, in fields: [String]) -> Bool {
    let query = query.trimmingCharacters(in: .whitespaces)
    return query.isEmpty || fields.contains { $0.localizedStandardContains(query) }
  }
}

extension SkillEntry {
  public var namespace: String? { CapabilityName.namespace(of: name) }
  public var shortName: String { CapabilityName.shortName(of: name) }

  /// The description without the `(superpowers) ` the CLI puts ahead of a plugin's.
  public var displayDescription: String {
    guard let namespace, description.hasPrefix("(\(namespace)) ") else { return description }
    return String(description.dropFirst(namespace.count + 3))
  }

  public func matches(_ query: String) -> Bool {
    CapabilityName.matches(query, in: [name, description])
  }
}

extension MCPServerEntry {
  public var namespace: String? { CapabilityName.namespace(of: name) }
  public var shortName: String { CapabilityName.shortName(of: name) }

  /// Failed, or waiting for the person to sign in.
  public var isProblem: Bool { status == .failed || status == .needsAuth }

  public func matches(_ query: String) -> Bool {
    CapabilityName.matches(query, in: [name])
  }
}

extension MCPServerStatus {
  /// Failed first, then needing auth, then the rest.
  var rank: Int {
    switch self {
    case .failed: 0
    case .needsAuth: 1
    case .connected, .pending, .other: 2
    }
  }
}

extension ProjectCapabilities {
  /// Alphabetical by the name without its namespace, so `superpowers:brainstorming` sorts
  /// under b; the whole name breaks a tie.
  public static func sorted(_ skills: [SkillEntry]) -> [SkillEntry] {
    skills.sorted { a, b in
      switch a.shortName.localizedStandardCompare(b.shortName) {
      case .orderedAscending: true
      case .orderedDescending: false
      case .orderedSame: a.name < b.name
      }
    }
  }

  /// What needs the person first, alphabetical within each.
  public static func sorted(_ servers: [MCPServerEntry]) -> [MCPServerEntry] {
    servers.sorted { a, b in
      if a.status.rank != b.status.rank { return a.status.rank < b.status.rank }
      return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
  }
}

/// What a new reading of a project's lists brings that the person should see: skills that
/// were not there, and servers that went wrong.
public struct CapabilityChanges: Sendable, Equatable {
  public var addedSkills: [String]
  /// New and failed or needing auth, or connected before and not now.
  public var worsenedServers: [String]

  public init(addedSkills: [String] = [], worsenedServers: [String] = []) {
    self.addedSkills = addedSkills
    self.worsenedServers = worsenedServers
  }

  public var isEmpty: Bool { addedSkills.isEmpty && worsenedServers.isEmpty }

  /// A list read for the first time (`old` nil, or that list nil in it) marks nothing. A
  /// removed row and a status that got better mark nothing either.
  public static func diff(from old: ProjectCapabilities?, to new: ProjectCapabilities)
    -> CapabilityChanges
  {
    var changes = CapabilityChanges()
    if let before = old?.skills, let after = new.skills {
      let known = Set(before.map(\.name))
      changes.addedSkills = after.map(\.name).filter { !known.contains($0) }
    }
    if let before = old?.mcpServers, let after = new.mcpServers {
      let previous = Dictionary(
        before.map { ($0.name, $0.status) }, uniquingKeysWith: { first, _ in first })
      changes.worsenedServers = after.filter { server in
        guard let was = previous[server.name] else { return server.isProblem }
        return was == .connected && server.status != .connected
      }.map(\.name)
    }
    return changes
  }
}

/// The probe's two answers as they arrive, told apart by the request ids it sent.
public struct CapabilityReplies: Sendable, Equatable {
  public let initializeID: String
  public let statusID: String
  public private(set) var capabilities = ProjectCapabilities()
  public private(set) var hasInitialize = false
  public private(set) var hasStatus = false
  /// The CLI's error, when it answered a request with one.
  public private(set) var initializeError: String?
  public private(set) var statusError: String?

  public init(initializeID: String, statusID: String) {
    self.initializeID = initializeID
    self.statusID = statusID
  }

  public var isComplete: Bool { hasInitialize && hasStatus }

  public mutating func take(_ response: ControlResponse) {
    switch response.requestID {
    case initializeID:
      hasInitialize = true
      if response.isSuccess {
        capabilities.skills = ProjectCapabilities.skills(fromInitialize: response.response)
      } else {
        initializeError = response.error
      }
    case statusID:
      hasStatus = true
      if response.isSuccess {
        capabilities.mcpServers = ProjectCapabilities.servers(fromMCPStatus: response.response)
      } else {
        statusError = response.error
      }
    default:
      break
    }
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: PASS. If `sortsServersByWhatNeedsThePersonFirst` fails on the order of
"claude.ai Gmail" and "plugin:stripe:stripe", check `localizedStandardCompare` and not
`<` is used: the expected order is case-insensitive.

- [ ] **Step 5: Format and commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Packages/DrakarKit
git commit -m "feat(kit): skills and servers sorted, filtered and diffed, and the probe's two replies told apart"
```

---

### Task 3: One launch path, and the `initialize` reply handed on (app)

**Files:**
- Create: `Drakar/Services/ClaudeLaunch.swift`
- Modify: `Drakar/Services/ClaudeSession.swift` (in `spawn(unlessStoppedSince:)`, the block
  from `// A resume under the account that wrote it` to `executable = claude`; and `apply`)
- Create: `DrakarTests/ClaudeLaunchTests.swift`
- Modify: `DrakarTests/ClaudeSessionTests.swift`

**Interfaces:**
- Produces:
  - `struct ClaudeLaunch { var executable: URL?; var environment: [String: String]; var account: ClaudeAccount?; static func make(folder: URL, resuming: ResumeTarget?, environment: [String: String], executableOverride: URL?) -> ClaudeLaunch; static var notFound: String }`
  - `ClaudeSession.onInitialized: ((JSONValue?) -> Void)?`, called with the `initialize`
    reply's `response` when it succeeds.

- [ ] **Step 1: Write the failing tests**

`DrakarTests/ClaudeLaunchTests.swift`:

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// What a `claude` in a folder runs: the probe and a new session must agree on it.
@MainActor
@Suite("Starting claude for a folder")
struct ClaudeLaunchTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-launch-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  /// The folder's pick wins over Settings, and reaches the environment.
  @Test func runsUnderTheFoldersPick() throws {
    let picked = folder.appending(path: ".claude-picked", directoryHint: .isDirectory)
    let settings = folder.appending(path: ".claude-settings", directoryHint: .isDirectory)
    for directory in [picked, settings] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let suite = "drakar-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(settings.path(percentEncoded: false), forKey: PreferenceKey.newSessionAccount)
    defer { defaults.removePersistentDomain(forName: suite) }

    let launch = ClaudeChoice.$testSuite.withValue(suite) {
      ClaudeChoice.pick(ClaudeChoice.account(at: picked.path(percentEncoded: false)), for: folder)
      return ClaudeLaunch.make(
        folder: folder, resuming: nil, environment: ["PATH": "/usr/bin"],
        executableOverride: URL(filePath: "/bin/echo"))
    }
    #expect(launch.account?.name == "picked")
    #expect(launch.environment["CLAUDE_CONFIG_DIR"]?.hasSuffix(".claude-picked") == true)
    #expect(launch.environment["PATH"] == "/usr/bin")
    #expect(launch.executable == URL(filePath: "/bin/echo"))
  }

  /// A resume runs where it was written, whatever the folder's pick.
  @Test func aResumeRunsUnderItsOwnAccount() throws {
    let writer = folder.appending(path: ".claude-writer", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: writer, withIntermediateDirectories: true)
    let target = ResumeTarget(
      sessionID: "s", cwd: folder.path(percentEncoded: false),
      file: writer.appending(path: "s.jsonl").path(percentEncoded: false),
      accountDirectory: writer.path(percentEncoded: false), accountIsDefault: false)
    let launch = ClaudeLaunch.make(
      folder: folder, resuming: target, environment: [:],
      executableOverride: URL(filePath: "/bin/echo"))
    #expect(launch.account?.name == "writer")
    #expect(launch.environment["CLAUDE_CONFIG_DIR"]?.hasSuffix(".claude-writer") == true)
  }
}
```

`ClaudeLocator.locate` also searches fixed install folders under the real home, so a
"no `claude` found" case cannot be made from a test's PATH. It stays covered by the
message moving unchanged into `ClaudeLaunch.notFound`.

In `ClaudeSessionTests.swift`, after `theFirstPromptFollowsInitialize`:

```swift
  /// The `initialize` reply reaches whoever keeps the project's skills.
  @Test func handsOnTheInitializeReply() async throws {
    let reply =
      #"{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{"commands":[{"name":"check","description":"Fix it","argumentHint":""}]}}}"#
    let replying = folder.appending(path: "replying-claude")
    try Data("#!/bin/sh\nread line\necho '\(reply)'\ncat > /dev/null\n".utf8).write(to: replying)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replying.path)

    let session = ClaudeSession(folder: folder)
    session.executableOverride = replying
    var received: JSONValue?
    session.onInitialized = { received = $0 }
    await session.spawn()
    defer { session.stop() }
    for _ in 0..<50 where received == nil {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(ProjectCapabilities.skills(fromInitialize: received)?.map(\.name) == ["check"])
  }
```

- [ ] **Step 2: Run them to see them fail**

Run: `make test-app`
Expected: the build fails: `cannot find 'ClaudeLaunch' in scope` and `value of type
'ClaudeSession' has no member 'onInitialized'`.

- [ ] **Step 3: Write `ClaudeLaunch`**

`Drakar/Services/ClaudeLaunch.swift`:

```swift
import DrakarKit
import Foundation

/// What a `claude` started for a folder runs: the binary, the environment and the account,
/// as Settings and the folder's pick choose them. Sessions and the capability probe both
/// start from here, so the probe sees what a new session would.
struct ClaudeLaunch {
  /// Nil when no `claude` was found.
  var executable: URL?
  var environment: [String: String]
  /// The account it runs under, picked or the shell's.
  var account: ClaudeAccount?

  static var notFound: String {
    String(localized: "Claude Code was not found. Install it, then open the folder again.")
  }

  /// `environment` is the login shell's (`ClaudeSession.environment`). A resume runs under
  /// the account that wrote it; a new session under its folder's pick, else the one in
  /// Settings, else the shell's.
  static func make(
    folder: URL, resuming: ResumeTarget?, environment: [String: String],
    executableOverride: URL?
  ) -> ClaudeLaunch {
    var environment = environment
    let chosen = resuming?.account ?? ClaudeChoice.account(forNewSessionIn: folder)
    if let chosen { environment = chosen.environment(environment) }
    let account =
      chosen
      ?? ClaudeChoice.account(
        at: environment["CLAUDE_CONFIG_DIR"]
          ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
          .path(percentEncoded: false))
    let executable =
      executableOverride
      ?? ClaudeLocator.locate(preferred: ClaudeChoice.executable, path: environment["PATH"])
    return ClaudeLaunch(executable: executable, environment: environment, account: account)
  }
}
```

- [ ] **Step 4: Spawn through it**

In `ClaudeSession.spawn(unlessStoppedSince:)`, replace from the comment `// A resume under
the account that wrote it; a new session under its folder's pick, else` down to and
including `executable = claude` with:

```swift
    let launch = ClaudeLaunch.make(
      folder: folder, resuming: resuming, environment: environment,
      executableOverride: executableOverride)
    environment = launch.environment
    account = launch.account
    guard let claude = launch.executable else { return fail(ClaudeLaunch.notFound) }
    executable = claude
```

The order is the same as before: the account is set even when no `claude` is found.

- [ ] **Step 5: Hand on the reply**

Add beside the other callbacks in `ClaudeSession`:

```swift
  /// The process answered `initialize`: its reply, which lists the skills.
  @ObservationIgnored var onInitialized: ((JSONValue?) -> Void)?
```

In `apply(_:)`, before the `if case .controlResponse(let response) = message,
response.requestID.hasPrefix("context-")` block:

```swift
    if case .controlResponse(let response) = message, response.requestID.hasPrefix("init-"),
      response.isSuccess
    {
      onInitialized?(response.response)
    }
```

No `return`: the message goes on to `transcript.apply` as it did before.

- [ ] **Step 6: Run the tests**

Run: `make test-app`
Expected: PASS, including the existing `runsTheClaudeAndAccountPickedInSettings`, which
guards that the refactor kept the session's account and executable.

- [ ] **Step 7: Format and commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests
git commit -m "feat(apple): a session starts from one launch path, and hands its initialize reply on"
```

---

### Task 4: The probe (app)

**Files:**
- Create: `Drakar/Services/CapabilityProbe.swift`
- Create: `DrakarTests/CapabilityProbeTests.swift`

**Interfaces:**
- Consumes: `ClaudeLaunch.make`, `ClaudeLaunch.notFound`, `ClaudeSession.environment`,
  `CapabilityReplies`, `ClientMessage.mcpStatus`.
- Produces:
  - `struct ProbeOutcome: Equatable { var capabilities: ProjectCapabilities; var skillsProblem: String?; var serversProblem: String?; var diagnostics: String; static func failed(_ reason: String) -> ProbeOutcome }`
  - `enum CapabilityProbe { static let initializeID = "probe-init"; static let statusID = "probe-mcp"; static func run(folder: URL, executableOverride: URL? = nil, timeout: Duration = .seconds(20), grace: Duration = .seconds(2)) async -> ProbeOutcome }`.
    Cancelling the calling task lets the process go: input closed, terminated after `grace`.

- [ ] **Step 1: Write the failing tests**

`DrakarTests/CapabilityProbeTests.swift`:

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

/// The probe against stand-in `claude`s: scripts that answer, stall or fail.
@MainActor
@Suite("Asking a project's claude what it would load")
struct CapabilityProbeTests {

  private let folder: URL

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func standIn(_ body: String) throws -> URL {
    let script = folder.appending(path: "claude")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  private let initialize =
    #"{"type":"control_response","response":{"subtype":"success","request_id":"probe-init","response":{"commands":[{"name":"check","description":"Fix it","argumentHint":""},{"name":"compact","description":"","argumentHint":"","builtin":true}]}}}"#
  private let status =
    #"{"type":"control_response","response":{"subtype":"success","request_id":"probe-mcp","response":{"mcpServers":[{"name":"armada","status":"connected","config":{"headers":{"Authorization":"Bearer x"}}}]}}}"#

  /// Both replies, then the input closes: the stand-in's `cat` ends and it runs to its end,
  /// which is how the real CLI takes its registry entry down.
  @Test func readsBothRepliesThenLetsTheProcessGo() async throws {
    let claude = try standIn(
      "read a\nread b\necho '\(initialize)'\necho '\(status)'\ncat > /dev/null\ntouch \"$0.ended\"")
    let outcome = await CapabilityProbe.run(folder: folder, executableOverride: claude)
    #expect(outcome.capabilities.skills?.map(\.name) == ["check"])
    #expect(outcome.capabilities.mcpServers?.map(\.name) == ["armada"])
    #expect(outcome.skillsProblem == nil)
    #expect(outcome.serversProblem == nil)
    #expect(exists(claude.appendingPathExtension("ended")))
  }

  /// An older CLI that never answers `mcp_status`: the skills are kept, the servers pane
  /// says why.
  @Test func keepsTheSkillsWhenTheStatusNeverComes() async throws {
    let claude = try standIn("read a\necho '\(initialize)'\nexec sleep 30")
    let outcome = await CapabilityProbe.run(
      folder: folder, executableOverride: claude, timeout: .seconds(1), grace: .milliseconds(200))
    #expect(outcome.capabilities.skills?.map(\.name) == ["check"])
    #expect(outcome.skillsProblem == nil)
    #expect(
      outcome.serversProblem == "Couldn't read MCP status. Claude Code took too long to answer.")
  }

  @Test func saysWhyWhenTheProcessFails() async throws {
    let claude = try standIn("read a\necho 'not signed in' >&2\nexit 1")
    let outcome = await CapabilityProbe.run(folder: folder, executableOverride: claude)
    #expect(outcome.capabilities == ProjectCapabilities())
    #expect(outcome.skillsProblem == "Couldn't read skills. Claude Code exited with status 1.")
    #expect(
      outcome.serversProblem == "Couldn't read MCP status. Claude Code exited with status 1.")
    #expect(outcome.diagnostics.contains("not signed in"))
  }

  @Test func saysWhenTheFolderIsGone() async {
    let gone = folder.appending(path: "gone", directoryHint: .isDirectory)
    let outcome = await CapabilityProbe.run(folder: gone)
    #expect(outcome.skillsProblem == "The folder gone no longer exists.")
    #expect(outcome.serversProblem == "The folder gone no longer exists.")
  }

  /// A window closed mid-probe: input closed first, so the CLI can exit on its own.
  @Test func aCancelledProbeLetsTheProcessGo() async throws {
    let claude = try standIn("cat > /dev/null\ntouch \"$0.closed\"\nexec sleep 30")
    let closed = claude.appendingPathExtension("closed")
    let probe = Task {
      await CapabilityProbe.run(
        folder: folder, executableOverride: claude, grace: .milliseconds(200))
    }
    try await Task.sleep(for: .milliseconds(300))
    probe.cancel()
    _ = await probe.value
    for _ in 0..<40 where !exists(closed) {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(exists(closed))
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `make test-app`
Expected: the build fails: `cannot find 'CapabilityProbe' in scope`.

- [ ] **Step 3: Write the probe**

`Drakar/Services/CapabilityProbe.swift`:

```swift
import DrakarKit
import Foundation

/// What one probe read, and what each pane says about what it did not.
struct ProbeOutcome: Equatable {
  var capabilities = ProjectCapabilities()
  /// Why the skills are missing; nil when they arrived.
  var skillsProblem: String?
  var serversProblem: String?
  /// The end of the CLI's stderr.
  var diagnostics = ""

  static func failed(_ reason: String) -> ProbeOutcome {
    ProbeOutcome(skillsProblem: reason, serversProblem: reason)
  }
}

/// A `claude` started in a project's folder only to be asked what it would load, then let
/// go: `initialize` and `mcp_status`, no prompt, no transcript
/// (docs/claude-stream-json.md, "Skills and MCP status").
enum CapabilityProbe {
  static let initializeID = "probe-init"
  static let statusID = "probe-mcp"

  /// What a new session in `folder` would load. Cancelling the calling task lets the
  /// process go as a finished probe does.
  static func run(
    folder: URL, executableOverride: URL? = nil, timeout: Duration = .seconds(20),
    grace: Duration = .seconds(2)
  ) async -> ProbeOutcome {
    guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else {
      return .failed(
        String(localized: "The folder \(folder.lastPathComponent) no longer exists."))
    }
    let launch = ClaudeLaunch.make(
      folder: folder, resuming: nil, environment: await ClaudeSession.environment.value,
      executableOverride: executableOverride)
    guard let executable = launch.executable else { return .failed(ClaudeLaunch.notFound) }
    let process = AgentProcess(
      .init(
        executable: executable,
        arguments: ClaudeCommand(includesPartialMessages: false).arguments,
        environment: launch.environment, currentDirectory: folder))
    return await withTaskCancellationHandler {
      await collect(from: process, timeout: timeout, grace: grace)
    } onCancel: {
      release(process, after: grace)
    }
  }

  private static func collect(
    from process: AgentProcess, timeout: Duration, grace: Duration
  ) async -> ProbeOutcome {
    let events: AsyncStream<AgentProcess.Event>
    do {
      events = try process.start()
      try process.send(.initialize(requestID: initializeID))
      try process.send(.mcpStatus(requestID: statusID))
    } catch {
      process.terminate()
      return .failed(error.localizedDescription)
    }
    let deadline = ContinuousClock.now + timeout
    let timer = Task {
      try? await Task.sleep(for: timeout)
      if !Task.isCancelled { release(process, after: grace) }
    }
    defer { timer.cancel() }
    var replies = CapabilityReplies(initializeID: initializeID, statusID: statusID)
    var diagnostics = ""
    var status: Int32?
    for await event in events {
      switch event {
      case .messages(let messages):
        for case .controlResponse(let response) in messages { replies.take(response) }
        if replies.isComplete { release(process, after: grace) }
      case .stderr(let text):
        diagnostics = String((diagnostics + text).suffix(4000))
      case .exited(let code, _):
        status = code
      }
    }
    let reason =
      if ContinuousClock.now >= deadline {
        String(localized: "Claude Code took too long to answer.")
      } else if let status, status != 0 {
        String(localized: "Claude Code exited with status \(status).")
      } else {
        String(localized: "Claude Code stopped before it answered.")
      }
    return outcome(replies, reason: reason, diagnostics: diagnostics)
  }

  /// Each pane's list, or why it has none: the CLI's error, a reply without the list, or
  /// no reply at all.
  static func outcome(_ replies: CapabilityReplies, reason: String, diagnostics: String)
    -> ProbeOutcome
  {
    var outcome = ProbeOutcome(capabilities: replies.capabilities, diagnostics: diagnostics)
    if replies.capabilities.skills == nil {
      outcome.skillsProblem =
        replies.hasInitialize
        ? replies.initializeError
          ?? String(localized: "This Claude Code version didn't list skills.")
        : String(localized: "Couldn't read skills. \(reason)")
    }
    if replies.capabilities.mcpServers == nil {
      outcome.serversProblem =
        replies.hasStatus
        ? replies.statusError
          ?? String(localized: "This Claude Code version didn't list MCP servers.")
        : String(localized: "Couldn't read MCP status. \(reason)")
    }
    return outcome
  }

  /// Input closed first, so the CLI exits on its own and takes its registry entry with it;
  /// terminated only if it is still there after `grace`. Safe to call more than once.
  nonisolated static func release(_ process: AgentProcess, after grace: Duration) {
    process.closeInput()
    Task.detached {
      try? await Task.sleep(for: grace)
      process.terminate()
    }
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `make test-app`
Expected: PASS. The suite takes about 2 s: the timeout test waits its 1 s.

- [ ] **Step 5: Format and commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests
git commit -m "feat(apple): a probe asks a project's claude for its skills and servers, then lets it go"
```

---

### Task 5: The lists kept per folder and account (app)

**Files:**
- Create: `Drakar/Services/Capabilities.swift`
- Create: `DrakarTests/CapabilityStoreTests.swift`

**Interfaces:**
- Consumes: `ProbeOutcome`, `CapabilityProbe.run`, `CapabilityChanges.diff`.
- Produces:
  - `@Observable final class Capabilities { let folder: URL; let accountKey: String; init(folder:accountKey:); private(set) var lists: ProjectCapabilities; skillsProblem, serversProblem: String?; diagnostics: String; isLoading, hasLoaded: Bool; var probe: (URL) async -> ProbeOutcome; func loadIfNeeded(); func refresh(); func refreshIfLoaded(); func cancel(); func sessionReported(skills: [SkillEntry]); func observe(_ handler: @escaping (CapabilityChanges) -> Void) -> UUID; func stopObserving(_ id: UUID) }`
  - `final class CapabilityStore { static let shared; func capabilities(for folder: URL, account: ClaudeAccount) -> Capabilities }`

- [ ] **Step 1: Write the failing tests**

`DrakarTests/CapabilityStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run them to see them fail**

Run: `make test-app`
Expected: the build fails: `cannot find 'Capabilities' in scope`.

- [ ] **Step 3: Implement**

`Drakar/Services/Capabilities.swift`:

```swift
import DrakarKit
import Foundation
import Observation

/// One project's skills and MCP servers under one account, as its `claude` would load them:
/// read by a probe, refreshed by the project's own sessions, kept for the launch and never
/// on disk. Every window on the folder shares it.
@Observable
final class Capabilities {
  let folder: URL
  /// `ClaudeAccount.key` of the account probed.
  let accountKey: String
  /// The last lists read; a failed reload leaves them.
  private(set) var lists = ProjectCapabilities()
  /// Why the last reading has no skills, or no servers.
  private(set) var skillsProblem: String?
  private(set) var serversProblem: String?
  private(set) var diagnostics = ""
  private(set) var isLoading = false
  private(set) var hasLoaded = false

  /// Stands in for the probe, in tests.
  @ObservationIgnored var probe: (URL) async -> ProbeOutcome = {
    await CapabilityProbe.run(folder: $0)
  }
  @ObservationIgnored private var running: Task<Void, Never>?
  @ObservationIgnored private var rerun = false
  @ObservationIgnored private var observers: [UUID: (CapabilityChanges) -> Void] = [:]

  init(folder: URL, accountKey: String) {
    self.folder = folder
    self.accountKey = accountKey
  }

  /// The first time a window shows the project.
  func loadIfNeeded() {
    guard !hasLoaded, running == nil else { return }
    refresh()
  }

  /// A probe now, or, while one runs, once more after it however often this is asked.
  func refresh() {
    if running != nil {
      rerun = true
      return
    }
    running = Task { await self.runProbes() }
  }

  /// For a file change: only lists something already asked for.
  func refreshIfLoaded() {
    guard hasLoaded || running != nil else { return }
    refresh()
  }

  /// The last window on the folder closed: its probe goes with it.
  func cancel() {
    running?.cancel()
    running = nil
    rerun = false
    isLoading = false
  }

  /// A session in the project's own folder answered `initialize`: its skills are current.
  func sessionReported(skills: [SkillEntry]) {
    skillsProblem = nil
    replace(ProjectCapabilities(skills: skills, mcpServers: lists.mcpServers))
  }

  /// `handler` hears what each new reading changed (`CapabilityChanges`), never the first.
  func observe(_ handler: @escaping (CapabilityChanges) -> Void) -> UUID {
    let id = UUID()
    observers[id] = handler
    return id
  }

  func stopObserving(_ id: UUID) {
    observers[id] = nil
  }

  private func runProbes() async {
    isLoading = true
    repeat {
      rerun = false
      let outcome = await probe(folder)
      if Task.isCancelled { return }
      apply(outcome)
    } while rerun
    isLoading = false
    running = nil
  }

  private func apply(_ outcome: ProbeOutcome) {
    var next = lists
    if let skills = outcome.capabilities.skills { next.skills = skills }
    if let servers = outcome.capabilities.mcpServers { next.mcpServers = servers }
    skillsProblem = outcome.skillsProblem
    serversProblem = outcome.serversProblem
    diagnostics = outcome.diagnostics
    hasLoaded = true
    replace(next)
  }

  private func replace(_ next: ProjectCapabilities) {
    let changes = CapabilityChanges.diff(from: lists, to: next)
    lists = next
    guard !changes.isEmpty else { return }
    for handler in observers.values { handler(changes) }
  }
}

/// Every project's `Capabilities`, by folder (as `ProjectPath.normalize` writes it) and
/// account: another account has other user skills and servers.
final class CapabilityStore {
  static let shared = CapabilityStore()

  private var entries: [String: Capabilities] = [:]

  func capabilities(for folder: URL, account: ClaudeAccount) -> Capabilities {
    let path = ProjectPath.normalize(folder.path(percentEncoded: false))
    let key = path + "\n" + account.key
    if let entry = entries[key] { return entry }
    let entry = Capabilities(
      folder: URL(filePath: path, directoryHint: .isDirectory), accountKey: account.key)
    entries[key] = entry
    return entry
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `make test-app`
Expected: PASS. If `oneEntryPerFolderAndAccount` fails on the trailing-slash case, check
`ProjectPath.normalize` drops a trailing slash. It does per `SessionRoute.swift`'s
comment, so the key building is what to look at.

- [ ] **Step 5: Format and commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests
git commit -m "feat(apple): a project's skills and servers are kept per folder and account, one probe at a time"
```

---

### Task 6: Running a skill (app)

**Files:**
- Modify: `Drakar/Services/Project.swift`
- Modify: `Drakar/Views/ComposerView.swift`
- Modify: `Drakar/Views/SessionView.swift:25-36`
- Create: `DrakarTests/SkillRunTests.swift`

**Interfaces:**
- Consumes: `SkillEntry` (`name`, `argumentHint`, `takesArguments`).
- Produces:
  - `struct SkillPrefill: Equatable { var text: String; var hint: String }`
  - `ProjectSession.prefill: SkillPrefill?`, `.focusRequest: Int`, `.composerHint: String?`
  - `enum SkillTarget { case newSession, current }` (top level in `Project.swift`)
  - `Project.canRun(in: SkillTarget) -> Bool`, `Project.run(_ skill: SkillEntry, in: SkillTarget)`
  - `Project.executableOverride: URL?` (test seam, copied onto every session `make` creates)
  - `ComposerView(…, hint: String? = nil, focusRequest: Int = 0)`

- [ ] **Step 1: Write the failing tests**

`DrakarTests/SkillRunTests.swift`:

```swift
import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("Running a skill from the inspector")
struct SkillRunTests {

  private let folder: URL
  private let check = SkillEntry(name: "check", description: "Fix it")
  private let audit = SkillEntry(
    name: "marketing:seo-audit", description: "Audit", argumentHint: "<url or topic>")

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-skill-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func standIn() throws -> URL {
    let script = folder.appending(path: "claude")
    try Data("#!/bin/sh\ncat > /dev/null\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  /// A skill that takes nothing goes at once, in a new session on top.
  @Test func aSkillWithoutArgumentsIsSentInANewSession() throws {
    let project = Project(folder: folder)
    project.executableOverride = try standIn()
    let first = project.newSession()
    project.run(check, in: .newSession)
    defer { project.stopAll() }
    #expect(project.sessions.count == 2)
    let item = try #require(project.selected)
    #expect(item.id != first.id)
    #expect(item.displayTitle == "/check")
    #expect(item.session.transcript.isRunning)
  }

  /// One that takes arguments waits in the composer, with what it takes shown.
  @Test func aSkillWithArgumentsWaitsInTheComposer() throws {
    let project = Project(folder: folder)
    project.run(audit, in: .newSession)
    let item = try #require(project.selected)
    #expect(item.draft == "/marketing:seo-audit ")
    #expect(item.composerHint == "<url or topic>")
    #expect(item.focusRequest == 1)
    #expect(!item.session.isProcessRunning)
    #expect(item.session.transcript.entries.isEmpty)
  }

  /// The hint stays while arguments are typed after the name, and goes once the name is
  /// edited away.
  @Test func theHintFollowsTheName() throws {
    let project = Project(folder: folder)
    project.run(audit, in: .newSession)
    let item = try #require(project.selected)
    item.draft = "/marketing:seo-audit example.com"
    #expect(item.composerHint == "<url or topic>")
    item.draft = "/marketing:seo-aud"
    #expect(item.composerHint == nil)
  }

  /// In the current session a draft already typed is kept, after the name.
  @Test func theCurrentSessionKeepsItsDraft() throws {
    let project = Project(folder: folder)
    let item = project.newSession()
    item.draft = "the login page"
    project.run(audit, in: .current)
    #expect(project.sessions.count == 1)
    #expect(item.draft == "/marketing:seo-audit the login page")
    #expect(item.composerHint == "<url or topic>")
  }

  /// A session that cannot take a prompt cannot take a skill: refused, not queued.
  @Test func aReadOnlySessionCannotRunOne() throws {
    let project = Project(folder: folder)
    let item = project.newSession()
    item.session.isReadOnly = true
    #expect(!project.canRun(in: .current))
    #expect(project.canRun(in: .newSession))
    project.run(audit, in: .current)
    #expect(item.draft.isEmpty)
    #expect(project.sessions.count == 1)
  }

  @Test func aSessionMidTurnCannotRunOne() async throws {
    let project = Project(folder: folder)
    project.executableOverride = try standIn()
    let item = project.newSession()
    item.session.send("working")
    defer { project.stopAll() }
    #expect(item.session.transcript.isRunning)
    #expect(!project.canRun(in: .current))
  }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `make test-app`
Expected: the build fails: `value of type 'Project' has no member 'run'` (and
`executableOverride`, `canRun`, `composerHint`, `focusRequest`).

- [ ] **Step 3: Implement in `Project.swift`**

Above `final class ProjectSession`, add:

```swift
/// A skill put in the composer rather than sent: the text it put there, and what it takes.
struct SkillPrefill: Equatable {
  var text: String
  var hint: String
}

/// Where the inspector runs a skill.
enum SkillTarget {
  case newSession
  case current
}
```

In `ProjectSession`, after `var draft = ""`:

```swift
  /// The skill the inspector put in the draft, while it waits for its arguments.
  var prefill: SkillPrefill?
  /// Bumped to ask the composer for the focus.
  var focusRequest = 0

  /// What the prefilled skill takes, while the draft still starts with its name.
  var composerHint: String? {
    guard let prefill, draft.hasPrefix(prefill.text) else { return nil }
    return prefill.hint
  }
```

In `Project`, after `@ObservationIgnored private(set) var focusesComposer = true`:

```swift
  /// Stands in for the located binary in every session this window makes, in tests.
  @ObservationIgnored var executableOverride: URL?
```

After `newSession()`:

```swift
  /// Whether a skill can go to `target`: a new session always can; the shown one only when
  /// it could take a prompt now (not read-only, not mid-turn).
  func canRun(in target: SkillTarget) -> Bool {
    switch target {
    case .newSession: true
    case .current: selected?.session.canSend == true
    }
  }

  /// A skill from the inspector: sent at once when it takes nothing, otherwise put at the
  /// start of the composer with what it takes shown, the focus there.
  func run(_ skill: SkillEntry, in target: SkillTarget) {
    guard canRun(in: target) else { return }
    let item: ProjectSession
    switch target {
    case .newSession: item = newSession()
    case .current:
      guard let selected else { return }
      item = selected
    }
    if skill.takesArguments {
      let text = "/\(skill.name) "
      item.draft = text + item.draft
      item.prefill = SkillPrefill(text: text, hint: skill.argumentHint)
      item.focusRequest += 1
    } else {
      takeOver(item)
      item.session.send("/\(skill.name)")
    }
  }
```

In `make(_:)`, first line of the body:

```swift
    if let executableOverride { session.executableOverride = executableOverride }
```

- [ ] **Step 4: The composer's hint line and focus request**

In `ComposerView`, after `var takesFocus = true`:

```swift
  /// What the skill at the start of the draft takes, shown above the field: a
  /// `TextField`'s placeholder only shows while it is empty.
  var hint: String? = nil
  /// A change asks for the focus: the inspector put a skill in the draft.
  var focusRequest = 0
```

In `body`, as the first child of the `VStack`, before `if !pinned.isEmpty || live != nil`:

```swift
      if let hint {
        Label(hint, systemImage: "text.cursor")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .help("What this skill takes after its name")
          .accessibilityIdentifier("composer.hint")
      }
```

and after `.onAppear { if takesFocus { isFocused = true } }`:

```swift
    .onChange(of: focusRequest) { isFocused = true }
```

In `SessionView.swift`, in the `ComposerView(` call, after
`takesFocus: project.focusesComposer`:

```swift
          takesFocus: project.focusesComposer,
          hint: item.composerHint, focusRequest: item.focusRequest)
```

(replacing the closing `takesFocus: project.focusesComposer)`).

- [ ] **Step 5: Run the tests**

Run: `make test-app`
Expected: PASS, the existing `ProjectTests` included.

- [ ] **Step 6: Format and commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests
git commit -m "feat(apple): a skill runs in a new or the current session, sent at once or waiting for its arguments"
```

---

### Task 7: The project's lists: binding, marks, sessions, files, closing (app)

**Files:**
- Modify: `Drakar/Services/Capabilities.swift` (add `CapabilityMarks` and the labels)
- Modify: `Drakar/Services/Project.swift`
- Modify: `Drakar/Services/Workspace.swift` (`filesChanged`, a callback, a static filter)
- Modify: `DrakarTests/SkillRunTests.swift` (marks, sessions, closing)
- Modify: `DrakarTests/CapabilityStoreTests.swift` (file filter, labels)

**Interfaces:**
- Consumes: `Capabilities`, `CapabilityStore`, `ClaudeSession.onInitialized`,
  `AccountStore.shared.windowAccount(for:)`, `ProjectCapabilities.skills(fromInitialize:)`.
- Produces:
  - `struct CapabilityMarks: Equatable { var skills: Set<String>; var servers: Set<String>; var isEmpty: Bool; mutating func add(_: CapabilityChanges); func summary(servers: [MCPServerEntry]) -> String }`
  - `extension MCPServerStatus { var label: String }`; `enum MCPSourceLabel { static func text(_ source: String?) -> String? }`
  - `Project.capabilities: Capabilities`, `Project.capabilityMarks: CapabilityMarks`,
    `Project.clearCapabilityMarks()`, `Project.unmarkServer(_ name: String)`,
    `Project.accountMayHaveChanged()`, `Project.speaksForProject(_ session: ClaudeSession) -> Bool`,
    `Project.capabilityDebounce: Duration` (2 s; tests shorten it)
  - `Workspace.onCapabilityFilesChanged: (() -> Void)?`,
    `static func touchesCapabilities(_ paths: [String], root: String) -> Bool`
  - `Project.run` also clears the skill's mark; `stopAll()` releases the lists.

- [ ] **Step 1: Write the failing tests**

Append to `CapabilityStoreTests`:

```swift
  /// What the CLI reads skills, commands and servers from, in the project itself.
  @Test func knowsWhichFilesChangeTheLists() {
    let root = "/p"
    #expect(Workspace.touchesCapabilities(["/p/.mcp.json"], root: root))
    #expect(Workspace.touchesCapabilities(["/p/.claude/skills/x/SKILL.md"], root: root))
    #expect(Workspace.touchesCapabilities(["/p/.claude/skills"], root: root))
    #expect(Workspace.touchesCapabilities(["/p/.claude/commands/deploy.md"], root: root))
    #expect(Workspace.touchesCapabilities(["/p/.claude/settings.json"], root: root))
    #expect(Workspace.touchesCapabilities(["/p/.claude/settings.local.json"], root: root))
    #expect(!Workspace.touchesCapabilities(["/p/.claude/worktrees/a/.mcp.json"], root: root))
    #expect(!Workspace.touchesCapabilities(["/p/sub/.mcp.json"], root: root))
    #expect(!Workspace.touchesCapabilities(["/p/src/main.swift"], root: root))
    #expect(!Workspace.touchesCapabilities(["/other/.mcp.json"], root: root))
  }

  @Test func summarisesMarksForTheToolbar() {
    var marks = CapabilityMarks()
    marks.add(CapabilityChanges(addedSkills: ["a", "b"], worsenedServers: ["github"]))
    let servers = [MCPServerEntry(name: "github", status: .failed)]
    #expect(marks.summary(servers: servers) == "2 new skills · github: Failed")
    var one = CapabilityMarks()
    one.add(CapabilityChanges(addedSkills: ["a"]))
    #expect(one.summary(servers: []) == "1 new skill")
  }
```

Append to `SkillRunTests`:

```swift
  private func settle(_ entry: Capabilities) async throws {
    for _ in 0..<100 where entry.isLoading {
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  /// A window marks what a new reading brought; running the skill, or hiding the inspector,
  /// clears it.
  @Test func marksFollowTheLists() async throws {
    let project = Project(folder: folder)
    let entry = project.capabilities
    entry.probe = { _ in ProbeOutcome(capabilities: ProjectCapabilities(skills: [], mcpServers: [])) }
    entry.refresh()
    try await settle(entry)
    #expect(project.capabilityMarks.isEmpty)
    entry.probe = { _ in
      ProbeOutcome(
        capabilities: ProjectCapabilities(
          skills: [self.audit], mcpServers: [MCPServerEntry(name: "github", status: .failed)]))
    }
    entry.refresh()
    try await settle(entry)
    #expect(project.capabilityMarks.skills == [audit.name])
    #expect(project.capabilityMarks.servers == ["github"])
    project.run(audit, in: .newSession)
    #expect(project.capabilityMarks.skills.isEmpty)
    project.unmarkServer("github")
    #expect(project.capabilityMarks.isEmpty)
  }

  /// A worktree is another checkout: its session does not speak for the project's list.
  @Test func onlyTheProjectsOwnFolderSpeaksForIt() {
    let project = Project(folder: folder)
    let worktree = ClaudeSession(
      folder: folder.appending(path: ".claude/worktrees/x", directoryHint: .isDirectory))
    #expect(!project.speaksForProject(worktree))
  }

  /// A session started in the project's folder, under the window's account, brings its
  /// skills to the inspector.
  @Test func aSessionsInitializeReplyRefreshesTheSkills() async throws {
    let reply =
      #"{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{"commands":[{"name":"fresh","description":"","argumentHint":""}]}}}"#
    let script = folder.appending(path: "claude")
    try Data("#!/bin/sh\nread line\necho '\(reply)'\ncat > /dev/null\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let project = Project(folder: folder)
    project.executableOverride = script
    let item = project.newSession()
    defer { project.stopAll() }
    await item.session.spawn()
    for _ in 0..<50 where project.capabilities.lists.skills == nil {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(project.speaksForProject(item.session))
    #expect(project.capabilities.lists.skills?.map(\.name) == ["fresh"])
  }

  /// The last window on a folder closing takes its probe with it.
  @Test func closingTheWindowCancelsItsProbe() async throws {
    let project = Project(folder: folder)
    let entry = project.capabilities
    entry.probe = { _ in
      try? await Task.sleep(for: .seconds(5))
      return ProbeOutcome()
    }
    entry.refresh()
    #expect(entry.isLoading)
    project.stopAll()
    #expect(!entry.isLoading)
  }

  /// A change to the project's `.claude/skills` reads the lists again, once, after the
  /// changes settle.
  @Test func aSkillFileChangeRefreshesOnceSettled() async throws {
    let project = Project(folder: folder)
    project.capabilityDebounce = .milliseconds(100)
    let entry = project.capabilities
    let calls = CapabilityStoreTests.Calls()
    entry.probe = { _ in
      calls.count += 1
      return ProbeOutcome(capabilities: ProjectCapabilities(skills: [], mcpServers: []))
    }
    entry.refresh()
    try await settle(entry)
    let skill = folder.appending(path: ".claude/skills/x", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try Data("---\nname: x\n---\n".utf8).write(to: skill.appending(path: "SKILL.md"))
    for _ in 0..<50 where calls.count < 2 {
      try await Task.sleep(for: .milliseconds(100))
    }
    try await settle(entry)
    #expect(calls.count == 2)
  }
```

`aSessionsInitializeReplyRefreshesTheSkills` relies on the session's account and the
window's account having the same key. Both come from `ClaudeChoice.account(forNewSessionIn:)`
with no pick, else the shell's. If it fails only on that check, print both keys before
changing anything. The session takes the shell's from `CLAUDE_CONFIG_DIR` and the store from
`AccountStore.shared.shellAccount`. A mismatch there is a real bug to fix in
`speaksForProject`, comparing `ClaudeAccount.key`s the same way on both sides; never delete
the check.

- [ ] **Step 2: Run them to see them fail**

Run: `make test-app`
Expected: the build fails: `cannot find 'CapabilityMarks' in scope`, `type 'Workspace' has
no member 'touchesCapabilities'`, `value of type 'Project' has no member 'capabilities'`.

- [ ] **Step 3: Marks and labels**

Append to `Drakar/Services/Capabilities.swift`:

```swift
/// What a window's lists brought since the inspector was last seen: the rows with a dot,
/// and the toolbar button's dot while the inspector is hidden. Per window, so one tab
/// having seen a change does not clear it in another.
struct CapabilityMarks: Equatable {
  var skills: Set<String> = []
  var servers: Set<String> = []

  var isEmpty: Bool { skills.isEmpty && servers.isEmpty }

  mutating func add(_ changes: CapabilityChanges) {
    skills.formUnion(changes.addedSkills)
    servers.formUnion(changes.worsenedServers)
  }

  /// "2 new skills · github: Failed", for the toolbar button's tooltip.
  func summary(servers entries: [MCPServerEntry]) -> String {
    var parts: [String] = []
    if !skills.isEmpty {
      parts.append(
        skills.count == 1
          ? String(localized: "1 new skill") : String(localized: "\(skills.count) new skills"))
    }
    for name in servers.sorted() {
      let status = entries.first { $0.name == name }?.status.label
      parts.append(status.map { "\(name): \($0)" } ?? name)
    }
    return parts.joined(separator: " · ")
  }
}

extension MCPServerStatus {
  var label: String {
    switch self {
    case .connected: String(localized: "Connected")
    case .needsAuth: String(localized: "Needs authentication")
    case .failed: String(localized: "Failed")
    case .pending: String(localized: "Connecting")
    case .other(let raw): raw
    }
  }
}

/// Where a server is configured, as a row says it.
enum MCPSourceLabel {
  static func text(_ source: String?) -> String? {
    switch source {
    case nil: nil
    case "user": String(localized: "User")
    case "project": String(localized: "Project")
    case "local": String(localized: "Local")
    case "plugin": String(localized: "Plugin")
    case "claudeai": String(localized: "claude.ai")
    case let other?: other
    }
  }
}
```

- [ ] **Step 4: The watcher's filter**

In `Workspace`, after `@ObservationIgnored var closeGuard: WindowCloseGuard?`:

```swift
  /// A file the project's skills, commands or servers are read from changed.
  @ObservationIgnored var onCapabilityFilesChanged: (() -> Void)?
```

In `filesChanged(_:)`, after `guard !paths.isEmpty else { return }`:

```swift
    if Self.touchesCapabilities(paths, root: tree.root) { onCapabilityFilesChanged?() }
```

and after `filesChanged(_:)`:

```swift
  /// What the CLI reads from the project itself: `.mcp.json`, and `.claude/skills/`,
  /// `.claude/commands/` and `.claude/settings*.json`. A worktree's copies are another
  /// checkout's, and a subfolder's `.mcp.json` is not the project's.
  static func touchesCapabilities(_ paths: [String], root: String) -> Bool {
    paths.contains { path in
      guard path.hasPrefix(root + "/") else { return false }
      let relative = path.dropFirst(root.count + 1)
      if relative == ".mcp.json" { return true }
      for folder in [".claude/skills", ".claude/commands"]
      where relative == folder || relative.hasPrefix(folder + "/") {
        return true
      }
      let inClaude = relative.hasPrefix(".claude/") ? relative.dropFirst(".claude/".count) : ""
      return inClaude.hasPrefix("settings") && inClaude.hasSuffix(".json")
        && !inClaude.contains("/")
    }
  }
```

- [ ] **Step 5: The project's side**

In `Project`, after `executableOverride`:

```swift
  /// The lists the inspector shows: this folder's under the window's account.
  private(set) var capabilities: Capabilities
  /// What the lists brought since the inspector was last seen.
  private(set) var capabilityMarks = CapabilityMarks()
  /// How long file changes settle before the lists are read again; tests shorten it.
  @ObservationIgnored var capabilityDebounce: Duration = .seconds(2)
  @ObservationIgnored private var capabilityObserver: UUID?
  @ObservationIgnored private var capabilityRefresh: Task<Void, Never>?
```

In `init(folder:restoring:)`, right after `workspace = Workspace(folder: folder)`:

```swift
    capabilities = CapabilityStore.shared.capabilities(
      for: folder, account: AccountStore.shared.windowAccount(for: folder))
```

and as the last lines of `init`:

```swift
    observeCapabilities()
    workspace.onCapabilityFilesChanged = { [weak self] in self?.capabilityFilesChanged() }
```

After `run(_:in:)`:

```swift
  /// Hiding the inspector after it was on screen: everything was seen.
  func clearCapabilityMarks() {
    capabilityMarks = CapabilityMarks()
  }

  /// A server row was opened.
  func unmarkServer(_ name: String) {
    capabilityMarks.servers.remove(name)
  }

  /// The window's account may be another now: the lists follow it.
  func accountMayHaveChanged() {
    let entry = CapabilityStore.shared.capabilities(
      for: folder, account: AccountStore.shared.windowAccount(for: folder))
    guard entry !== capabilities else { return }
    if let capabilityObserver { capabilities.stopObserving(capabilityObserver) }
    capabilities = entry
    capabilityMarks = CapabilityMarks()
    observeCapabilities()
    entry.loadIfNeeded()
  }

  /// A session's `initialize` lists the project's skills only from the project's own
  /// folder, under the account the lists are for: a worktree is another checkout.
  func speaksForProject(_ session: ClaudeSession) -> Bool {
    ProjectPath.normalize(session.folder.path(percentEncoded: false))
      == ProjectPath.normalize(folder.path(percentEncoded: false))
      && session.account?.key == capabilities.accountKey
  }

  private func observeCapabilities() {
    capabilityObserver = capabilities.observe { [weak self] changes in
      self?.capabilityMarks.add(changes)
    }
  }

  private func capabilityFilesChanged() {
    capabilityRefresh?.cancel()
    let delay = capabilityDebounce
    capabilityRefresh = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.capabilities.refreshIfLoaded()
    }
  }

  /// The window is going: its probe too, unless another window shows the same lists.
  private func releaseCapabilities() {
    capabilityRefresh?.cancel()
    if let capabilityObserver { capabilities.stopObserving(capabilityObserver) }
    capabilityObserver = nil
    let shared = OpenSessions.shared.projects.values.contains {
      $0 !== self && $0.capabilities === capabilities
    }
    if !shared { capabilities.cancel() }
  }
```

In `run(_:in:)`, after the `guard canRun(in: target) else { return }` line:

```swift
    capabilityMarks.skills.remove(skill.name)
```

Change `stopAll()` to:

```swift
  func stopAll() {
    for item in sessions { item.session.stop() }
    releaseCapabilities()
  }
```

In `make(_:)`, after the `session.onStopped = …` block:

```swift
    session.onInitialized = { [weak self, weak session] reply in
      guard let self, let session, self.speaksForProject(session),
        let skills = ProjectCapabilities.skills(fromInitialize: reply)
      else { return }
      self.capabilities.sessionReported(skills: skills)
    }
```

- [ ] **Step 6: Run the tests**

Run: `make test-app`
Expected: PASS. If `aSkillFileChangeRefreshesOnceSettled` times out, check FSEvents
reports the temp folder's `/private/var/...` path and that `filesChanged` maps it back to
`tree.root` before `touchesCapabilities` sees it. The call is placed after that mapping on
purpose.

- [ ] **Step 7: Format and commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar apps/apple/DrakarTests
git commit -m "feat(apple): a window follows its project's lists, marks what changed, and lets its probe go when it closes"
```

---

### Task 8: The inspector (app)

**Files:**
- Create: `Drakar/Views/InspectorView.swift`
- Modify: `Drakar/ContentView.swift` (body: `.inspector`, toolbar, first load, scene storage)
- Modify: `Drakar/Services/Workspace.swift` (`FocusedValues`)
- Modify: `Drakar/DrakarApp.swift` (`InspectorCommand`)

**Interfaces:**
- Consumes: everything above. `PaneHeader`, `VerticalSplit` exist and are reused as they
  are (`Drakar/Views/PaneHeader.swift`, `Drakar/Views/VerticalSplit.swift`).
- Produces: `struct InspectorView: View { let project: Project }`,
  `struct InspectorToggle: View { let project: Project; @Binding var isShown: Bool }`,
  `FocusedValues.inspectorShown: Binding<Bool>?`.

This task is view code, checked live in Task 9; it has no hosted test of its own. Each
step ends with `make build` green.

- [ ] **Step 1: The column**

`Drakar/Views/InspectorView.swift`:

```swift
import AppKit
import DrakarKit
import SwiftUI

/// The window's right-hand column: what the project's `claude` would load, its skills over
/// its MCP servers, both filtered by one field. The split and the folding are kept per
/// window, as the sidebar's are.
struct InspectorView: View {
  let project: Project
  @SceneStorage("drakar.skillsFraction") private var fraction = 0.6
  @SceneStorage("drakar.skillsCollapsed") private var skillsCollapsed = false
  @SceneStorage("drakar.mcpCollapsed") private var serversCollapsed = false
  @State private var filter = ""

  var body: some View {
    VStack(spacing: 0) {
      TextField("Filter", text: $filter, prompt: Text("Filter skills and servers"))
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .accessibilityIdentifier("inspector.filter")
      Divider()
      VerticalSplit(
        fraction: $fraction, collapsesTop: skillsCollapsed, collapsesBottom: serversCollapsed
      ) {
        SkillsPane(project: project, filter: filter, isCollapsed: $skillsCollapsed)
      } bottom: {
        ServersPane(project: project, filter: filter, isCollapsed: $serversCollapsed)
      }
    }
  }
}

private struct SkillsPane: View {
  let project: Project
  let filter: String
  @Binding var isCollapsed: Bool

  private var capabilities: Capabilities { project.capabilities }

  var body: some View {
    let all = capabilities.lists.skills
    let shown = (all ?? []).filter { $0.matches(filter) }
    VStack(spacing: 0) {
      PaneHeader(
        title: String(localized: "Skills"), systemImage: "sparkles", isCollapsed: $isCollapsed,
        help: isCollapsed ? String(localized: "Show skills") : String(localized: "Hide skills"),
        identifier: "inspector.skills.header"
      ) {
        if let all { CountLabel(count: all.count) }
        RefreshButton(capabilities: capabilities, problem: all == nil ? nil : capabilities.skillsProblem)
      }
      if !isCollapsed {
        if all == nil {
          PaneStatus(capabilities: capabilities, problem: capabilities.skillsProblem)
        } else {
          List {
            ForEach(shown) { skill in
              SkillRow(skill: skill, isMarked: project.capabilityMarks.skills.contains(skill.name))
                .contentShape(Rectangle())
                .onTapGesture { project.run(skill, in: .newSession) }
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("inspector.skill.\(skill.name)")
                .contextMenu { menu(for: skill) }
            }
          }
          .listStyle(.sidebar)
          .overlay {
            if shown.isEmpty {
              Text(filter.isEmpty ? "No skills" : "No match")
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier("inspector.skills")
        }
      }
    }
  }

  @ViewBuilder private func menu(for skill: SkillEntry) -> some View {
    Button("Run in Current Session") { project.run(skill, in: .current) }
      .disabled(!project.canRun(in: .current))
    Button("Run in New Session") { project.run(skill, in: .newSession) }
    Divider()
    Button("Copy Name") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(skill.name, forType: .string)
    }
  }
}

/// A skill: its name, the namespace quieter, and one line of what it does.
private struct SkillRow: View {
  let skill: SkillEntry
  let isMarked: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        Text(
          "\(Text(skill.namespace.map { "\($0):" } ?? "").foregroundStyle(.secondary))\(skill.shortName)"
        )
        .lineLimit(1)
        if isMarked { NewDot() }
      }
      if !skill.displayDescription.isEmpty {
        Text(skill.displayDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .help(help)
    .accessibilityElement(children: .combine)
  }

  private var help: String {
    guard skill.takesArguments else { return skill.description }
    return "\(skill.description)\n\n/\(skill.name) \(skill.argumentHint)"
  }
}

private struct ServersPane: View {
  let project: Project
  let filter: String
  @Binding var isCollapsed: Bool

  private var capabilities: Capabilities { project.capabilities }

  var body: some View {
    let all = capabilities.lists.mcpServers
    let shown = (all ?? []).filter { $0.matches(filter) }
    VStack(spacing: 0) {
      PaneHeader(
        title: String(localized: "MCP Servers"), systemImage: "server.rack",
        isCollapsed: $isCollapsed,
        help: isCollapsed
          ? String(localized: "Show MCP servers") : String(localized: "Hide MCP servers"),
        identifier: "inspector.servers.header"
      ) {
        if let all { CountLabel(count: all.count) }
        RefreshButton(
          capabilities: capabilities, problem: all == nil ? nil : capabilities.serversProblem)
      }
      if !isCollapsed {
        if all == nil {
          PaneStatus(capabilities: capabilities, problem: capabilities.serversProblem)
        } else {
          List {
            ForEach(shown) { server in
              ServerRow(
                server: server, isMarked: project.capabilityMarks.servers.contains(server.name)
              ) { project.unmarkServer(server.name) }
              .accessibilityIdentifier("inspector.server.\(server.name)")
            }
          }
          .listStyle(.sidebar)
          .overlay {
            if shown.isEmpty {
              Text(filter.isEmpty ? "No MCP servers" : "No match")
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier("inspector.servers")
        }
      }
    }
  }
}

/// A server: its status, its name, where it is configured and what it offers, or why it
/// failed. Its tools fold out.
private struct ServerRow: View {
  let server: MCPServerEntry
  let isMarked: Bool
  let opened: () -> Void
  @State private var isExpanded = false

  var body: some View {
    if server.tools.isEmpty {
      label
    } else {
      DisclosureGroup(isExpanded: $isExpanded) {
        ForEach(server.tools, id: \.name) { tool in
          HStack(spacing: 4) {
            Text(tool.name).font(.caption.monospaced()).lineLimit(1)
            Spacer(minLength: 4)
            if tool.isDestructive {
              Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help("Destructive")
            } else if tool.isReadOnly {
              Image(systemName: "eye")
                .foregroundStyle(.secondary)
                .help("Read-only")
            }
          }
        }
      } label: {
        label
      }
      .onChange(of: isExpanded) { _, expanded in if expanded { opened() } }
    }
  }

  private var label: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Circle()
        .fill(tint)
        .frame(width: 7, height: 7)
        .help(server.status.label)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(
            "\(Text(server.namespace.map { "\($0):" } ?? "").foregroundStyle(.secondary))\(server.shortName)"
          )
          .lineLimit(1)
          if isMarked { NewDot() }
        }
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .help(server.error ?? server.status.label)
    .accessibilityElement(children: .combine)
    .accessibilityValue(server.status.label)
  }

  private var tint: Color {
    switch server.status {
    case .connected: .green
    case .needsAuth: .blue
    case .failed: .red
    case .pending, .other: .secondary
    }
  }

  /// "User · 11 tools", "Plugin · Needs authentication", or the failure.
  private var detail: String {
    if server.status == .failed, let error = server.error { return error }
    var parts = [MCPSourceLabel.text(server.source)].compactMap { $0 }
    if server.status == .connected {
      parts.append(
        server.tools.count == 1
          ? String(localized: "1 tool") : String(localized: "\(server.tools.count) tools"))
    } else {
      parts.append(server.status.label)
    }
    return parts.joined(separator: " · ")
  }
}

private struct CountLabel: View {
  let count: Int

  var body: some View {
    Text(count, format: .number)
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
  }
}

/// The blue dot of an unread session row, on a row that is new or went wrong.
private struct NewDot: View {
  var body: some View {
    Circle().fill(.blue).frame(width: 5, height: 5).accessibilityLabel("New")
  }
}

/// Reads the lists again; a spinner while a probe runs, a warning while the lists shown are
/// older than a reload that failed.
private struct RefreshButton: View {
  let capabilities: Capabilities
  let problem: String?

  var body: some View {
    if capabilities.isLoading {
      ProgressView().controlSize(.small)
    } else {
      Button(
        "Refresh", systemImage: problem == nil ? "arrow.clockwise" : "exclamationmark.triangle"
      ) { capabilities.refresh() }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
      .help(problem ?? String(localized: "Read the lists again"))
    }
  }
}

/// A pane with no list yet: asking, or why it could not, with Retry.
private struct PaneStatus: View {
  let capabilities: Capabilities
  let problem: String?

  var body: some View {
    VStack(spacing: 8) {
      if let problem, !capabilities.isLoading {
        Label(problem, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .font(.callout)
        if !capabilities.diagnostics.isEmpty {
          DisclosureGroup("Details") {
            Text(capabilities.diagnostics.suffix(600))
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
        Button("Retry") { capabilities.refresh() }
      } else {
        ProgressView().controlSize(.small)
        Text("Asking Claude Code…").font(.caption).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(12)
  }
}

/// Shows or hides the inspector. While it is hidden and its lists changed, a dot says so
/// and the tooltip says what. It also follows the window's account, the one view always on
/// screen in a project window that sees it change.
struct InspectorToggle: View {
  let project: Project
  @Binding var isShown: Bool
  /// Read only to notice a pick or the Settings default changing.
  @AppStorage(PreferenceKey.accountForFolder) private var picks = ""
  @AppStorage(PreferenceKey.newSessionAccount) private var settingsAccount = ""

  var body: some View {
    let marks = project.capabilityMarks
    let showsDot = !isShown && !marks.isEmpty
    Toggle(isOn: $isShown) {
      Label("Inspector", systemImage: "sidebar.right")
    }
    .toggleStyle(.button)
    .overlay(alignment: .topTrailing) {
      if showsDot {
        Circle().fill(.blue).frame(width: 6, height: 6).offset(x: 2, y: -1)
          .accessibilityHidden(true)
      }
    }
    .help(help(marks, showsDot: showsDot))
    .accessibilityValue(
      showsDot ? marks.summary(servers: project.capabilities.lists.mcpServers ?? []) : "")
    .accessibilityIdentifier("window.inspector")
    .onChange(of: picks + "\n" + settingsAccount) { project.accountMayHaveChanged() }
  }

  private func help(_ marks: CapabilityMarks, showsDot: Bool) -> String {
    let action =
      isShown
      ? String(localized: "Hide skills and MCP servers (⌥⌘0)")
      : String(localized: "Show skills and MCP servers (⌥⌘0)")
    guard showsDot else { return action }
    return marks.summary(servers: project.capabilities.lists.mcpServers ?? []) + "\n" + action
  }
}
```

Run: `make build`
Expected: builds. If the `Text` interpolation of a styled `Text` does not compile on this
toolchain, replace each `Text("\(Text(…).foregroundStyle(.secondary))\(name)")` with
`Text(namespace).foregroundStyle(.secondary) + Text(name)` (the namespace part being the
same optional-mapped string).

- [ ] **Step 2: The focused binding and the View menu**

In `Workspace.swift`'s `extension FocusedValues`, after `filesCollapsed`:

```swift
  /// Whether the focused window shows its inspector, for View › Show Inspector.
  @Entry var inspectorShown: Binding<Bool>?
```

In `DrakarApp.swift`, change `CommandGroup(after: .sidebar) { FilesCommand() }` to:

```swift
      CommandGroup(after: .sidebar) {
        FilesCommand()
        InspectorCommand()
      }
```

and after `FilesCommand`:

```swift
/// View › Show Inspector (⌥⌘0, the inspector key of Xcode and Finder): the focused window's
/// skills and MCP servers.
private struct InspectorCommand: View {
  @FocusedBinding(\.inspectorShown) private var inspectorShown

  var body: some View {
    Button(inspectorShown == true ? "Hide Inspector" : "Show Inspector") {
      inspectorShown?.toggle()
    }
    .keyboardShortcut("0", modifiers: [.command, .option])
    .disabled(inspectorShown == nil)
  }
}
```

- [ ] **Step 3: Put it in the window**

In `ContentView`, after `@SceneStorage("drakar.keepsOnTop") private var keepsOnTop = false`:

```swift
  /// Whether the skills and MCP servers column is shown, kept per window.
  @SceneStorage("drakar.inspectorShown") private var inspectorShown = false
```

On the `NavigationSplitView { … } detail: { … }` expression, before `.background(
WindowReader { window in`:

```swift
        .inspector(isPresented: $inspectorShown) {
          InspectorView(project: project)
            .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
        }
        // Hidden after being seen: what it showed was seen.
        .onChange(of: inspectorShown) { was, now in
          if was, !now { project.clearCapabilityMarks() }
        }
        // The first window on the folder reads its lists, shown or not, so a change shows on
        // the toolbar button.
        .task(id: ObjectIdentifier(project)) { project.capabilities.loadIfNeeded() }
        .focusedSceneValue(\.inspectorShown, $inspectorShown)
```

In `.toolbar { if let project { … } }`, after the `AccountToolbarItem(folder:
project.folder)` item:

```swift
        ToolbarItem(placement: .primaryAction) {
          InspectorToggle(project: project, isShown: $inspectorShown)
        }
```

Run: `make build`
Expected: builds.

- [ ] **Step 4: Run every suite**

Run: `make test && make test-app`
Expected: PASS.

- [ ] **Step 5: Format and commit**

```bash
make -C apps/apple format-swift
git add apps/apple/Drakar
git commit -m "feat(apple): an inspector lists the project's skills and mcp servers, ⌥⌘0"
```

---

### Task 9: Live

**Files:**
- Modify: `PLAN.md` (repo root; the "What exists" paragraph)

- [ ] **Step 1: Run the app on this repository**

```bash
cd /Users/olivier/Projects/apps/drakar-skills-inspector/apps/apple
make run
```

Open the `drakar-skills-inspector` folder as a project. Then check each of these, and note
what each showed:

1. ⌥⌘0 shows the inspector; within about 2 s both panes fill. The Skills count matches
   the non-built-in commands, and `/compact` and `/simplify` are absent.
2. The needs-auth and failed servers are first in MCP Servers, each with a blue or red dot
   and its source or error on the second line. Unfolding a connected server lists its tools.
3. A click on `check` (or any skill with an empty hint) opens a new session that runs it.
4. A click on `marketing:seo-audit` (or any skill with a hint) opens a new session with
   `/marketing:seo-audit ` in the composer and the hint above it. Typing `x` gives
   `/marketing:seo-audit x`: **the cursor is at the end, the text not selected.** If the
   text is selected, fix it in `ComposerView`: after setting the focus, move the field
   editor's selection to the end (`NSApp.keyWindow?.fieldEditor(false, for: nil)` /
   `NSTextView.setSelectedRange`). Then check again.
5. Right-click → Run in Current Session on an idle session puts the skill in that session.
   On a session mid-turn the item is disabled.
6. With the inspector hidden, `mkdir -p .claude/skills/x && printf -- '---\nname: x\ndescription: test\n---\n' > .claude/skills/x/SKILL.md`
   in the project. Within about 4 s the toolbar button has a dot and its tooltip says
   "1 new skill". Showing the inspector shows `x` with a dot; hiding it again clears the
   dots. Remove `.claude/skills/x` afterwards.
7. Typing in the filter narrows both panes. Clearing it brings everything back.
8. Close the project tab during the first 2 s after opening it, then
   `ls ~/.claude/sessions/` shows no entry left by the probe (compare pids with `ps`).

Any check that fails is a bug to fix in the task that owns it, with a test where a hosted
test can see it, before going on.

- [ ] **Step 2: Say it exists**

In `PLAN.md`'s status paragraph, after the sentence about phase 5, add one sentence in its
style: "The inspector (⌥⌘0) lists the skills and MCP servers a project's `claude` would load,
from a short probe, and runs a skill in one click."

- [ ] **Step 3: Format, check, commit**

```bash
make -C apps/apple format-swift-check
cd /Users/olivier/Projects/apps/drakar-skills-inspector && make audit
git add PLAN.md apps/apple
git commit -m "docs: the skills and mcp inspector is in"
```
