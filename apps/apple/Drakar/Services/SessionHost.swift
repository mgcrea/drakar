import DrakarKit
import Foundation
import Synchronization

/// The app's way to the session host (spec §1, §5): finds the host on its socket, starts the
/// bundled `DrakarHost` when nothing answers there, and keeps the one connection every
/// hosted process shares.
///
/// Off under tests unless a test names a directory, so no test reaches the person's host or
/// leaves one running.
@MainActor final class SessionHost {
  /// Off under tests whatever `testDirectory` says: a suite running beside a test's host
  /// must not reach it through its sessions, nor start one nobody stops.
  static let shared = SessionHost(cooldown: .seconds(30), helper: helper, underTests: nil)

  /// Tests only: the directory a `SessionHost()` made under XCTest uses, read as it is made,
  /// instead of none.
  static var testDirectory: URL?

  /// The helper in the bundle. Not `url(forAuxiliaryExecutable:)`, which looks only in
  /// `Contents/MacOS`.
  static var helper: URL {
    Bundle.main.bundleURL.appending(path: "Contents/Helpers/DrakarHost")
  }

  /// True only while connected. False says "not now" (not yet connected, reconnecting, or
  /// cooling down after a host that did not answer in time) unless `cannotStart` is true too,
  /// which says "never": then sessions run as the app's children for the app's whole life.
  private(set) var isAvailable = false
  /// No host can be had (spec §5): the helper is missing or will not spawn, or the socket's
  /// path is refused. A host that started but answered late is not this: it is tried again.
  private(set) var cannotStart = false

  /// Our host's, from its hello: what it runs for this app's own rows the registry of live
  /// sessions must not take for another app's (`LiveSession.read`).
  /// Settable for tests, whose host is the test process.
  var hostPID: Int32? { didSet { if hostPID != oldValue { hostedChanged() } } }

  /// Tests only: the helper this instance started, if it started one.
  private(set) var started: pid_t?

  private let helper: URL
  private let cooldown: Duration
  /// `testDirectory` when this one was made.
  private let underTests: URL?
  private var connection: HostClient?
  private var connecting: Task<Outcome, Never>?
  private var reconnecting: Task<HostClient?, Never>?
  private var quietUntil: ContinuousClock.Instant?
  /// The windows showing processes another app holds read-only. Told when an app lets one
  /// go (`released`), asked in the order they began watching until one takes it, so that one
  /// attaches; and told of each new connection, which no `released` sent meanwhile reached.
  private var releaseWatchers: [ReleaseWatcher] = []
  /// The processes this app ended for good (a window closed, End Session). The host lists
  /// one until it has exited, attached to this app still, and no `released` comes of it here.
  private(set) var ended: Set<String> = []

  private struct ReleaseWatcher {
    weak var owner: AnyObject?
    var takes: (String) -> Bool
    var connected: () -> Void
  }

  private enum Outcome {
    case connected(HostClient, pid: Int32)
    /// Spawned, or a socket took the connection, but no hello came in time.
    case noAnswer
    case cannotStart
  }

  /// The first wait after starting the helper, doubled up to `longestWait`; `client()` gives
  /// up after `patience`. A hello gets `helloLimit`, so a host that takes the connection but
  /// never answers holds nothing up for long.
  private static let firstWait = Duration.milliseconds(50)
  private static let longestWait = Duration.seconds(2)
  private static let patience = Duration.seconds(5)
  private static let helloLimit = Duration.seconds(2)

  /// `cooldown`: how long after a host that did not answer `client()` gives nil at once, so
  /// a slow start costs one wait, not one per session. `helper` is for tests.
  convenience init(cooldown: Duration = .seconds(30), helper: URL = SessionHost.helper) {
    self.init(cooldown: cooldown, helper: helper, underTests: Self.testDirectory)
  }

  private init(cooldown: Duration, helper: URL, underTests: URL?) {
    self.cooldown = cooldown
    self.helper = helper
    self.underTests = underTests
  }

  /// The connection to the host, starting it when nothing answers. Nil when there is no host
  /// to have now: under tests without `testDirectory`, while cooling down, or for good once
  /// `cannotStart`.
  func client() async -> HostClient? {
    if let connection {
      if !connection.isClosed { return connection }
      // Ended, and its `disconnected` not handled yet: this one is not to be had again.
      self.connection = nil
      isAvailable = false
    }
    if let connecting { return Self.client(of: await connecting.value) }
    guard !cannotStart, let directory else { return nil }
    if let quietUntil, ContinuousClock.now < quietUntil { return nil }
    let task = Task { await connect(in: directory) }
    connecting = task
    let outcome = await task.value
    connecting = nil
    switch outcome {
    case .connected(let client, let pid):
      quietUntil = nil
      hostPID = pid
      adopt(client)
    case .noAnswer:
      quietUntil = .now + cooldown
    case .cannotStart:
      cannotStart = true
    }
    return Self.client(of: outcome)
  }

  private static func client(of outcome: Outcome) -> HostClient? {
    if case .connected(let client, _) = outcome { return client }
    return nil
  }

  /// A connection once more, for the hosted processes whose connection ended (spec §5): the
  /// host tried again with the start's backoff until one answers, every caller waiting on
  /// the same attempt. Nil once no host can be had.
  func reconnect() async -> HostClient? {
    if let reconnecting { return await reconnecting.value }
    let task = Task { () -> HostClient? in
      var wait = Self.firstWait
      while true {
        if let client = await client() { return client }
        guard !cannotStart, directory != nil else { return nil }
        try? await Task.sleep(for: wait)
        wait = min(wait * 2, Self.longestWait)
      }
    }
    reconnecting = task
    let reconnected = await task.value
    reconnecting = nil
    return reconnected
  }

  /// Writes what was sent to the host before returning, for an app about to exit.
  func flush() {
    connection?.flush()
  }

  /// What the host holds, or nothing when there is no host or it does not answer.
  func held() async -> [HeldProcess] {
    await listed() ?? []
  }

  /// What the host holds; nil when there is no host or it does not answer, which says
  /// nothing of what it holds.
  func listed() async -> [HeldProcess]? {
    guard let client = await client() else { return nil }
    return await Self.within(Self.helloLimit) { try await client.list() }
  }

  /// What the host holds, without starting one: with no socket there is no host, and nothing
  /// held. For a launch or a window opening, which have nothing to ask a host that isn't up.
  func heldIfRunning() async -> [HeldProcess] {
    guard connection != nil || hasSocket else { return [] }
    return await held()
  }

  /// What hosts of an older protocol hold (spec §5): each socket of a lower major in the
  /// directory is said hello to and listed, and nothing more is ever asked of it. All of it
  /// is held elsewhere for this app, attached to an app or not.
  func heldByOlderHosts() async -> [HeldProcess] {
    guard let directory else { return [] }
    let version = Self.appVersion
    var held: [HeldProcess] = []
    for socket in Self.olderSockets(in: directory) {
      guard let client = try? HostClient.connect(socket: socket) else { continue }
      defer { client.close() }
      let welcome = await Self.within(Self.helloLimit) {
        try await client.hello(appVersion: version)
      }
      guard let welcome, welcome.protocol < HostWire.major else { continue }
      held += await Self.within(Self.helloLimit) { try await client.list() } ?? []
    }
    return held
  }

  /// `host-v<n>.sock` for each `n` below ours.
  private static func olderSockets(in directory: URL) -> [URL] {
    let names =
      (try? FileManager.default.contentsOfDirectory(
        atPath: directory.path(percentEncoded: false))) ?? []
    return (0..<HostWire.major).compactMap { major in
      guard let socket = try? HostWire.socket(in: directory, major: major),
        names.contains(socket.lastPathComponent)
      else { return nil }
      return socket
    }
  }

  /// `takes` is asked for each process an app lets go, until a watcher takes it, and
  /// `connected` runs on each new connection; for as long as `owner`, once for each.
  func watchReleases(
    for owner: AnyObject, takes: @escaping (String) -> Bool,
    connected: @escaping () -> Void
  ) {
    releaseWatchers.removeAll { $0.owner == nil || $0.owner === owner }
    releaseWatchers.append(ReleaseWatcher(owner: owner, takes: takes, connected: connected))
  }

  /// The registry is read again without what our host runs for this app; only for the app's
  /// own host, not a test's.
  private func hostedChanged() {
    if self === Self.shared { SessionMonitor.shared.hostedChanged() }
  }

  /// This app ends the process for good: no window takes it back, nor shows it held elsewhere.
  func ending(_ id: String) {
    ended.insert(id)
  }

  private func released(_ id: String) {
    releaseWatchers.removeAll { $0.owner == nil }
    _ = releaseWatchers.first { $0.takes(id) }
  }

  private var hasSocket: Bool {
    guard let directory, let socket = try? HostWire.socket(in: directory) else { return false }
    return FileManager.default.fileExists(atPath: socket.path(percentEncoded: false))
  }

  private var directory: URL? {
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      return underTests
    }
    return HostWire.directory(
      bundleID: Bundle.main.bundleIdentifier ?? "io.mgcrea.Drakar",
      home: FileManager.default.homeDirectoryForCurrentUser)
  }

  private func connect(in directory: URL) async -> Outcome {
    guard let socket = try? HostWire.socket(in: directory) else { return .cannotStart }
    let deadline = ContinuousClock.now + Self.patience
    var wait = Self.firstWait
    var spawned = false
    while true {
      if let (client, pid) = await Self.answering(socket, until: deadline) {
        return .connected(client, pid: pid)
      }
      if !spawned {
        // A socket a crashed host left is the new host's to remove, under its lock.
        guard let pid = Self.startHelper(helper, in: directory) else { return .cannotStart }
        started = pid
        spawned = true
      }
      guard ContinuousClock.now + wait < deadline else { return .noAnswer }
      try? await Task.sleep(for: wait)
      wait = min(wait * 2, Self.longestWait)
    }
  }

  /// A connection whose host says hello in our major in time, and the host's pid, or nil.
  private static func answering(_ socket: URL, until deadline: ContinuousClock.Instant) async
    -> (HostClient, pid: Int32)?
  {
    guard let client = try? HostClient.connect(socket: socket) else { return nil }
    let limit = min(helloLimit, deadline - .now)
    let version = appVersion
    let welcome = await within(limit) { try await client.hello(appVersion: version) }
    guard let welcome, welcome.protocol == HostWire.major else {
      client.close()
      return nil
    }
    return (client, welcome.pid)
  }

  private static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }

  private func adopt(_ client: HostClient) {
    connection = client
    isAvailable = true
    releaseWatchers.removeAll { $0.owner == nil }
    for watcher in releaseWatchers { watcher.connected() }
    Task { [weak self] in
      for await id in client.released { self?.released(id) }
    }
    Task { [weak self] in
      for await _ in client.disconnected {}
      guard let self, self.connection === client else { return }
      self.connection = nil
      self.isAvailable = false
    }
  }

  /// `body`'s result, or nil once `limit` has gone by or it throws.
  private static func within<T: Sendable>(
    _ limit: Duration, _ body: @escaping @Sendable () async throws -> T
  ) async -> T? {
    await withTaskGroup(of: T?.self) { group in
      group.addTask { try? await body() }
      group.addTask {
        try? await Task.sleep(for: limit)
        return nil
      }
      defer { group.cancelAll() }
      return await group.next() ?? nil
    }
  }

  // MARK: - The helper

  /// The helpers started and not yet reaped. Reaped as each exits, so none lingers as a
  /// zombie while the app runs; tests read it to know one has gone.
  nonisolated private static let running = Mutex<Set<pid_t>>([])

  nonisolated static func isRunning(_ pid: pid_t) -> Bool {
    running.withLock { $0.contains(pid) }
  }

  /// Starts the helper detached: its own session, stdio on `/dev/null`, none of the app's
  /// descriptors and a small environment of its own, so it does not die with the app nor
  /// hold anything of it. Nil when the helper is missing or will not start.
  static func startHelper(_ helper: URL = helper, in directory: URL) -> pid_t? {
    let helper = helper.path(percentEncoded: false)
    guard FileManager.default.isExecutableFile(atPath: helper) else { return nil }

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var noSignals = sigset_t()
    var allSignals = sigset_t()
    sigemptyset(&noSignals)
    sigfillset(&allSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    posix_spawnattr_setsigdefault(&attributes, &allSignals)
    let flags =
      POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
      | POSIX_SPAWN_SETSIGDEF
    posix_spawnattr_setflags(&attributes, Int16(flags))

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

    let inherited = ProcessInfo.processInfo.environment
    let environment =
      ["HOME", "USER", "LOGNAME", "TMPDIR"].compactMap { key in
        inherited[key].map { "\(key)=\($0)" }
      } + ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
    let arguments = [helper, "--directory", directory.path(percentEncoded: false)]

    var argv = arguments.map { strdup($0) } + [nil]
    var envp = environment.map { strdup($0) } + [nil]
    defer { for pointer in argv + envp { free(pointer) } }
    var pid = pid_t()
    guard posix_spawn(&pid, helper, &actions, &attributes, &argv, &envp) == 0 else {
      return nil
    }
    let child = pid
    running.withLock { _ = $0.insert(child) }
    Thread.detachNewThread {
      var status: Int32 = 0
      while waitpid(child, &status, 0) == -1, errno == EINTR {}
      running.withLock { _ = $0.remove(child) }
    }
    return child
  }
}
