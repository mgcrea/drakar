import DrakarKit
import SupportKitSettings
import SwiftUI

// MARK: - Settings

/// The panes, and the order they sit in: General, Transcript, Theme, Attention, What's New,
/// About.
///
/// An entitlement pane joins only when something is actually sold: before a StoreKit
/// product is registered it would be a button that fails.
///
/// What's New sits beside About: both answer what this build is rather than how it behaves.
/// DIVERGES from armada, which puts the two in an `.information` section of their own:
/// Drakar's panes are one ungrouped list until something is sold. About stays last, because
/// it answers a question you only ask with a bug report open.
enum SettingsPane: String, SupportKitSettings.SettingsPane {
  case general
  case transcript
  case theme
  case attention
  case whatsNew
  case about

  var title: LocalizedStringKey {
    switch self {
    case .general: "General"
    case .transcript: "Transcript"
    case .theme: "Theme"
    case .attention: "Attention"
    case .whatsNew: "What's New"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .transcript: "text.bubble"
    case .theme: "paintpalette"
    case .attention: "bell.badge"
    case .whatsNew: "sparkles"
    case .about: "info.circle"
    }
  }

  /// The unread-release count on What's New, and nothing anywhere else. Read on
  /// every sidebar draw, so it clears the moment the pane marks the notes seen.
  var badge: Int {
    self == .whatsNew && Changelog.hasUnseen ? Changelog.unseen.count : 0
  }

  static var defaultPane: SettingsPane { .general }
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
  /// Whether the model menus list older pinned models (Opus 4.8) beside the current ones; off
  /// unless turned on.
  static let showsLegacyModels = "drakar.showsLegacyModels"
  /// The permission mode new sessions start with (`PermissionMode`'s raw value); empty for
  /// Claude Code's default.
  static let defaultMode = "drakar.defaultMode"
  /// The permission mode new Codex sessions start with (`PermissionMode`'s raw value); empty
  /// for Ask before edits.
  static let codexDefaultMode = "drakar.codexDefaultMode"
  /// The effort new sessions start with (`low` … `max`); empty for Claude Code's default.
  static let defaultEffort = "drakar.defaultEffort"
  /// The accent colour, as `RRGGBBAA` hex; absent for the catalog's.
  static let accentColor = "drakar.accentColor"
  /// Whether the editor sits left of the session; off, as the default, it opens to its right.
  static let editorLeads = "drakar.editorLeads"
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

  /// The model new sessions start with, from Settings; nil for Claude Code's default.
  static var defaultModel: String? {
    _ = AttentionDefaults.shared.revision
    return stored(PreferenceKey.defaultModel)
  }

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
      case .transcript: TranscriptPane()
      case .theme: ThemePane()
      case .attention: AttentionPane()
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
  @AppStorage(PreferenceKey.codexDefaultMode) private var codexDefaultMode = ""
  @AppStorage(PreferenceKey.allowsBypass) private var allowsBypass = true
  @AppStorage(PreferenceKey.editorLeads) private var editorLeads = false
  @State private var codexPath: String?

  var body: some View {
    Form {
      Section {
        Picker("New sessions run", selection: $defaultAgent) {
          ForEach(AgentKind.allCases, id: \.self) { agent in
            Text(agent.name).tag(agent.rawValue)
          }
        }
        .accessibilityIdentifier("settings.defaultAgent")
        LabeledContent("Codex") {
          Text(
            codexPath.map { ContentView.abbreviated(URL(filePath: $0)) }
              ?? String(localized: "Not found: brew install --cask codex"))
        }
        Picker("Mode for new Codex sessions", selection: $codexDefaultMode) {
          ForEach(CodexPolicy.offeredModes(allowsBypass: allowsBypass), id: \.self) { mode in
            Text(mode.title).tag(mode == .ask ? "" : mode.rawValue)
          }
          if codexDefaultMode == PermissionMode.bypass.rawValue, !allowsBypass {
            Text("Bypass permissions, not allowed").tag(codexDefaultMode)
          }
        }
        .accessibilityIdentifier("settings.codexDefaultMode")
      } footer: {
        Text("⌥-click New Session, or press ⌃⌘N, to start the other one.")
      }
      .task {
        let environment = await AgentSession.environment.value
        codexPath = CodexLaunch.locate(path: environment["PATH"])?.path(percentEncoded: false)
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
      ClaudeSection()
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

/// Which `claude` runs, and under which account a new session starts.
private struct ClaudeSection: View {
  @AppStorage(PreferenceKey.claudePath) private var claudePath = ""
  @AppStorage(PreferenceKey.newSessionAccount) private var accountPath = ""
  @AppStorage(PreferenceKey.allowsBypass) private var allowsBypass = true
  @AppStorage(PreferenceKey.defaultModel) private var defaultModel = ""
  @AppStorage(PreferenceKey.defaultMode) private var defaultMode = ""
  @AppStorage(PreferenceKey.defaultEffort) private var defaultEffort = ""
  @AppStorage(PreferenceKey.showsLegacyModels) private var showsLegacyModels = false
  /// The login shell's `CLAUDE_CONFIG_DIR`, for the account whose models are listed.
  @State private var shellDirectory: String?
  @State private var installs: [Install] = []
  @State private var accounts: [ClaudeAccount] = []
  /// The account the login shell selects, for the first choice's label.
  @State private var shellAccount = "default"
  @State private var isLoaded = false

  struct Install {
    var url: URL
    var version: ClaudeVersion?
    var path: String { url.path(percentEncoded: false) }
  }

  var body: some View {
    Section {
      Picker("Claude Code", selection: $claudePath) {
        Text(installs.first.map { "Automatic: \(label($0))" } ?? "Automatic").tag("")
        ForEach(installs, id: \.path) { install in
          Text(label(install)).tag(install.path)
        }
        if !claudePath.isEmpty, !installs.contains(where: { $0.path == claudePath }) {
          Text(isLoaded ? "\(abbreviated(claudePath)), not found" : abbreviated(claudePath))
            .tag(claudePath)
        }
      }
      .accessibilityIdentifier("settings.claudePath")
      if let version = running?.version, let drift = version.drift {
        Label(warning(version, drift), systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
      Picker("Account for new sessions", selection: $accountPath) {
        Text("As the shell sets it: \(shellAccount)").tag("")
        ForEach(accounts, id: \.self) { account in
          Text("\(account.name), in \(abbreviated(account.directory.path(percentEncoded: false)))")
            .tag(account.directory.path(percentEncoded: false))
        }
        if !accountPath.isEmpty,
          !accounts.contains(where: { $0.directory.path(percentEncoded: false) == accountPath })
        {
          Text(isLoaded ? "\(abbreviated(accountPath)), not found" : abbreviated(accountPath))
            .tag(accountPath)
        }
      }
      .accessibilityIdentifier("settings.newSessionAccount")
      Picker("Model for new sessions", selection: $defaultModel) {
        Text("Claude Code's default").tag("")
        let models = modelAccount.flatMap { ModelCatalog.shared.models(for: $0) }
        // "Default (recommended)" is the first choice already.
        ForEach(
          ClaudeChoice.offered(models ?? [], keeping: defaultModel).filter {
            $0.value != "default"
          }
        ) { option in
          Text(option.displayName).tag(option.value)
        }
        if !defaultModel.isEmpty, models?.contains(where: { $0.value == defaultModel }) != true {
          Text(models == nil ? defaultModel : "\(defaultModel), not offered").tag(defaultModel)
        }
      }
      .accessibilityIdentifier("settings.defaultModel")
      .task(id: modelAccount?.key) {
        if let modelAccount {
          ModelCatalog.shared.load(
            folder: FileManager.default.homeDirectoryForCurrentUser, account: modelAccount)
        }
      }
      Toggle("Offer older models", isOn: $showsLegacyModels)
        .accessibilityIdentifier("settings.showsLegacyModels")
      Text(
        "Pinned versions such as Opus 4.8, below the current Opus, Sonnet, Fable and Haiku. A session already on one keeps it in its menu."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Picker("Effort for new sessions", selection: $defaultEffort) {
        Text("Claude Code's default").tag("")
        ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { level in
          Text(EffortLevel.title(of: level)).tag(level)
        }
      }
      .accessibilityIdentifier("settings.defaultEffort")
      Text(
        "Claude Code's default is the effortLevel in its settings.json, else the model's own. A model without effort, such as Haiku, ignores it."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Picker("Mode for new sessions", selection: $defaultMode) {
        Text("Claude Code's default").tag("")
        ForEach(PermissionMode.allCases.filter { $0 != .bypass || allowsBypass }, id: \.self) {
          mode in
          Text(mode.title).tag(mode.rawValue)
        }
        if defaultMode == PermissionMode.bypass.rawValue, !allowsBypass {
          Text("Bypass permissions, not allowed").tag(defaultMode)
        }
      }
      .accessibilityIdentifier("settings.defaultMode")
      Text("Auto falls back to Ask before edits on a model without it.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Toggle("Allow Bypass permissions", isOn: $allowsBypass)
        .accessibilityIdentifier("settings.allowsBypass")
      Text(
        "Sessions start with --allow-dangerously-skip-permissions, so Bypass can be picked in the composer."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    } header: {
      Text("Claude Code")
    } footer: {
      Text(
        "Automatic runs the first `claude` on your shell’s PATH, as a terminal would. A resumed session always runs under the account that wrote it. Both apply to sessions started from now on."
      )
    }
    .task { await load() }
  }

  /// The account new sessions take, whose models the model picker lists: Settings', else the
  /// shell's once it is read.
  private var modelAccount: ClaudeAccount? {
    if !accountPath.isEmpty { return ClaudeChoice.account(at: accountPath) }
    guard isLoaded else { return nil }
    return ClaudeChoice.account(
      at: shellDirectory
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        .path(percentEncoded: false))
  }

  /// The install sessions will run: the one picked while it is there, else the first.
  private var running: Install? {
    installs.first { $0.path == claudePath } ?? (claudePath.isEmpty ? installs.first : nil)
  }

  private func label(_ install: Install) -> String {
    let path = abbreviated(install.path)
    return install.version.map { "\(path), \($0)" } ?? path
  }

  private func warning(_ version: ClaudeVersion, _ drift: ClaudeVersion.Drift) -> String {
    let tested = ClaudeVersion.tested
    return switch drift {
    case .older:
      String(
        localized:
          "\(version.description) is older than the versions Drakar was tested with (\(tested.lowerBound.description) to \(tested.upperBound.description)): it may not understand everything Drakar sends."
      )
    case .newer:
      String(
        localized:
          "\(version.description) is newer than the versions Drakar was tested with (\(tested.lowerBound.description) to \(tested.upperBound.description)): some of what it says may not show."
      )
    }
  }

  private func abbreviated(_ path: String) -> String {
    ContentView.abbreviated(URL(filePath: path))
  }

  private func load() async {
    let environment = await AgentSession.environment.value
    let urls = await Task.detached { ClaudeLocator.installed(path: environment["PATH"]) }.value
    // Each asked at once: an npm install takes a while to answer.
    installs = await withTaskGroup(of: (Int, Install).self) { group in
      for (index, url) in urls.enumerated() {
        group.addTask {
          (
            index,
            Install(url: url, version: await ClaudeVersion.read(of: url, environment: environment))
          )
        }
      }
      var found: [(Int, Install)] = []
      for await item in group { found.append(item) }
      return found.sorted { $0.0 < $1.0 }.map(\.1)
    }
    let shellDirectory = environment["CLAUDE_CONFIG_DIR"]
    accounts = await Task.detached {
      ClaudeAccount.discover(
        extra: shellDirectory.map { [URL(filePath: $0, directoryHint: .isDirectory)] } ?? [])
    }.value
    shellAccount = shellDirectory.map { ClaudeChoice.account(at: $0).name } ?? "default"
    self.shellDirectory = shellDirectory
    isLoaded = true
  }
}

#Preview {
  SettingsView()
}
