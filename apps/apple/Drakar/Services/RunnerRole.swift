import DrakarKit
import Foundation
import OSLog

/// Whether this Mac takes sessions started from another Mac (spec §2): Settings › Runner's
/// "Let my other Macs start sessions here", off by default, in the app's own defaults domain,
/// which the relay shares.
///
/// While it is on, the app keeps its host up and writes the environment its sessions get. The
/// host is only ever started by the app, in the person's GUI session, never by the relay: one
/// started under sshd would run every `claude` without the login Keychain.
@MainActor final class RunnerRole {
  /// Off under tests: no test run writes the person's environment file or keeps their host
  /// up, whatever their own setting says.
  static let shared = RunnerRole(
    directory: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
      ? SessionHost.hostDirectory.deletingLastPathComponent() : nil)

  /// Not the main actor's: the relay reads it, and never runs the app.
  nonisolated static let acceptsKey = "runner.acceptsSessions"

  var accepts: Bool {
    get { defaults.bool(forKey: Self.acceptsKey) }
    set { defaults.set(newValue, forKey: Self.acceptsKey) }
  }

  private let defaults: UserDefaults
  /// The app's Application Support directory, the host's parent, where the relay reads the
  /// environment file. Nil writes none.
  private let directory: URL?
  private let host: SessionHost

  private static let log = Logger(subsystem: "io.mgcrea.Drakar", category: "runner")

  /// `defaults`, `directory` and `host` are for tests.
  init(defaults: UserDefaults = .standard, directory: URL?, host: SessionHost = .shared) {
    self.defaults = defaults
    self.directory = directory
    self.host = host
  }

  /// At launch and whenever the setting changes. On, the GUI session's environment is
  /// written for the relay to hand the Mac (spec §1), each launch, so a PATH the person
  /// changed reaches the next session; and the app stays connected to its host, so its idle
  /// exit never fires while the app runs. Off, the app stops reconnecting, and lets go of a
  /// connection only it was keeping.
  func apply() {
    guard accepts else { return host.stopKeepingConnected() }
    host.keepConnected()
    guard let directory else { return }
    Task {
      let environment = await AgentSession.environment.value
      // Turned off while the shell was read: nothing to write for.
      guard accepts else { return }
      do {
        try RunnerEnvironment.write(environment, to: RunnerEnvironment.file(in: directory))
      } catch {
        // The relay then falls back to the login shell ssh gives it, less ssh's own.
        Self.log.error(
          "runner environment not written: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}
