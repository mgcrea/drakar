import Foundation

/// The other Mac this one runs sessions on (spec §3), as Settings › Runner names it: what to
/// call it, the `ssh` destination that reaches it, and where Drakar is there. No destination
/// is no runner, and then nothing of it runs.
struct RunnerSettings: Codable, Equatable {
  /// What Home and every failure call it.
  var name: String
  /// Anything `ssh` takes: a `~/.ssh/config` alias, `user@host`.
  var destination: String
  /// Drakar's bundle on the runner.
  var drakarPath: String = defaultDrakarPath

  static let defaultDrakarPath = "/Applications/Drakar.app"

  static let key = "runner.settings"

  /// The `ssh` the person has, the only program Drakar runs to reach another Mac (spec §6).
  /// Tests put a script of their own here, and put this back after.
  static var sshExecutable = URL(filePath: "/usr/bin/ssh")

  /// The runner in the app's own defaults, nil when none is set.
  static var current: RunnerSettings? { read(from: .standard) }

  /// Nil when nothing is kept, it does not read, or its destination is empty.
  static func read(from defaults: UserDefaults) -> RunnerSettings? {
    guard let data = defaults.data(forKey: key),
      let settings = try? JSONDecoder().decode(RunnerSettings.self, from: data),
      !settings.destination.trimmingCharacters(in: .whitespaces).isEmpty
    else { return nil }
    return settings
  }

  /// Nil, or no destination, removes the runner.
  static func write(_ settings: RunnerSettings?, to defaults: UserDefaults) {
    guard let settings, !settings.destination.trimmingCharacters(in: .whitespaces).isEmpty,
      let data = try? JSONEncoder().encode(settings)
    else { return defaults.removeObject(forKey: key) }
    defaults.set(data, forKey: key)
  }

  /// Its name, or its destination when it has none yet.
  var displayName: String {
    let name = name.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? destination : name
  }
}
