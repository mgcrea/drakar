import Foundation

/// What a runner's relay states before it copies a byte (spec §1): one JSON line on stdout,
/// read by the Mac before anything of the host's. Everything the Mac needs to know about the
/// runner without parsing HostWire through it, or running anything else there.
public struct RunnerFacts: Codable, Equatable, Sendable {
  /// The relay's own protocol, which moves independently of HostWire's.
  public static let relayVersion = 1

  public var relay: Int
  /// The runner's Drakar: its version and its build.
  public var drakar: String
  public var build: String
  /// The HostWire majors this build speaks.
  public var hostMajors: [Int]
  public var home: String
  public var user: String
  public var hostname: String
  /// The runner's GUI session environment, where the host and every `claude` run, not the
  /// ssh session's the relay runs in.
  public var environment: [String: String]
  public var environmentFrom: EnvironmentSource
  /// Every `claude` the runner has, as Settings lists them locally.
  public var claude: [ClaudeCandidate]
  /// The runner's Claude config directories, as paths.
  public var accounts: [String]

  public init(
    relay: Int = relayVersion, drakar: String, build: String, hostMajors: [Int], home: String,
    user: String, hostname: String, environment: [String: String],
    environmentFrom: EnvironmentSource, claude: [ClaudeCandidate], accounts: [String]
  ) {
    self.relay = relay
    self.drakar = drakar
    self.build = build
    self.hostMajors = hostMajors
    self.home = home
    self.user = user
    self.hostname = hostname
    self.environment = environment
    self.environmentFrom = environmentFrom
    self.claude = claude
    self.accounts = accounts
  }

  /// One JSON object and its newline. The encoder escapes a newline inside a value, so the
  /// only raw one is the last byte, and the bytes after it are the host's.
  public func line() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(self) + Data("\n".utf8)
  }

  /// A line of any other shape throws: a relay that states something else is not one this
  /// build can talk to.
  public static func parse(_ line: Data) throws -> RunnerFacts {
    try JSONDecoder().decode(RunnerFacts.self, from: line)
  }
}

/// Where the facts' environment came from.
public enum EnvironmentSource: String, Codable, Sendable {
  /// The file the runner's app writes from its GUI session.
  case gui
  /// The relay's own login shell, without the ssh session's variables: the file was missing.
  case ssh
}

/// One `claude` found on the runner.
public struct ClaudeCandidate: Codable, Equatable, Sendable {
  public var path: String
  /// Nil when it did not say.
  public var version: String?

  public init(path: String, version: String?) {
    self.path = path
    self.version = version
  }
}

/// The runner's GUI session environment, kept on disk for the relay (spec §1). The relay runs
/// in an ssh session, whose environment is not the one the host and every `claude` get; the
/// runner's app writes its own at each launch and the relay reads it. The app's file, not the
/// host's: the host neither writes nor reads it.
public enum RunnerEnvironment {
  public static let fileName = "runner-environment.json"

  /// `appSupport` is the app's Application Support directory, the parent of the host's.
  public static func file(in appSupport: URL) -> URL {
    appSupport.appendingPathComponent(fileName)
  }

  /// Owner's only from the moment it exists, and replaced whole: a relay reading it at the
  /// same time sees the old file or the new one, never half of either. It holds the person's
  /// `SSH_AUTH_SOCK` and whatever secrets their shell exports.
  public static func write(_ environment: [String: String], to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(environment)
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(".\(fileName).\(UUID().uuidString)")
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      try handle.close()
      guard rename(temporary.path, url.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch {
      unlink(temporary.path)
      throw error
    }
  }

  /// Nil when the file is missing or unreadable; the relay then falls back to `withoutSSH`.
  public static func read(from url: URL) -> [String: String]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode([String: String].self, from: data)
  }

  /// The ssh session's own variables, which mean nothing to the GUI session: its agent socket
  /// is dead once the session closes, and a `git push` from the runner needs the GUI's.
  public static func withoutSSH(_ environment: [String: String]) -> [String: String] {
    let session: Set = ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY", "SSH_AUTH_SOCK"]
    return environment.filter { !session.contains($0.key) }
  }
}
