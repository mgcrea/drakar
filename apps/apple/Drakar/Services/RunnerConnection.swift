import DrakarKit
import Foundation
import Synchronization

/// Why a runner could not be reached: what to say, and ssh's stderr as it came, which names
/// what ssh itself knows went wrong (a host key changed, a key refused, no Drakar at the
/// path) and what the relay said before it left.
nonisolated struct RunnerFailure: Error, Equatable {
  var message: String
  var stderr: String
}

/// The Mac's way to a runner's host (spec §3): `ssh` to the runner, running its Drakar as the
/// relay, one end of a socket pair as ssh's stdin and stdout. The relay states the runner's
/// facts in one line, then copies bytes to and from the host's socket, so the same end then
/// serves a `HostClient` as a local socket does.
///
/// ssh is the person's own, spawned as `claude` is (spec §6): Drakar opens no connection of its
/// own to the runner, and the relay is reached only through their ssh login. `BatchMode`,
/// for nobody is there to type a passphrase; their `~/.ssh/config` supplies everything else
/// (keys, `ControlMaster`, Tailscale names), and Drakar writes nothing there.
enum RunnerConnection {
  /// How long the relay has to state its facts: ssh connecting, then each `claude --version`
  /// the relay asks on the runner.
  static let factsLimit = Duration.seconds(10)
  /// How long the host has to answer once the facts are in. The relay waits 15 s for one, the
  /// runner's app starting it, and says why on stderr when none came.
  static let helloLimit = Duration.seconds(20)
  /// The longest facts line taken; anything longer is not a relay's.
  nonisolated private static let longestLine = 1 << 20
  /// How long an ssh that is ending is waited on for the rest of its stderr.
  private static let stderrLimit = Duration.seconds(2)

  /// A runner reached: its host's connection, its facts, and the ssh that carries it.
  typealias Opened = (client: HostClient, facts: RunnerFacts, ssh: Process)

  /// The runner's host, said hello to, the runner's facts, and the ssh that carries the
  /// connection, for whoever lets the connection go to `end`. Throws when ssh fails, the
  /// relay states nothing within `factsLimit`, or the runner's Drakar is not one this build
  /// can talk to; ssh is ended then, whatever it was doing.
  static func open(_ settings: RunnerSettings) async throws(RunnerFailure) -> Opened {
    let name = settings.displayName
    // ssh would take it for one of its options.
    guard !settings.destination.hasPrefix("-") else {
      throw RunnerFailure(
        message: String(localized: "“\(settings.destination)” is not an ssh destination."),
        stderr: "")
    }
    var ends: [Int32] = [0, 0]
    var errors: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0 else {
      throw RunnerFailure(message: Self.cannotStart(errno), stderr: "")
    }
    // At once, before anything else can be spawned: a child that kept ssh's end would keep
    // ours from seeing ssh go.
    for fd in ends { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    guard pipe(&errors) == 0 else {
      let error = errno
      for fd in ends { close(fd) }
      throw RunnerFailure(message: Self.cannotStart(error), stderr: "")
    }
    for fd in errors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    let (ours, theirs) = (ends[0], ends[1])

    // The person's ssh, which opens the connection to their runner; not Drakar (spec §6).
    let ssh = Process()
    ssh.executableURL = RunnerSettings.sshExecutable
    ssh.arguments = arguments(settings)
    // ssh's stdio are dups of these; the app's copies close once it runs.
    let stdio = FileHandle(fileDescriptor: theirs, closeOnDealloc: false)
    ssh.standardInput = stdio
    ssh.standardOutput = stdio
    ssh.standardError = FileHandle(fileDescriptor: errors[1], closeOnDealloc: false)
    let exit = Exit()
    ssh.terminationHandler = { _ in exit.end() }
    do {
      try ssh.run()
    } catch {
      for fd in ends + errors { close(fd) }
      throw RunnerFailure(
        message: String(localized: "ssh did not start: \(error.localizedDescription)"),
        stderr: "")
    }
    close(theirs)
    close(errors[1])
    let tail = Tail(reading: errors[0])

    /// ssh ended here, unless it is `ending` of itself, and what it said on stderr meanwhile.
    func failure(_ message: String, ending: Bool) async -> RunnerFailure {
      let ended = ending ? await exit.wait(within: stderrLimit) : false
      if !ended { ssh.terminate() }
      await tail.wait(within: stderrLimit)
      return RunnerFailure(message: message, stderr: tail.text)
    }

    let limit = factsLimit
    guard let line = await Task.detached(operation: { line(from: ours, within: limit) }).value
    else {
      // The end of the line: ssh is going, and says why. Else it said nothing in time.
      let ending = Self.hasEnded(ours)
      close(ours)
      throw await failure(
        ending
          ? String(localized: "ssh to \(name) ended before Drakar answered there.")
          : String(
            localized: "\(name) did not answer within \(factsLimit.components.seconds) seconds."),
        ending: ending)
    }
    let facts: RunnerFacts
    do {
      facts = try Self.facts(from: line, name: name)
    } catch {
      close(ours)
      throw await failure(error.message, ending: false)
    }

    let client = HostClient.connect(fd: ours)
    let version = SessionHost.appVersion
    let welcome = await SessionHost.within(helloLimit) {
      try await client.hello(appVersion: version)
    }
    guard let welcome, welcome.protocol == HostWire.major else {
      client.close()
      // No hello: the relay most likely left, saying why, and ssh with it.
      throw await failure(
        welcome.map { update(name, runnerIsNewer: $0.protocol > HostWire.major) }
          ?? String(localized: "Drakar's session host on \(name) did not answer."),
        ending: welcome == nil)
    }
    return (client, facts, ssh)
  }

  /// Ends the ssh of a connection let go. Closing the connection alone leaves ssh to notice
  /// its stdin has ended, which one whose network has gone, or whose relay is wedged, does
  /// not do for minutes.
  static func end(_ ssh: Process) {
    if ssh.isRunning { ssh.terminate() }
  }

  /// `ssh -T -o BatchMode=yes <destination> <drakarPath>/Contents/MacOS/Drakar --relay`. ssh
  /// hands the command to the runner's shell as one line, so a path that shell would split is
  /// quoted for it, all but a leading `~/`, which the shell expands to the runner's home.
  static func arguments(_ settings: RunnerSettings) -> [String] {
    let relay = settings.drakarPath + "/Contents/MacOS/Drakar"
    let quoted =
      relay.hasPrefix("~/")
      ? "~/" + quotedForShell(String(relay.dropFirst(2))) : quotedForShell(relay)
    return ["-T", "-o", "BatchMode=yes", settings.destination, quoted, "--relay"]
  }

  private static func quotedForShell(_ word: String) -> String {
    let plain = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+:@%,")
    guard word.unicodeScalars.contains(where: { !plain.contains($0) }) else { return word }
    return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
  }

  /// The relay's facts, when they are of a relay and a host this build speaks. A relay of
  /// another version may state them in another shape, so its version is read first.
  private static func facts(from line: Data, name: String) throws(RunnerFailure) -> RunnerFacts {
    struct Stated: Decodable { var relay: Int }
    guard let stated = try? JSONDecoder().decode(Stated.self, from: line) else {
      let start = String(decoding: line.prefix(200), as: UTF8.self)
      throw RunnerFailure(
        message: String(localized: "\(name) answered with something other than Drakar: “\(start)”"),
        stderr: "")
    }
    guard stated.relay == RunnerFacts.relayVersion else {
      throw RunnerFailure(
        message: update(name, runnerIsNewer: stated.relay > RunnerFacts.relayVersion), stderr: "")
    }
    // A relay of our version that states facts we cannot read is not the build it says.
    guard let facts = try? RunnerFacts.parse(line) else {
      throw RunnerFailure(message: update(name, runnerIsNewer: false), stderr: "")
    }
    guard facts.hostMajors.contains(HostWire.major) else {
      // Newer only when every major it speaks is above ours; older, or none, it is behind.
      let newer = !facts.hostMajors.isEmpty && facts.hostMajors.allSatisfy { $0 > HostWire.major }
      throw RunnerFailure(message: update(name, runnerIsNewer: newer), stderr: "")
    }
    return facts
  }

  /// The Mac that is behind is the one to update (spec §3).
  private static func update(_ name: String, runnerIsNewer: Bool) -> String {
    runnerIsNewer
      ? String(localized: "Update Drakar on this Mac")
      : String(localized: "Update Drakar on \(name)")
  }

  private static func cannotStart(_ error: Int32) -> String {
    String(localized: "ssh could not be started: \(String(cString: strerror(error)))")
  }

  /// The other end has closed: what is left to read is nothing.
  nonisolated private static func hasEnded(_ fd: Int32) -> Bool {
    var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    var byte: UInt8 = 0
    return poll(&ready, 1, 0) > 0 && recv(fd, &byte, 1, MSG_PEEK) == 0
  }

  /// The facts line, read a byte at a time so that none of the host's bytes after it is
  /// taken; nil on EOF, after `limit`, or once it is longer than any relay's.
  nonisolated private static func line(from fd: Int32, within limit: Duration) -> Data? {
    let deadline = ContinuousClock.now + limit
    var line = Data()
    var byte: UInt8 = 0
    while line.count < longestLine {
      let left = deadline - .now
      guard left > .zero else { return nil }
      var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let polled = poll(&ready, 1, Int32(left / .milliseconds(1)) + 1)
      if polled < 0, errno == EINTR { continue }
      guard polled > 0 else { return nil }
      let count = read(fd, &byte, 1)
      if count < 0, errno == EINTR || errno == EAGAIN { continue }
      guard count == 1 else { return nil }
      if byte == 0x0A { return line }
      line.append(byte)
    }
    return nil
  }

  /// ssh's exit, as its termination handler says it.
  nonisolated private final class Exit: Sendable {
    private let ended = Mutex(false)

    var hasEnded: Bool { ended.withLock { $0 } }

    func end() {
      ended.withLock { $0 = true }
    }

    /// True once ssh has ended, false if it is still running after `limit`.
    func wait(within limit: Duration) async -> Bool {
      let deadline = ContinuousClock.now + limit
      while !hasEnded, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
      }
      return hasEnded
    }
  }

  /// The last `kept` bytes of ssh's stderr, read for as long as ssh writes it, so a chatty
  /// ssh never fills the pipe.
  nonisolated private final class Tail: Sendable {
    private static let kept = 4096
    private let state = Mutex((bytes: Data(), ended: false))
    /// Kept while it is read, which its handler alone does not do.
    private let handle: FileHandle

    init(reading fd: Int32) {
      handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      handle.readabilityHandler = { [self] handle in
        let data = handle.availableData
        guard !data.isEmpty else {
          // Its last writer closed it: the handle goes, and closes it, with this handler.
          handle.readabilityHandler = nil
          return state.withLock { $0.ended = true }
        }
        state.withLock { state in
          state.bytes.append(data)
          if state.bytes.count > Self.kept { state.bytes = state.bytes.suffix(Self.kept) }
        }
      }
    }

    var text: String { String(decoding: state.withLock { $0.bytes }, as: UTF8.self) }

    /// Until every writer has closed it, or `limit` has gone by.
    func wait(within limit: Duration) async {
      let deadline = ContinuousClock.now + limit
      while !state.withLock({ $0.ended }), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
  }
}
