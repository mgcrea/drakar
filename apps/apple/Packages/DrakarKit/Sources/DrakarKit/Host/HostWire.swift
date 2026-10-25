import Foundation

/// What the app and the session host say to each other (spec §2). Newline-delimited JSON, one
/// request or event per line.
public enum HostWire {
  public static let major = 1, minor = 0

  /// The socket's path would not fit `sockaddr_un.sun_path`.
  public struct PathTooLong: Error, Equatable {
    public var path: String
  }

  /// Where the socket and the logs live: `<home>/Library/Application Support/<id>/host`.
  public static func directory(bundleID: String, home: URL) -> URL {
    home.appendingPathComponent("Library/Application Support", isDirectory: true)
      .appendingPathComponent(bundleID, isDirectory: true)
      .appendingPathComponent("host", isDirectory: true)
  }

  /// `sun_path` holds 104 bytes with its NUL; a longer path is refused, never truncated.
  public static func socket(in directory: URL, major: Int = major) throws -> URL {
    let url = directory.appendingPathComponent("host-v\(major).sock")
    guard url.path.utf8.count <= 103 else { throw PathTooLong(path: url.path) }
    return url
  }
}

/// One process the host holds, as `list` reports it.
public struct HeldProcess: Codable, Sendable, Equatable {
  public var id: String
  public var meta: Data
  public var running: Bool
  public var exitStatus: Int32?
  public var logLength: UInt64
  /// The pid of the app attached to it, if any.
  public var attachedApp: Int32?

  public init(
    id: String, meta: Data, running: Bool, exitStatus: Int32? = nil, logLength: UInt64,
    attachedApp: Int32? = nil
  ) {
    self.id = id
    self.meta = meta
    self.running = running
    self.exitStatus = exitStatus
    self.logLength = logLength
    self.attachedApp = attachedApp
  }
}

public enum HostRequest: Codable, Sendable, Equatable {
  case hello(protocol: Int, appVersion: String)
  case list
  case spawn(AgentProcess.Configuration, meta: Data)
  case attach(id: String, from: UInt64)
  case write(id: String, bytes: Data)
  /// Logged as a `note` and written to nothing: the app's own marks for its replay.
  case note(id: String, bytes: Data)
  case closeInput(id: String)
  case terminate(id: String)
  case setMeta(id: String, meta: Data)
  case acknowledge(id: String)
}

public enum HostEvent: Codable, Sendable, Equatable {
  case welcome(protocol: Int, hostVersion: String, pid: Int32)
  case listed([HeldProcess])
  case spawned(id: String)
  case record(id: String, HostRecord)
  /// The attach's backlog is sent; what follows is live.
  case caughtUp(id: String, offset: UInt64)
  case stderr(id: String, text: String)
  case exited(id: String, status: Int32)
  case released(id: String)
  case refused(reason: String)
}
