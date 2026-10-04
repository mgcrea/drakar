import DrakarKit
import SupportKitSettings
import SwiftUI

// MARK: - Settings

/// The panes, and the order they sit in: General, Attention, About.
///
/// An entitlement pane joins only when something is actually sold: before a StoreKit
/// product is registered it would be a button that fails.
///
/// About stays last, because it answers a question you only ask with a bug report open.
enum SettingsPane: String, SupportKitSettings.SettingsPane {
  case general
  case attention
  case about

  var title: LocalizedStringKey {
    switch self {
    case .general: "General"
    case .attention: "Attention"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .attention: "bell.badge"
    case .about: "info.circle"
    }
  }

  static var defaultPane: SettingsPane { .general }
}

// MARK: - Preferences

/// The defaults keys, named the way every other key in the fleet is: the slug, then
/// the setting.
enum PreferenceKey {
  /// Which folders Drakar offers itself as the editor for, to `claude` run in a terminal.
  static let editorScope = "drakar.editorScope"
  /// The `claude` sessions run, by path; empty for the one the login shell would run.
  static let claudePath = "drakar.claudePath"
  /// The configuration directory a new session runs under; empty for the login shell's.
  static let newSessionAccount = "drakar.newSessionAccount"
  /// Whether a session that finishes its turn while Drakar is in the background says so.
  static let notifiesTurnEnds = "drakar.notifiesTurnEnds"
  /// Whether a turn that ends on a question or an offer marks its row.
  static let recognisesAsks = "drakar.recognisesAsks"
}

/// What Settings picked for the sessions Drakar starts.
enum ClaudeChoice {
  /// Where the choices are read from; a scratch suite in tests, never the real one.
  static var defaults = UserDefaults.standard

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
  /// In the group's header count and ⌥⌘↓.
  case counts
  case badges
  case notifies
}

enum AttentionChoice {
  /// Where the choices are read from; a scratch suite in tests, never the real one.
  static var defaults = UserDefaults.standard

  static var recognisesAsks: Bool {
    defaults.object(forKey: PreferenceKey.recognisesAsks) as? Bool ?? true
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
    defaults.object(forKey: key(level, feedback)) as? Bool ?? defaultValue(level, feedback)
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
      case .attention: AttentionPane()
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

  var body: some View {
    Form {
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
          "A reply that ends on a question, such as “Want me to build it that way?”, marks its session “Asked you”; one that ends on an offer marks it “Offered”. Either stays until you answer or dismiss it (⌥⌘D)."
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
              Text(level.title)
              ForEach(AttentionFeedback.allCases, id: \.self) { feedback in
                FeedbackToggle(level: level, feedback: feedback)
                  .disabled(!recognisesAsks && (level == .question || level == .offer))
              }
            }
          }
          GridRow {
            Text("Finished turn")
            Text("")
            Text("")
            Toggle("", isOn: $notifiesTurnEnds)
              .labelsHidden()
              .accessibilityIdentifier("settings.notifiesTurnEnds")
          }
        }
      } footer: {
        Text(
          "Counts puts the session in the sidebar's count and in Next Session Needing You (⌥⌘↓). Drakar notifies unless the session is the one you are looking at."
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
    } header: {
      Text("Claude Code")
    } footer: {
      Text(
        "Automatic runs the first `claude` on your shell’s PATH, as a terminal would. A resumed session always runs under the account that wrote it. Both apply to sessions started from now on."
      )
    }
    .task { await load() }
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
    let environment = await ClaudeSession.environment.value
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
    isLoaded = true
  }
}

#Preview {
  SettingsView()
}
