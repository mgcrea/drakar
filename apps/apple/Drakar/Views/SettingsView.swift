import DrakarKit
import SupportKitSettings
import SwiftUI

// MARK: - Settings

/// The panes, and the order they sit in.
///
/// About only, for now. A General pane joins with the app's first real preference
/// and goes first, with `defaultPane` moved to it; an empty pane shipped to fill
/// the sidebar is a pane somebody opens once. An entitlement pane joins only when
/// something is actually sold: before a StoreKit product is registered it would
/// be a button that fails.
///
/// About stays last, because it answers a question you only ask with a bug report
/// open.
enum SettingsPane: String, SupportKitSettings.SettingsPane {
  case general
  case transcript
  case about

  var title: LocalizedStringKey {
    switch self {
    case .general: "General"
    case .transcript: "Transcript"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .transcript: "text.bubble"
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
  /// Whether the last prompt stays pinned over the transcript even while it is in view.
  static let pinsLastPrompt = "drakar.pinsLastPrompt"
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
  @AppStorage(PreferenceKey.notifiesTurnEnds) private var notifiesTurnEnds = false

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
      Section {
        Toggle("Notify when a session finishes its turn", isOn: $notifiesTurnEnds)
          .accessibilityIdentifier("settings.notifiesTurnEnds")
      } footer: {
        Text("Sessions that need a permission always notify while Drakar is in the background.")
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
