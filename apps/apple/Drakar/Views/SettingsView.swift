import DrakarKit
import SupportKitSettings
import SwiftUI

// MARK: - Settings

/// The panes, in three sections, as Cupertino and Armada draw them.
///
/// The first is how sessions behave: General, Models, Transcript, Theme, Attention, then
/// Runner, which says where they may run, and MCP Server, which says what an agent on this Mac
/// may do with them.
///
/// The second is the fleet's information section: What's New and Updates are the version pair
/// (what this build changed, and is there a newer one), and About answers which build this is.
/// About stays last of the three, because it answers a question you only ask with a bug report
/// open. No Help pane, unlike Cupertino's: Drakar keeps its menu bar, so the Help menu is
/// always there to carry those links.
///
/// Licence is last and alone: a key, the trial, and the Buy button while
/// `LicenceLinks.isSelling`. Somebody opens it because of a refusal or a receipt, never to
/// tune something.
enum SettingsPane: String, SupportKitSettings.SettingsPane {
  case general
  case models
  case transcript
  case theme
  case attention
  case runner
  case mcp
  case whatsNew
  case updates
  case about
  case licence

  var title: LocalizedStringKey {
    switch self {
    case .general: "General"
    case .models: "Models"
    case .transcript: "Transcript"
    case .theme: "Theme"
    case .attention: "Attention"
    case .runner: "Runner"
    case .mcp: "MCP Server"
    case .updates: "Updates"
    case .licence: "Licence"
    case .whatsNew: "What's New"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .models: "cpu"
    case .transcript: "text.bubble"
    case .theme: "paintpalette"
    case .attention: "bell.badge"
    case .runner: "desktopcomputer.and.macbook"
    case .mcp: "point.3.connected.trianglepath.dotted"
    case .updates: "arrow.triangle.2.circlepath"
    case .licence: "key"
    case .whatsNew: "sparkles"
    case .about: "info.circle"
    }
  }

  var group: SettingsPaneGroup {
    switch self {
    case .general, .models, .transcript, .theme, .attention, .runner, .mcp: .configuration
    case .whatsNew, .updates, .about: .information
    case .licence: .entitlement
    }
  }

  /// The unread-release count on What's New, and nothing anywhere else. Read on
  /// every sidebar draw, so it clears the moment the pane marks the notes seen.
  var badge: Int {
    self == .whatsNew && Changelog.hasUnseen ? Changelog.unseen.count : 0
  }

  static var defaultPane: SettingsPane { .general }
}

/// Drakar's section between the package's pair. Sections draw in ascending `order`, and
/// `.entitlement` sits at 1_000 to leave room for exactly this.
extension SettingsPaneGroup {
  nonisolated static let information = SettingsPaneGroup(order: 500)
}

// MARK: - Preferences

/// The defaults keys, named the way every other key in the fleet is: the slug, then
/// the setting.
enum PreferenceKey {
  /// The agent New Session starts (`AgentKind`'s raw value); empty for Claude Code.
  static let defaultAgent = "drakar.defaultAgent"
  /// Which folders Drakar offers itself as the editor for, to `claude` run in a terminal.
  static let editorScope = "drakar.editorScope"
  /// The `claude` sessions run, by path; empty for the one the login shell would run.
  static let claudePath = "drakar.claudePath"
  /// The configuration directory a new session runs under; empty for the login shell's.
  static let newSessionAccount = "drakar.newSessionAccount"
  /// Folder path → account directory, as a JSON object: the account a folder's new sessions
  /// start under. A string so a view can observe it with `@AppStorage`.
  static let accountForFolder = "drakar.accountForFolder"
  /// Folder path → agent raw value, as a JSON object: the agent a folder's new sessions start
  /// under. A string so a view can observe it with `@AppStorage`.
  static let agentForFolder = "drakar.agentForFolder"
  /// Whether a session that finishes its turn while Drakar is in the background says so.
  static let notifiesTurnEnds = "drakar.notifiesTurnEnds"
  /// Whether a turn that ends on a question or an offer marks its row.
  static let recognisesAsks = "drakar.recognisesAsks"
  /// Whether the last prompt stays pinned over the transcript even while it is in view.
  static let pinsLastPrompt = "drakar.pinsLastPrompt"
  /// Whether sessions start able to switch to Bypass permissions; on unless turned off.
  static let allowsBypass = "drakar.allowsBypass"
  /// The model new sessions start with (a `value` of `initialize`'s `models`); empty for
  /// Claude Code's default.
  static let defaultModel = "drakar.defaultModel"
  /// The model new Codex sessions start with; empty for Codex's own (`config.toml`).
  static let codexDefaultModel = "drakar.codexDefaultModel"
  /// The model new Antigravity sessions start with; empty for Antigravity's default.
  static let agyDefaultModel = "drakar.agyDefaultModel"
  /// The model new Grok sessions start with; empty for Grok's default.
  static let grokDefaultModel = "drakar.grokDefaultModel"
  /// Whether the model menus list older pinned models (Opus 4.8) beside the current ones; off
  /// unless turned on.
  static let showsLegacyModels = "drakar.showsLegacyModels"
  /// The permission mode new sessions start with (`PermissionMode`'s raw value); empty for
  /// Claude Code's default.
  static let defaultMode = "drakar.defaultMode"
  /// The permission mode new Codex sessions start with (`PermissionMode`'s raw value); empty
  /// for Ask before edits.
  static let codexDefaultMode = "drakar.codexDefaultMode"
  /// The permission mode new Antigravity sessions start with (`PermissionMode`'s raw value);
  /// empty for Antigravity's default.
  static let agyDefaultMode = "drakar.agyDefaultMode"
  /// The effort new sessions start with (`low` … `max`); empty for Claude Code's default.
  static let defaultEffort = "drakar.defaultEffort"
  /// The accent colour, as `RRGGBBAA` hex; absent for the catalog's.
  static let accentColor = "drakar.accentColor"
  /// Whether the editor sits left of the session; off, as the default, it opens to its right.
  static let editorLeads = "drakar.editorLeads"
  /// A launch has linked the `drakar` command once: a link removed since stays removed.
  static let commandLinked = "drakar.commandLinked"
  /// Whether the Mac stays awake while an agent works (`KeepAwake`); on unless turned off.
  static let keepsAwake = "drakar.keepsAwake"
  /// Whether an idle Claude Code session compacts before its prompt cache expires
  /// (`IdleCompaction`); on unless turned off.
  static let compactsIdle = "drakar.compactsIdle"
  /// The command a compaction Drakar starts sends first (`/distill`); empty for none.
  static let compactionFirst = "drakar.compactionFirst"
}

/// What Settings picked for the sessions Drakar starts.
enum ClaudeChoice {
  /// A scratch defaults suite for tests, never the real one. Task-local so that suites
  /// running in parallel each see their own; a name because `UserDefaults` is not `Sendable`.
  @TaskLocal static var testSuite: String?

  /// Where the choices are read from and the folder picks written to.
  static var defaults: UserDefaults {
    testSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  /// The `claude` picked in Settings; nil to run the shell's.
  static var executable: URL? {
    stored(PreferenceKey.claudePath).map { URL(filePath: $0) }
  }

  /// The account picked for new sessions while its directory is there; nil for the shell's.
  static var newSessionAccount: ClaudeAccount? {
    guard let path = stored(PreferenceKey.newSessionAccount),
      FileManager.default.fileExists(atPath: path)
    else { return nil }
    return account(at: path)
  }

  /// The account a new session in `folder` starts under: the folder's pick, else Settings',
  /// else nil for the shell's. A resumed session ignores both and runs where it was written.
  static func account(forNewSessionIn folder: URL) -> ClaudeAccount? {
    pickedAccount(for: folder) ?? newSessionAccount
  }

  /// The folder's pick while its directory is there. A missing directory skips the pick and
  /// keeps it, for when the directory comes back.
  static func pickedAccount(for folder: URL) -> ClaudeAccount? {
    guard let path = picks[folderKey(folder)], FileManager.default.fileExists(atPath: path)
    else { return nil }
    return account(at: path)
  }

  static func pick(_ account: ClaudeAccount, for folder: URL) {
    var picks = picks
    picks[folderKey(folder)] = account.directory.path(percentEncoded: false)
    let data = (try? JSONEncoder().encode(picks)) ?? Data("{}".utf8)
    defaults.set(String(decoding: data, as: UTF8.self), forKey: PreferenceKey.accountForFolder)
  }

  /// Sessions start with `--allow-dangerously-skip-permissions`, so the mode pill can offer
  /// Bypass. On by default.
  static var allowsBypass: Bool {
    _ = AttentionDefaults.shared.revision
    return defaults.object(forKey: PreferenceKey.allowsBypass) as? Bool ?? true
  }

  /// The agent New Session starts; ⌥-click starts the other.
  static var defaultAgent: AgentKind {
    _ = AttentionDefaults.shared.revision
    return stored(PreferenceKey.defaultAgent).flatMap(AgentKind.init(rawValue:)) ?? .claude
  }

  /// The agent picked for `folder` in the toolbar; nil when the folder follows Settings.
  static func pickedAgent(for folder: URL) -> AgentKind? {
    _ = AttentionDefaults.shared.revision
    return agentPicks[folderKey(folder)].flatMap(AgentKind.init(rawValue:))
  }

  /// The agent a new session in `folder` starts under: the folder's pick, else Settings'.
  static func agent(forNewSessionIn folder: URL) -> AgentKind {
    pickedAgent(for: folder) ?? defaultAgent
  }

  static func pick(_ agent: AgentKind, for folder: URL) {
    var picks = agentPicks
    picks[folderKey(folder)] = agent.rawValue
    let data = (try? JSONEncoder().encode(picks)) ?? Data("{}".utf8)
    defaults.set(String(decoding: data, as: UTF8.self), forKey: PreferenceKey.agentForFolder)
  }

  /// The model new sessions start with, from Settings; nil for Claude Code's default.
  static var defaultModel: String? {
    _ = AttentionDefaults.shared.revision
    return stored(PreferenceKey.defaultModel)
  }

  /// The model new Codex sessions start with, from Settings; nil for Codex's own.
  static var codexDefaultModel: String? {
    _ = AttentionDefaults.shared.revision
    return stored(PreferenceKey.codexDefaultModel)
  }

  /// The model new Antigravity sessions start with, from Settings; nil for Antigravity's
  /// default.
  static var agyDefaultModel: String? {
    _ = AttentionDefaults.shared.revision
    return stored(PreferenceKey.agyDefaultModel)
  }

  /// The model new Grok sessions start with, from Settings; nil for Grok's default.
  static var grokDefaultModel: String? {
    _ = AttentionDefaults.shared.revision
    return stored(PreferenceKey.grokDefaultModel)
  }

  /// The model new `agent` sessions start with, from Settings; nil for the agent's own.
  static func defaultModel(for agent: AgentKind) -> String? {
    switch agent {
    case .claude: defaultModel
    case .codex: codexDefaultModel
    case .agy: agyDefaultModel
    case .grok: grokDefaultModel
    }
  }

  /// An idle session compacts before its prompt cache expires. On by default.
  static var compactsIdle: Bool {
    defaults.object(forKey: PreferenceKey.compactsIdle) as? Bool ?? true
  }

  /// The command a compaction Drakar starts sends first; nil for none.
  static var compactionFirst: String? { stored(PreferenceKey.compactionFirst) }

  /// The model menus list older pinned models. Off by default.
  static var showsLegacyModels: Bool {
    _ = AttentionDefaults.shared.revision
    return defaults.object(forKey: PreferenceKey.showsLegacyModels) as? Bool ?? false
  }

  /// `models` as the menus offer them: without the older ones unless Settings shows them,
  /// `kept` always.
  static func offered(_ models: [ModelOption], keeping kept: String?) -> [ModelOption] {
    showsLegacyModels ? models : ModelOption.withoutLegacy(models, keeping: kept)
  }

  /// The mode new sessions start with, from Settings; nil for Claude Code's. Bypass only
  /// while Settings allows it.
  static var defaultMode: PermissionMode? {
    _ = AttentionDefaults.shared.revision
    let mode = stored(PreferenceKey.defaultMode).flatMap(PermissionMode.init(rawValue:))
    return mode == .bypass && !allowsBypass ? nil : mode
  }

  /// The mode new Codex sessions start with, from Settings: one Codex offers, Bypass only
  /// while Settings allows it; nil for Ask before edits.
  static var codexDefaultMode: PermissionMode? {
    _ = AttentionDefaults.shared.revision
    let mode = stored(PreferenceKey.codexDefaultMode).flatMap(PermissionMode.init(rawValue:))
    return mode.flatMap {
      CodexPolicy.offeredModes(allowsBypass: allowsBypass).contains($0) ? $0 : nil
    }
  }

  /// The mode new Antigravity sessions start with, from Settings: one Antigravity offers,
  /// Bypass only while Settings allows it; nil for Antigravity's default.
  static var agyDefaultMode: PermissionMode? {
    _ = AttentionDefaults.shared.revision
    let mode = stored(PreferenceKey.agyDefaultMode).flatMap(PermissionMode.init(rawValue:))
    return mode.flatMap {
      AgyPolicy.offeredModes(allowsBypass: allowsBypass).contains($0) ? $0 : nil
    }
  }

  /// The effort new sessions start with, from Settings; nil for Claude Code's
  /// (`settings.json`'s `effortLevel`, else the model's own).
  static var defaultEffort: String? {
    _ = AttentionDefaults.shared.revision
    return stored(PreferenceKey.defaultEffort)
  }

  private static var picks: [String: String] {
    guard let text = stored(PreferenceKey.accountForFolder),
      let picks = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8))
    else { return [:] }
    return picks
  }

  private static var agentPicks: [String: String] {
    guard let text = stored(PreferenceKey.agentForFolder),
      let picks = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8))
    else { return [:] }
    return picks
  }

  private static func folderKey(_ folder: URL) -> String {
    ProjectPath.normalize(folder)
  }

  /// The account a configuration directory holds; `~/.claude` is the default one.
  static func account(at path: String) -> ClaudeAccount {
    let directory = URL(filePath: path, directoryHint: .isDirectory)
    let standard = FileManager.default.homeDirectoryForCurrentUser.appending(
      path: ".claude", directoryHint: .isDirectory)
    return ClaudeAccount(
      directory: directory,
      isDefault: directory.standardizedFileURL.path(percentEncoded: false)
        == standard.standardizedFileURL.path(percentEncoded: false))
  }

  private static func stored(_ key: String) -> String? {
    defaults.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
  }
}

/// What each level of `Urgency` does, as the Attention pane set it.
enum AttentionFeedback: String, CaseIterable {
  /// In the group's header count and Next Session Needing You.
  case counts
  case badges
  case notifies
}

enum AttentionChoice {
  /// Where the choices are read from; a scratch suite in tests, never the real one.
  static var defaults = UserDefaults.standard

  static var recognisesAsks: Bool {
    _ = AttentionDefaults.shared.revision
    return defaults.object(forKey: PreferenceKey.recognisesAsks) as? Bool ?? true
  }

  static var notifiesTurnEnds: Bool { defaults.bool(forKey: PreferenceKey.notifiesTurnEnds) }

  static func key(_ level: Urgency, _ feedback: AttentionFeedback) -> String {
    "drakar.attention.\(level.rawValue).\(feedback.rawValue)"
  }

  /// Everything is on but an offer, which only marks its row.
  static func defaultValue(_ level: Urgency, _ feedback: AttentionFeedback) -> Bool {
    level != .offer
  }

  static func isOn(_ level: Urgency, _ feedback: AttentionFeedback) -> Bool {
    _ = AttentionDefaults.shared.revision
    return defaults.object(forKey: key(level, feedback)) as? Bool ?? defaultValue(level, feedback)
  }
}

/// Bumped whenever a default changes, and read by every `AttentionChoice` question:
/// `UserDefaults` is not observable, and a switch flipped in the Attention pane has to
/// redraw the rows and counts that read it; so do the composer's pills, which read the defaults for new sessions.
@Observable
final class AttentionDefaults {
  static let shared = AttentionDefaults()

  private(set) var revision = 0
  @ObservationIgnored private var observer: (any NSObjectProtocol)?

  private init() {
    observer = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: nil
    ) { _ in
      if Thread.isMainThread {
        MainActor.assumeIsolated { AttentionDefaults.shared.revision += 1 }
      } else {
        Task { @MainActor in AttentionDefaults.shared.revision += 1 }
      }
    }
  }
}

/// Where a terminal `claude` finds Drakar as its editor (`docs/claude-ide-bridge.md`).
enum EditorScope: String, CaseIterable {
  /// The folders of Drakar's open session windows: the default, because a second editor
  /// matching the same folder as VS Code stops `claude --ide` connecting to either.
  case openFolders
  /// Every folder in the home folder.
  case home
  /// Never: no lock file is written.
  case off

  static var current: EditorScope {
    UserDefaults.standard.string(forKey: PreferenceKey.editorScope).flatMap(EditorScope.init)
      ?? .openFolders
  }
}

// MARK: - The window

/// The sidebar, the persisted pane, the `settings.pane.*` identifiers and the
/// heading all come from the shared scaffold; what stays here are the pane bodies.
struct SettingsView: View {
  var body: some View {
    SettingsScaffold(selection: Support.settings) { pane in
      switch pane {
      case .general: GeneralPane()
      case .models: ModelsSettingsPane()
      case .transcript: TranscriptPane()
      case .theme: ThemePane()
      case .attention: AttentionPane()
      case .runner: RunnerSettingsPane()
      case .mcp: MCPSettingsPane()
      case .updates: UpdatesPane()
      case .licence: LicensePane()
      case .whatsNew: WhatsNewPane()
      case .about:
        AboutSettingsPane(app: Support.app, preferIssueTracker: Support.preferIssueTracker)
      }
    }
    // A floor, not a fixed size, and sized for the sidebar: it spends up to 240pt
    // before a pane sees any width at all.
    .settingsWindowSize(minWidth: 660, idealWidth: 700, minHeight: 400, idealHeight: 460)
  }
}

struct GeneralPane: View {
  @AppStorage(PreferenceKey.editorScope) private var editorScope = EditorScope.openFolders
  @AppStorage(PreferenceKey.defaultAgent) private var defaultAgent = AgentKind.claude.rawValue
  @AppStorage(PreferenceKey.allowsBypass) private var allowsBypass = true
  @AppStorage(PreferenceKey.editorLeads) private var editorLeads = false
  @AppStorage(PreferenceKey.keepsAwake) private var keepsAwake = true

  var body: some View {
    Form {
      Section {
        Picker("New sessions run", selection: $defaultAgent) {
          ForEach(AgentKind.allCases, id: \.self) { agent in
            Text(agent.name).tag(agent.rawValue)
          }
        }
        .accessibilityIdentifier("settings.defaultAgent")
      } footer: {
        Text("Right-click New Session to pick any agent, or ⌥-click / ⌃⌘N for the alternate one.")
      }
      Section {
        Toggle("Allow Bypass permissions", isOn: $allowsBypass)
          .accessibilityIdentifier("settings.allowsBypass")
      } footer: {
        Text(
          "Lets sessions switch to Bypass permissions in the composer and offers Bypass as a default mode."
        )
      }
      Section {
        Picker("Files open", selection: $editorLeads) {
          Text("To the right of the session").tag(false)
          Text("To the left of the session").tag(true)
        }
        .accessibilityIdentifier("settings.editorLeads")
      } footer: {
        Text(
          "Where the editor sits: files from a link, the file tree or Quick Open. View › Move Editor (⌥⌘E) switches it."
        )
      }
      Section {
        Toggle("Keep the Mac awake while an agent is working", isOn: $keepsAwake)
          .accessibilityIdentifier("settings.keepsAwake")
      } footer: {
        Text(
          "From a prompt to the end of its turn, even after you close its window or quit Drakar, but not while it waits for you. The display still sleeps, and a laptop closed on battery sleeps anyway."
        )
      }
      CompactionSection()
      CommandLineSection()
      Section {
        Picker("Be the editor for Claude Code in a terminal", selection: $editorScope) {
          Text("In folders open in Drakar").tag(EditorScope.openFolders)
          Text("In any folder in my home folder").tag(EditorScope.home)
          Text("Never").tag(EditorScope.off)
        }
        .accessibilityIdentifier("settings.editorScope")
      } footer: {
        Text(
          "Run `claude --ide` in one of these folders, or type /ide in a running session, and its edits open here for you to accept or reject. If VS Code has the same folder open, pick the editor with /ide."
        )
      }
    }
    .formStyle(.grouped)
    .onChange(of: editorScope) { IDEBridge.shared.refreshFolders() }
    .onChange(of: keepsAwake) { KeepAwake.shared.apply() }
  }
}

struct TranscriptPane: View {
  @AppStorage(PreferenceKey.pinsLastPrompt) private var pinsLastPrompt = false

  var body: some View {
    Form {
      Section {
        Toggle("Always show your last message", isOn: $pinsLastPrompt)
          .accessibilityIdentifier("settings.pinsLastPrompt")
      } footer: {
        Text(
          "Pinned at the top of the transcript; click it to scroll back to the message. When off, it shows only once the message has scrolled out of view."
        )
      }
    }
    .formStyle(.grouped)
  }
}

/// How Drakar is coloured: the accent, for now. Picking the default again forgets the key,
/// so a later change to the default reaches everyone who never chose.
struct ThemePane: View {
  @AppStorage(PreferenceKey.accentColor) private var accent = ""

  var body: some View {
    Form {
      Section {
        SwatchColorPicker(
          "Accent colour", value: SwatchColor(hex: accent) ?? Theme.defaultAccent,
          default: Theme.defaultAccent, palette: Theme.accentPalette
        ) { picked in
          accent = picked?.hex ?? ""
        }
        .accessibilityIdentifier("settings.accentColor")
      } footer: {
        Text(
          "Folders, the selected row, prominent buttons, the pane handles and the controls that take a tint."
        )
      }
    }
    .formStyle(.grouped)
  }
}

/// What wants the person, and how loudly: per level, whether it counts, badges, notifies.
struct AttentionPane: View {
  @AppStorage(PreferenceKey.recognisesAsks) private var recognisesAsks = true
  @AppStorage(PreferenceKey.notifiesTurnEnds) private var notifiesTurnEnds = false

  var body: some View {
    Form {
      Section {
        Toggle("Recognise questions and offers at the end of a turn", isOn: $recognisesAsks)
          .accessibilityIdentifier("settings.recognisesAsks")
      } footer: {
        Text(
          "A reply that ends on a question, such as “Want me to build it that way?”, marks its session “Asked you”; one that ends on an offer marks it “Offered”. Either stays until you answer or dismiss it (⌥⇧⌘D)."
        )
      }
      Section {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
          GridRow {
            Text("")
            Text("Counts").gridColumnAlignment(.center)
            Text("Dock badge").gridColumnAlignment(.center)
            Text("Notification").gridColumnAlignment(.center)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          ForEach(Urgency.allCases.reversed(), id: \.self) { level in
            GridRow {
              // The mark its sidebar row shows, so the pane explains the list.
              HStack(spacing: 7) {
                StateDot(state: RowState(level))
                Text(level.title)
              }
              ForEach(AttentionFeedback.allCases, id: \.self) { feedback in
                FeedbackToggle(level: level, feedback: feedback)
                  .disabled(!recognisesAsks && (level == .question || level == .offer))
              }
            }
          }
          GridRow {
            HStack(spacing: 7) {
              Color.clear.frame(width: 7, height: 7)
              Text("Finished turn")
            }
            Text("")
            Text("")
            Toggle("", isOn: $notifiesTurnEnds)
              .labelsHidden()
              .accessibilityIdentifier("settings.notifiesTurnEnds")
          }
        }
      } footer: {
        Text(
          "Counts puts the session in the sidebar's count and in Next Session Needing You (⇧⌥⌘↓). Drakar notifies unless the session is the one you are looking at."
        )
      }
    }
    .formStyle(.grouped)
    .onChange(of: recognisesAsks) { Attention.shared.refresh() }
  }
}

/// One switch of the Attention grid, on its own key.
private struct FeedbackToggle: View {
  let level: Urgency
  let feedback: AttentionFeedback
  @AppStorage private var isOn: Bool

  init(level: Urgency, feedback: AttentionFeedback) {
    self.level = level
    self.feedback = feedback
    _isOn = AppStorage(
      wrappedValue: AttentionChoice.defaultValue(level, feedback),
      AttentionChoice.key(level, feedback))
  }

  var body: some View {
    Toggle("", isOn: $isOn)
      .labelsHidden()
      .gridColumnAlignment(.center)
      .onChange(of: isOn) { Attention.shared.refresh() }
      .accessibilityIdentifier("settings.\(level.rawValue).\(feedback.rawValue)")
  }
}

/// The `drakar` command, linked with one click, as VS Code's "Install 'code' command".
/// Compactions Drakar starts: before an idle session's prompt cache expires, as Claude Code
/// does itself only where it takes the session to be attended, and the command sent first.
private struct CompactionSection: View {
  @AppStorage(PreferenceKey.compactsIdle) private var compactsIdle = true
  @AppStorage(PreferenceKey.compactionFirst) private var first = ""

  var body: some View {
    Section {
      Toggle("Compact idle conversations before the prompt cache expires", isOn: $compactsIdle)
        .accessibilityIdentifier("settings.compactsIdle")
      Text(
        "Six minutes before an idle session’s hour of cache runs out, once its context holds 200k tokens (CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS sets another floor). Claude Code does this itself in a terminal or VS Code, but not for the sessions Drakar runs."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      TextField("Run first", text: $first, prompt: Text(verbatim: "/distill"))
        .accessibilityIdentifier("settings.compactionFirst")
      Text(
        "Sent before Drakar compacts, idle or from the Session inspector. If that turn stops to ask you something, Drakar does not compact."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    } header: {
      Text("Compaction")
    }
  }
}

private struct CommandLineSection: View {
  /// Where the link goes, once the login shell's PATH is known.
  @State private var directory: URL?
  @State private var installed = false
  @State private var failure: String?

  var body: some View {
    Section {
      LabeledContent("Command line") {
        HStack {
          if let directory, installed {
            Text("drakar, in \(ContentView.abbreviated(directory))")
          } else {
            Text("Not installed")
          }
          Button(installed ? "Reinstall" : "Install") { Task { await install() } }
            .disabled(directory == nil || CommandLineTool.bundledScript == nil)
            .accessibilityIdentifier("settings.installCommand")
        }
      }
      if let failure {
        Label(failure, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
    } footer: {
      Text(
        "Type `drakar` in a terminal to open the folder you are in, or `drakar <folder>` for another, as `code .` does for VS Code."
      )
    }
    .task {
      let environment = await AgentSession.environment.value
      let directory = CommandLineTool.directory(
        path: environment["PATH"], home: FileManager.default.homeDirectoryForCurrentUser)
      self.directory = directory
      installed =
        CommandLineTool.bundledScript.map { CommandLineTool.isInstalled(script: $0, in: directory) }
        ?? false
    }
  }

  private func install() async {
    guard let directory, let script = CommandLineTool.bundledScript else { return }
    failure = nil
    let place = ContentView.abbreviated(directory)
    do {
      try CommandLineTool.install(script: script, in: directory)
    } catch CocoaError.fileWriteNoPermission {
      // `/usr/local/bin` is root's on a Mac without Intel Homebrew: macOS asks for a password.
      if let problem = await CommandLineTool.installAsAdministrator(script: script, in: directory) {
        failure = String(localized: "Could not link drakar in \(place): \(problem)")
      }
    } catch {
      let link = directory.appending(path: CommandLineTool.name).path(percentEncoded: false)
      let isFile =
        FileManager.default.fileExists(atPath: link)
        && (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == nil
      failure =
        isFile
        ? String(
          localized: "\(place) already has a file named drakar. Remove it, then install again.")
        : String(localized: "Could not link drakar in \(place): \(error.localizedDescription)")
    }
    installed = CommandLineTool.isInstalled(script: script, in: directory)
    // Linked by hand counts as linked once: a launch never puts back one removed since.
    if installed { UserDefaults.standard.set(true, forKey: PreferenceKey.commandLinked) }
  }
}

#Preview {
  SettingsView()
}
