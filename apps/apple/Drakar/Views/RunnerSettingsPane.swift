import DrakarKit
import Foundation
import SwiftUI

/// What Settings › Runner edits (remote sessions spec §2, §3): this Mac's opt-in to be a
/// runner, and the runner this Mac uses. The fields are saved only by Save, which replaces the
/// runner's host; Test reaches the runner as typed and lets it go again.
@MainActor @Observable final class RunnerPaneModel {
  /// Where Test stands.
  enum Check: Equatable {
    case idle
    case testing
    case passed(RunnerFacts)
    case failed(RunnerFailure)
  }

  var name = ""
  /// A Test's result is of the runner it reached: another destination or path clears it.
  var destination = "" {
    didSet { if destination != oldValue { check = .idle } }
  }
  var drakarPath = RunnerSettings.defaultDrakarPath {
    didSet { if drakarPath != oldValue { check = .idle } }
  }
  private(set) var check = Check.idle

  /// "Let my other Macs start sessions here", applied at each change.
  var accepts: Bool {
    didSet {
      guard accepts != oldValue else { return }
      role.accepts = accepts
      role.apply()
    }
  }

  /// The runner as typed, saved or not.
  var typed: RunnerSettings {
    let path = drakarPath.trimmingCharacters(in: .whitespacesAndNewlines)
    return RunnerSettings(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      destination: destination.trimmingCharacters(in: .whitespacesAndNewlines),
      drakarPath: path.isEmpty ? RunnerSettings.defaultDrakarPath : path)
  }

  /// The fields say something other than what is saved; no destination says no runner.
  var canSave: Bool {
    let typed = typed
    return (typed.destination.isEmpty ? nil : typed) != saved
  }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let role: RunnerRole
  @ObservationIgnored private let install: @MainActor (RunnerSettings?) -> Void
  @ObservationIgnored private let open:
    @MainActor (RunnerSettings) async throws(RunnerFailure) -> RunnerConnection.Opened
  private var saved: RunnerSettings?

  /// The app's own of each unless a test gives its own: `install` puts the runner's host in
  /// `SessionHost.runner`, `open` reaches the runner.
  init(
    defaults: UserDefaults = .standard, role: RunnerRole = .shared,
    install: @escaping @MainActor (RunnerSettings?) -> Void = SessionHost.useRunner,
    open:
      @escaping @MainActor (RunnerSettings) async throws(RunnerFailure) -> RunnerConnection.Opened =
      RunnerConnection.open
  ) {
    self.defaults = defaults
    self.role = role
    self.install = install
    self.open = open
    accepts = role.accepts
    saved = RunnerSettings.read(from: defaults)
    if let saved {
      name = saved.name
      destination = saved.destination
      drakarPath = saved.drakarPath
    }
  }

  /// Keeps the fields, and puts a host for them in place of the runner's before.
  func save() {
    RunnerSettings.write(typed, to: defaults)
    saved = RunnerSettings.read(from: defaults)
    install(saved)
  }

  /// Connects to the runner as typed, keeps its facts, and closes the connection and its ssh
  /// at once: a check, not the runner's host. A runner left unnamed is named after its
  /// hostname.
  func test() async {
    let settings = typed
    guard !settings.destination.isEmpty, check != .testing else { return }
    check = .testing
    let outcome: Check
    do {
      let (client, facts, ssh) = try await open(settings)
      client.close()
      RunnerConnection.end(ssh)
      outcome = .passed(facts)
    } catch {
      outcome = .failed(error)
    }
    // Typed over meanwhile: what came back is of a runner no longer named here.
    let now = typed
    guard now.destination == settings.destination, now.drakarPath == settings.drakarPath else {
      return
    }
    check = outcome
    if case .passed(let facts) = outcome, now.name.isEmpty { name = facts.hostname }
  }
}

/// Settings › Runner: this Mac taking sessions from the person's other Macs, and the Mac this
/// one starts its sessions on.
struct RunnerSettingsPane: View {
  @State private var model = RunnerPaneModel()

  var body: some View {
    Form {
      Section {
        Toggle("Let my other Macs start sessions here", isOn: $model.accepts)
          .accessibilityIdentifier("settings.runnerAccepts")
      } header: {
        Text("This Mac as a runner")
      } footer: {
        Text(
          "Sessions started from another Mac run here, under this Mac's login and its Claude Code."
        )
      }
      Section {
        TextField("Name", text: $model.name, prompt: Text("The runner’s hostname"))
          .accessibilityIdentifier("settings.runnerName")
        TextField(
          "ssh destination", text: $model.destination, prompt: Text("studio or me@studio.local")
        )
        .accessibilityIdentifier("settings.runnerDestination")
        TextField(
          "Drakar on the runner", text: $model.drakarPath,
          prompt: Text(RunnerSettings.defaultDrakarPath)
        )
        .accessibilityIdentifier("settings.runnerDrakarPath")
        HStack {
          Spacer()
          Button("Test") { Task { await model.test() } }
            .disabled(model.typed.destination.isEmpty || model.check == .testing)
            .accessibilityIdentifier("settings.runnerTest")
          Button("Save") { model.save() }
            .disabled(!model.canSave)
            .accessibilityIdentifier("settings.runnerSave")
        }
        RunnerCheckRows(check: model.check, name: model.typed.displayName)
      } header: {
        Text("Use a runner")
      } footer: {
        Text(
          "Anything ssh takes: an alias from ~/.ssh/config, or user@host. ssh cannot ask for a passphrase here, so its key must need none or be in the agent. Leave it empty for no runner."
        )
      }
    }
    .formStyle(.grouped)
  }
}

/// What Test found: the runner's facts, or why it could not be reached and what ssh said.
private struct RunnerCheckRows: View {
  let check: RunnerPaneModel.Check
  let name: String

  var body: some View {
    switch check {
    case .idle:
      EmptyView()
    case .testing:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Connecting to \(name)…")
          .foregroundStyle(.secondary)
      }
    case .passed(let facts):
      LabeledContent("Drakar", value: "\(facts.drakar) (\(facts.build))")
      LabeledContent("Claude Code") {
        Text(
          facts.claude.isEmpty
            ? String(localized: "Not found")
            : facts.claude.map { claude in
              let path = Self.abbreviated(claude.path, home: facts.home)
              return claude.version.map { "\(path), \($0)" } ?? path
            }.joined(separator: "\n"))
      }
      LabeledContent("Accounts") {
        Text(
          facts.accounts.isEmpty
            ? String(localized: "None")
            : facts.accounts.map { Self.abbreviated($0, home: facts.home) }
              .joined(separator: "\n"))
      }
      if facts.environmentFrom == .ssh {
        Label(
          "Open Drakar on the runner once, so its sessions get its desktop's environment",
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
      }
    case .failed(let failure):
      Label(failure.message, systemImage: "xmark.octagon.fill")
        .foregroundStyle(.red)
      let stderr = failure.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      if !stderr.isEmpty {
        Text(stderr)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  /// A path on the runner, its home as `~`: the runner's, not this Mac's.
  private static func abbreviated(_ path: String, home: String) -> String {
    guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
  }
}
