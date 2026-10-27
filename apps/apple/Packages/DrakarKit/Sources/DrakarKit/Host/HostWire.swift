import Foundation

/// What the app and the session host say to each other (spec §2). Newline-delimited JSON, one
/// request or event per line.
public enum HostWire {
  public static let major = 1, minor = 3

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
  /// `bytes` go to stdin; `logged`, when there is one, is what the log keeps of them in their
  /// place (`ClientMessage.redactedLine()`). Added in minor 3; nil, as an older app sends it,
  /// logs `bytes`. An older host ignores it and logs `bytes`.
  case write(id: String, bytes: Data, logged: Data? = nil)
  /// Logged as a `note` and written to nothing: the app's own marks for its replay.
  case note(id: String, bytes: Data)
  case closeInput(id: String)
  /// `forget`: the host forgets the process once it has ended, as an `acknowledge` would,
  /// for an app that will not be there to say so. Added in minor 2; nil, as an older app
  /// sends it, keeps what ended.
  case terminate(id: String, forget: Bool? = nil)
  case setMeta(id: String, meta: Data)
  case acknowledge(id: String)
  /// The app lets go of the process, which carries on: nobody is attached, and the other
  /// apps are told. Added in minor 1.
  case detach(id: String)
}

public enum HostEvent: Codable, Sendable, Equatable {
  /// `minor`: the host's. Added in minor 3; nil, as an older host sends it, is minor 2 or
  /// lower.
  case welcome(protocol: Int, hostVersion: String, pid: Int32, minor: Int? = nil)
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

/// The lines on the socket. The app numbers its requests, and the host answers each with
/// one `Answer` naming it, holding the core's direct replies (often none). An `Answer` with
/// no `to` carries one event the core delivered: an attach's stream, or a `released`.
enum HostFrame {
  struct Request: Codable {
    var id: Int
    var request: HostRequest
  }

  /// What the host reads of a request it does not know, to refuse it.
  struct Head: Decodable {
    var id: Int
  }

  struct Answer: Codable {
    var to: Int?
    var events: [HostEvent]

    init(to: Int?, events: [HostEvent]) {
      self.to = to
      self.events = events
    }

    /// An event this app does not know (a newer minor's) is skipped, not the whole answer.
    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      to = try container.decodeIfPresent(Int.self, forKey: .to)
      var list = try container.nestedUnkeyedContainer(forKey: .events)
      events = []
      while !list.isAtEnd {
        if let event = try? list.decode(HostEvent.self) {
          events.append(event)
        } else {
          _ = try list.decode(Skipped.self)
        }
      }
    }

    private struct Skipped: Decodable {
      init(from decoder: any Decoder) throws {}
    }
  }
}
