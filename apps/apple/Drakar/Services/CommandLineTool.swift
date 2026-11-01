import DrakarKit
import Foundation

/// The `drakar` command: `drakar.sh` in the app's resources, linked into a folder on the
/// login shell's PATH, as VS Code links `code`.
enum CommandLineTool {
  static let name = "drakar"

  /// The script inside this copy of Drakar.
  static var bundledScript: URL? { Bundle.main.url(forResource: "drakar", withExtension: "sh") }

  /// Where the link goes: `~/.local/bin` when the login shell's `path` has it, since that
  /// needs no administrator; `/usr/local/bin` otherwise, which every Mac's `/etc/paths` has.
  static func directory(path: String?, home: URL) -> URL {
    let local = home.appending(path: ".local/bin")
    let wanted = ProjectPath.normalize(local)
    let entries = (path ?? "").split(separator: ":").map { ProjectPath.normalize(String($0)) }
    return entries.contains(wanted)
      ? local : URL(filePath: "/usr/local/bin")
  }

  /// Whether `directory/drakar` is a link to `script`.
  static func isInstalled(script: URL, in directory: URL) -> Bool {
    let link = directory.appending(path: name).path(percentEncoded: false)
    return (try? FileManager.default.destinationOfSymbolicLink(atPath: link))
      == script.path(percentEncoded: false)
  }

  /// `install` as one shell command, for `do shell script … with administrator privileges`
  /// when `directory` is not writable (`/usr/local/bin` is root's on a Mac with no Intel
  /// Homebrew). It fails rather than replace a real file, as `install` does.
  static func privilegedCommand(script: URL, in directory: URL) -> String {
    func quoted(_ url: URL) -> String {
      "'" + url.path(percentEncoded: false).replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
    let link = quoted(directory.appending(path: name))
    return "mkdir -p \(quoted(directory)) && { [ ! -e \(link) ] || [ -L \(link) ]; } && "
      + "ln -sfn \(quoted(script)) \(link)"
  }

  /// `privilegedCommand` as an AppleScript, which asks for an administrator's password.
  static func appleScript(script: URL, in directory: URL) -> String {
    let command = privilegedCommand(script: script, in: directory)
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "do shell script \"\(command)\" with administrator privileges"
  }

  /// Runs `appleScript` in `osascript`: a process of its own, so every window keeps drawing
  /// while the password dialog waits. Nil once linked, or when the person cancels;
  /// otherwise what went wrong.
  static func installAsAdministrator(script: URL, in directory: URL) async -> String? {
    let source = appleScript(script: script, in: directory)
    guard
      let result = try? await ProcessRunner.run(
        URL(filePath: "/usr/bin/osascript"), ["-e", source], timeout: .seconds(600))
    else { return String(localized: "osascript could not start.") }
    guard result.status != 0 else { return nil }
    let errors = String(decoding: result.errors, as: UTF8.self)
    // -128: the dialog's Cancel.
    return errors.contains("(-128)") ? nil : errors.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Links `directory/drakar` to `script`, creating `directory` if needed and taking over
  /// a link that points elsewhere (a Drakar since moved, or another copy). A real file
  /// there is someone else's: that throws, and it is left alone.
  static func install(script: URL, in directory: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let link = directory.appending(path: name)
    let path = link.path(percentEncoded: false)
    if (try? manager.destinationOfSymbolicLink(atPath: path)) != nil {
      try manager.removeItem(at: link)
    }
    try manager.createSymbolicLink(
      atPath: path, withDestinationPath: script.path(percentEncoded: false))
  }
}
