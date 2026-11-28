import DrakarKit
import SwiftUI

/// Settings › Models: per-provider executables and their versions and updates, accounts,
/// default models, effort and permission modes for new sessions, grouped by provider.
struct ModelsSettingsPane: View {
  @AppStorage(PreferenceKey.codexTitleModel) private var codexTitleModel = ""
  @AppStorage(PreferenceKey.codexDefaultModel) private var codexDefaultModel = ""
  @AppStorage(PreferenceKey.codexDefaultMode) private var codexDefaultMode = ""
  @AppStorage(PreferenceKey.agyDefaultModel) private var agyDefaultModel = ""
  @AppStorage(PreferenceKey.agyDefaultMode) private var agyDefaultMode = ""
  @AppStorage(PreferenceKey.grokDefaultModel) private var grokDefaultModel = ""
  @AppStorage(PreferenceKey.grokDefaultMode) private var grokDefaultMode = ""
  @AppStorage(PreferenceKey.allowsBypass) private var allowsBypass = true

  @State private var codexPath: String?
  @State private var agyPath: String?
  @State private var grokPath: String?

  var body: some View {
    Form {
      ClaudeSection()
      ProviderSection(
        agent: .codex,
        path: codexPath,
        notFound: "Not found: brew install --cask codex",
        defaultModelLabel: "Codex's default",
        modelSelection: $codexDefaultModel,
        models: ModelCatalog.shared.codexModels,
        modelIdentifier: "settings.codexDefaultModel"
      ) {
        Picker("Session title model", selection: $codexTitleModel) {
          Text("Off").tag("")
          Text("Automatic").tag(CodexTitle.automatic)
          ForEach(ModelCatalog.shared.codexModels ?? []) { model in
            Text(model.displayName).tag(model.value)
          }
          if !codexTitleModel.isEmpty, codexTitleModel != CodexTitle.automatic,
            ModelCatalog.shared.codexModels?.contains(where: { $0.value == codexTitleModel })
              != true
          {
            Text(codexTitleModel).tag(codexTitleModel)
          }
        }
        .accessibilityIdentifier("settings.codexTitleModel")
        Text("Uses one extra Codex request to title each new session.")
          .font(.caption)
          .foregroundStyle(.secondary)
        DefaultModePicker(
          defaultLabel: nil,
          emptyTagMode: .ask,
          selection: $codexDefaultMode,
          modes: CodexPolicy.offeredModes(allowsBypass: allowsBypass),
          allowsBypass: allowsBypass,
          identifier: "settings.codexDefaultMode")
      }
      ProviderSection(
        agent: .agy,
        path: agyPath,
        notFound: "Not found: install agy",
        defaultModelLabel: "Antigravity's default",
        modelSelection: $agyDefaultModel,
        models: ModelCatalog.shared.agyModels,
        modelIdentifier: "settings.agyDefaultModel"
      ) {
        DefaultModePicker(
          defaultLabel: "Antigravity's default",
          emptyTagMode: nil,
          selection: $agyDefaultMode,
          modes: AgyPolicy.offeredModes(allowsBypass: allowsBypass),
          allowsBypass: allowsBypass,
          identifier: "settings.agyDefaultMode")
      }
      ProviderSection(
        agent: .grok,
        path: grokPath,
        notFound: "Not found: install grok",
        defaultModelLabel: "Grok's default",
        modelSelection: $grokDefaultModel,
        models: ModelCatalog.shared.grokModels,
        modelIdentifier: "settings.grokDefaultModel"
      ) {
        DefaultModePicker(
          defaultLabel: "Grok's default",
          emptyTagMode: nil,
          selection: $grokDefaultMode,
          modes: GrokPolicy.offeredModes(allowsBypass: allowsBypass),
          allowsBypass: allowsBypass,
          identifier: "settings.grokDefaultMode")
      }
    }
    .formStyle(.grouped)
    .task {
      let environment = await AgentSession.environment.value
      codexPath = CodexLaunch.locate(path: environment["PATH"])?.path(percentEncoded: false)
      agyPath = AgyLaunch.locate(path: environment["PATH"])?.path(percentEncoded: false)
      grokPath = AgyLaunch.locate(path: environment["PATH"], binary: "grok")?.path(
        percentEncoded: false)
      ModelCatalog.shared.loadCodex()
      ModelCatalog.shared.loadAgy()
      ModelCatalog.shared.loadGrok()
    }
  }
}

/// Which `claude` runs, under which account, and what new Claude Code sessions start with.
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
    var version: CLIVersion?
    var path: String { url.path(percentEncoded: false) }
  }

  var body: some View {
    Section {
      Picker("Command", selection: $claudePath) {
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
      VersionRow(
        agent: .claude, executable: effectiveInstall,
        claudeDirectory: accountPath.isEmpty
          ? nil : URL(filePath: accountPath, directoryHint: .isDirectory)
      )
      .onChange(of: effectiveInstall.map { CLIUpdates.shared.status(of: $0).installed }) {
        _, new in
        // An update replaced the binary: the Command picker's versions are stale.
        guard let new, let url = effectiveInstall,
          let listed = installs.first(where: { $0.path == url.path(percentEncoded: false) }),
          listed.version != new
        else { return }
        Task { await load() }
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
      AgentModelPicker(
        defaultLabel: "Claude Code's default",
        selection: $defaultModel,
        models: offeredModels,
        identifier: "settings.defaultModel"
      )
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
      DefaultModePicker(
        defaultLabel: "Claude Code's default",
        emptyTagMode: nil,
        selection: $defaultMode,
        modes: PermissionMode.allCases.filter { $0 != .bypass || allowsBypass },
        allowsBypass: allowsBypass,
        identifier: "settings.defaultMode")
      Text("Auto falls back to Ask before edits on a model without it.")
        .font(.caption)
        .foregroundStyle(.secondary)
    } header: {
      ProviderHeader(agent: .claude)
    } footer: {
      Text(
        "Automatic runs the first `claude` on your shell’s PATH, as a terminal would. A resumed session always runs under the account that wrote it. Both apply to sessions started from now on."
      )
    }
    .task { await load() }
  }

  /// The install new sessions run: Settings' choice, else the first on the PATH.
  private var effectiveInstall: URL? {
    if !claudePath.isEmpty {
      guard !isLoaded || installs.contains(where: { $0.path == claudePath }) else { return nil }
      return URL(filePath: claudePath)
    }
    return installs.first?.url
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

  private var offeredModels: [ModelOption]? {
    modelAccount
      .flatMap { ModelCatalog.shared.models(for: $0) }
      .map { models in
        // "Default (recommended)" is the first choice already.
        ClaudeChoice.offered(models, keeping: defaultModel).filter { $0.value != "default" }
      }
  }

  private func label(_ install: Install) -> String {
    let path = abbreviated(install.path)
    return install.version.map { "\(path), \($0)" } ?? path
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
            Install(url: url, version: await CLIVersion.read(of: url, environment: environment))
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

/// Shared grouped section for non-Claude providers (Codex, Antigravity, Grok).
private struct ProviderSection<Extra: View>: View {
  let agent: AgentKind
  let path: String?
  let notFound: LocalizedStringKey
  let defaultModelLabel: LocalizedStringKey
  @Binding var modelSelection: String
  let models: [ModelOption]?
  let modelIdentifier: String
  @ViewBuilder let extra: () -> Extra

  var body: some View {
    Section {
      LabeledContent("Command") {
        if let path {
          Text(ContentView.abbreviated(URL(filePath: path)))
        } else {
          Text(notFound)
        }
      }
      VersionRow(agent: agent, executable: path.map { URL(filePath: $0) })
      AgentModelPicker(
        defaultLabel: defaultModelLabel,
        selection: $modelSelection,
        models: models,
        identifier: modelIdentifier)
      extra()
    } header: {
      ProviderHeader(agent: agent)
    }
  }
}

/// The installed version beside the newest published, with the CLI's own `update` one click
/// away. Checks when shown, at most once per `CLIUpdates.freshness`.
private struct VersionRow: View {
  let agent: AgentKind
  let executable: URL?
  var claudeDirectory: URL?

  private var updates: CLIUpdates { .shared }

  var body: some View {
    if let executable {
      let status = updates.status(of: executable)
      LabeledContent("Version") {
        HStack(spacing: 8) {
          if status.isUpdating {
            ProgressView().controlSize(.small)
            Text("Updating\(status.latest.map { " to \($0.description)" } ?? "")…")
          } else {
            Group {
              if let installed = status.installed {
                Text(installed.description)
              } else {
                Text(status.hasRead ? "Unknown" : "…")
              }
            }
            .monospacedDigit()
            detail(status)
            actions(status, executable: executable)
          }
        }
      }
      .accessibilityIdentifier("settings.\(agent.rawValue)Version")
      .task(
        id:
          "\(executable.path(percentEncoded: false))|\(claudeDirectory?.path(percentEncoded: false) ?? "")"
      ) {
        updates.check(agent: agent, executable: executable, claudeDirectory: claudeDirectory)
      }
      if let message = status.message {
        Text(LocalizedStringKey(message))
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  @ViewBuilder private func detail(_ status: CLIUpdates.Status) -> some View {
    if status.isChecking {
      ProgressView().controlSize(.mini)
    } else if status.isUpdateAvailable, let latest = status.latest {
      Text("\(latest.description) available")
        .foregroundStyle(.tint)
    } else if status.checkFailed {
      Text("Couldn’t check")
        .foregroundStyle(.secondary)
        .help(
          "The newest version could not be read. Update still runs `\(command)`, which checks for itself."
        )
    } else if status.latest != nil {
      Text("Up to date")
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private func actions(_ status: CLIUpdates.Status, executable: URL) -> some View {
    if status.isUpdateAvailable || (status.checkFailed && !status.isChecking) {
      Button("Update") {
        updates.update(agent: agent, executable: executable, claudeDirectory: claudeDirectory)
      }
      .controlSize(.small)
      .help("Runs `\(command)`. Sessions already running keep the version they started with.")
      .accessibilityIdentifier("settings.\(agent.rawValue)Update")
    }
    if !status.isChecking {
      Button {
        updates.check(
          agent: agent, executable: executable, claudeDirectory: claudeDirectory, force: true)
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .help("Check for Updates")
      .accessibilityLabel("Check for Updates")
      .accessibilityIdentifier("settings.\(agent.rawValue)CheckUpdates")
    }
  }

  private var command: String {
    "\(executable?.lastPathComponent ?? agent.rawValue) update"
  }
}

private struct ProviderHeader: View {
  let agent: AgentKind

  var body: some View {
    HStack(spacing: 6) {
      AgentAppIcon(agent: agent)
      Text(agent.name)
    }
  }
}

/// Model picker shared across providers, keeping any previously chosen model id visible while
/// the list loads or if the server stops offering it.
private struct AgentModelPicker: View {
  let defaultLabel: LocalizedStringKey
  @Binding var selection: String
  let models: [ModelOption]?
  let identifier: String

  var body: some View {
    Picker("Model for new sessions", selection: $selection) {
      Text(defaultLabel).tag("")
      ForEach(models ?? []) { option in
        Text(option.displayName).tag(option.value)
      }
      if !selection.isEmpty, models?.contains(where: { $0.value == selection }) != true {
        Text(models == nil ? selection : "\(selection), not offered").tag(selection)
      }
    }
    .accessibilityIdentifier(identifier)
  }
}

/// Permission mode picker shared across providers that offer a default mode setting.
private struct DefaultModePicker: View {
  let defaultLabel: LocalizedStringKey?
  let emptyTagMode: PermissionMode?
  @Binding var selection: String
  let modes: [PermissionMode]
  let allowsBypass: Bool
  let identifier: String

  var body: some View {
    Picker("Mode for new sessions", selection: $selection) {
      if let defaultLabel {
        Text(defaultLabel).tag("")
      }
      ForEach(modes, id: \.self) { mode in
        Text(mode.title).tag(mode == emptyTagMode ? "" : mode.rawValue)
      }
      if selection == PermissionMode.bypass.rawValue, !allowsBypass {
        Text("Bypass permissions, not allowed").tag(selection)
      }
    }
    .accessibilityIdentifier(identifier)
  }
}

#Preview {
  ModelsSettingsPane()
}
