import Foundation

/// The other Mac this one runs sessions on (spec §3), as Settings › Runner names it: what to
/// call it, the `ssh` destination that reaches it, and where Drakar is there. No destination
/// is no runner, and then nothing of it runs.
struct RunnerSettings: Codable, Equatable {
  /// The runner's for as long as it is configured, whatever it is renamed or retargeted to:
  /// what the app keys this runner's things by. Made when it is first saved.
  var id: UUID
  /// What Home and every failure call it; for show only.
  var name: String
  /// Anything `ssh` takes: a `~/.ssh/config` alias, `user@host`.
  var destination: String
  /// Drakar's bundle on the runner.
  var drakarPath: String

  static let defaultDrakarPath = "/Applications/Drakar.app"

  init(
    id: UUID = UUID(), name: String, destination: String,
    drakarPath: String = defaultDrakarPath
  ) {
    self.id = id
    self.name = name
    self.destination = destination
    self.drakarPath = drakarPath
  }

  /// Settings kept before runners had an id are given one; `read` keeps it.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try container.decode(String.self, forKey: .name)
    destination = try container.decode(String.self, forKey: .destination)
    drakarPath =
      try container.decodeIfPresent(String.self, forKey: .drakarPath) ?? Self.defaultDrakarPath
  }

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
    // Kept without an id: the one just made is written, so the next read gives the same.
    struct Kept: Decodable { var id: UUID? }
    if (try? JSONDecoder().decode(Kept.self, from: data))?.id == nil {
      write(settings, to: defaults)
    }
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
