import DrakarKit
import Foundation
import Synchronization

/// The app's way to the session host (spec §1, §5): finds the host on its socket, starts the
/// bundled `DrakarHost` when nothing answers there, and keeps the one connection every
/// hosted process shares. A runner's host (remote sessions spec §3) is reached the same way
/// once connected, through ssh and the runner's relay instead of a socket, and is never
/// started from here.
///
/// Off under tests unless a test names a directory, so no test reaches the person's host or
/// leaves one running.
@MainActor final class SessionHost {
  enum Endpoint: Equatable {
    /// This Mac's host.
    case local
    /// The host of the runner these settings reach.
    case runner(RunnerSettings)
  }

  /// Off under tests whatever `testDirectory` says: a suite running beside a test's host
  /// must not reach it through its sessions, nor start one nobody stops.
  static let shared = SessionHost(
    endpoint: .local, cooldown: .seconds(30), helper: helper, underTests: nil)

  /// The configured runner's host, made for `RunnerSettings.current`, and the same one for as
  /// long as a runner is configured (`useRunner`). None under tests, which never reach the
  /// person's runner.
  static var runner: SessionHost? =
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    ? nil
    : RunnerSettings.current.map { SessionHost(endpoint: .runner($0), keptIn: .standard) }

  /// The runner Settings › Runner saved in `defaults`, nil for none. The host stays the one
  /// the sessions on it hold, whatever the runner is renamed or retargeted to (`retarget`);
  /// only no runner closes it, for good. Never two runners reached at once.
  static func useRunner(_ settings: RunnerSettings?, keptIn defaults: UserDefaults = .standard) {
    guard let settings else {
      runner?.close()
      runner = nil
      return
    }
    if let runner {
      runner.retarget(settings)
    } else {
      runner = SessionHost(endpoint: .runner(settings), keptIn: defaults)
    }
  }

  /// Tests only: the directory a `SessionHost()` made under XCTest uses, read as it is made,
  /// instead of none.
  static var testDirectory: URL?

  /// The app's own host directory, which the relay finds too; never a test's.
  nonisolated static var hostDirectory: URL {
    HostWire.directory(
      bundleID: Bundle.main.bundleIdentifier ?? "io.mgcrea.Drakar",
      home: FileManager.default.homeDirectoryForCurrentUser)
  }

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

  /// A runner's changes as Settings › Runner saves them (`retarget`).
  private(set) var endpoint: Endpoint
  var isRunner: Bool { endpoint != .local }
  /// What the runner's relay stated on the last connection made.
  private(set) var facts: RunnerFacts?
  /// Why the last attempt to reach the runner failed; nil once one succeeds.
  private(set) var failure: RunnerFailure?
  /// Let go for good (`close()`): nothing more is asked of it.
  private(set) var isClosed = false
  /// Whether a process the runner holds is this Mac's (its `owner`), for `reattachRefused`.
  var ownsProcess: (HeldProcess) -> Bool = { _ in false }

  private let helper: URL
  private let cooldown: Duration
  /// `testDirectory` when this one was made.
  private let underTests: URL?
  private var connection: HostClient?
  /// The ssh that carries a runner's `connection`, ended with it.
  private var ssh: Process?
  /// Where a runner's settings are kept, for `name(after:)`.
  private var settings: UserDefaults?
  /// Moved on by each `retarget`: an attempt begun before it reached the old target.
  private var target = 0
  private var connecting: Task<Outcome, Never>?
  private var reconnecting: Task<HostClient?, Never>?
  private var quietUntil: ContinuousClock.Instant?
  /// A session took this connection through `client()` or `reconnect()`, or may be about to:
  /// a runner turning its opt-in off leaves it open, as it is left today. Cleared as the
  /// connection ends, never as one is made, which a session waiting on the same attempt
  /// may have taken first.
  private var taken = false
  /// The runner's opt-in connecting, and again after each drop (`keepConnected`).
  private var keeping: Task<Void, Never>?
  private var drops: AsyncStream<Void>.Continuation?
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
    /// `pid` is the host's, nil for a runner's, which is no process of this Mac.
    case connected(HostClient, pid: Int32?, ssh: Process?)
    /// Spawned, or a socket took the connection, but no hello came in time.
    case noAnswer
    case cannotStart
  }

  /// The first wait after starting the helper, doubled up to `longestWait`; `client()` gives
  /// up after `patience`. A hello gets `helloLimit`, so a host that takes the connection but
  /// never answers holds nothing up for long. `reconnect()`, a session waiting out a
  /// runner's stale relay, and the relay waiting for its host back off the same way.
  nonisolated static let firstWait = Duration.milliseconds(50)
  nonisolated static let longestWait = Duration.seconds(2)
  private static let patience = Duration.seconds(5)
  private static let helloLimit = Duration.seconds(2)

  /// `cooldown`: how long after a host that did not answer `client()` gives nil at once, so
  /// a slow start costs one wait, not one per session. `helper` is for tests. A runner's is
  /// reached through `RunnerSettings.sshExecutable`, `testDirectory` or not: a test gives it
  /// a fake ssh that names the test's host directory to the relay.
  /// `keptIn`: where a runner's settings are kept, for the name it is given from its
  /// hostname when it has none.
  convenience init(
    endpoint: Endpoint = .local, cooldown: Duration = .seconds(30),
    helper: URL = SessionHost.helper, keptIn settings: UserDefaults? = nil
  ) {
    self.init(
      endpoint: endpoint, cooldown: cooldown, helper: helper, underTests: Self.testDirectory)
    self.settings = settings
  }

  private init(endpoint: Endpoint, cooldown: Duration, helper: URL, underTests: URL?) {
    self.endpoint = endpoint
    self.cooldown = cooldown
    self.helper = helper
    self.underTests = underTests
  }

  /// Settings › Runner changed this runner. A new name is for show, and the connection stays.
  /// Another destination or Drakar is another target: the connection to the old one goes, its
  /// ssh with it, and the next `client()` or `reconnect()` reaches the new one, where a
  /// session reattaches if it is the same Mac and ends as a lost connection does if not.
  func retarget(_ new: RunnerSettings) {
    guard case .runner(let old) = endpoint, old != new else { return }
    endpoint = .runner(new)
    guard old.destination != new.destination || old.drakarPath != new.drakarPath else { return }
    // An attempt under way is to the old target: `connected()` drops what it brings.
    target += 1
    connecting = nil
    quietUntil = nil
    facts = nil
    failure = nil
    let connection = connection
    self.connection = nil
    isAvailable = false
    taken = false
    connection?.close()
    if let ssh { RunnerConnection.end(ssh) }
    ssh = nil
  }

  /// A runner kept without a name is named after its hostname, the first time it is reached
  /// (spec §3), here and where it is kept, unless it was named meanwhile.
  private func name(after hostname: String) {
    guard case .runner(var current) = endpoint,
      current.name.trimmingCharacters(in: .whitespaces).isEmpty, !hostname.isEmpty
    else { return }
    current.name = hostname
    endpoint = .runner(current)
    guard let settings, var kept = RunnerSettings.read(from: settings), kept.id == current.id,
      kept.name.trimmingCharacters(in: .whitespaces).isEmpty
    else { return }
    kept.name = hostname
    RunnerSettings.write(kept, to: settings)
  }

  /// The connection to the host, starting it when nothing answers. Nil when there is no host
  /// to have now: under tests without `testDirectory`, while cooling down, or for good once
  /// `cannotStart`. A runner's is never started from here, and `failure` says why it could
  /// not be reached.
  func client() async -> HostClient? {
    take(await connected())
  }

  private func take(_ client: HostClient?) -> HostClient? {
    if client != nil { taken = true }
    return client
  }

  /// `client()` for this type's own uses, which keep nothing open for a session.
  private func connected() async -> HostClient? {
    if let connection {
      if !connection.isClosed { return connection }
      // Ended, and its `disconnected` not handled yet: this one is not to be had again.
      self.connection = nil
      isAvailable = false
      taken = false
    }
    let target = target
    if let connecting {
      let outcome = await connecting.value
      return isClosed || self.target != target ? nil : Self.client(of: outcome)
    }
    guard !cannotStart, isReachable else { return nil }
    if let quietUntil, ContinuousClock.now < quietUntil { return nil }
    let task = Task { await connect() }
    connecting = task
    let outcome = await task.value
    guard !isClosed, self.target == target else {
      // Closed or retargeted while it connected: this one is nobody's.
      if self.target == target { connecting = nil }
      if case .connected(let client, _, let ssh) = outcome {
        client.close()
        if let ssh { RunnerConnection.end(ssh) }
      }
      return nil
    }
    connecting = nil
    switch outcome {
    case .connected(let client, let pid, let ssh):
      quietUntil = nil
      hostPID = pid
      adopt(client, ssh: ssh)
    case .noAnswer:
      quietUntil = .now + cooldown
    case .cannotStart:
      cannotStart = true
    }
    return Self.client(of: outcome)
  }

  private static func client(of outcome: Outcome) -> HostClient? {
    if case .connected(let client, _, _) = outcome { return client }
    return nil
  }

  /// A connection once more, for the hosted processes whose connection ended (spec §5): the
  /// host tried again with the start's backoff until one answers, every caller waiting on
  /// the same attempt. Nil once no host can be had.
  func reconnect() async -> HostClient? {
    if let reconnecting { return take(await reconnecting.value) }
    let task = Task { () -> HostClient? in
      var wait = Self.firstWait
      while true {
        if let client = await connected() { return client }
        guard !cannotStart, isReachable else { return nil }
        try? await Task.sleep(for: wait)
        wait = min(wait * 2, Self.longestWait)
      }
    }
    reconnecting = task
    let reconnected = await task.value
    reconnecting = nil
    return take(reconnected)
  }

  /// Connected for as long as the runner's opt-in is on (spec §2): a connection now, and again
  /// after each drop, so the host's idle exit never fires while the app runs. The host is as
  /// it always was: an app connected is what keeps it. One loop, however often it is asked.
  func keepConnected() {
    guard keeping == nil else { return }
    let (dropped, drops) = AsyncStream.makeStream(
      of: Void.self, bufferingPolicy: .bufferingNewest(1))
    self.drops = drops
    keeping = Task { [weak self] in
      var drop = dropped.makeAsyncIterator()
      repeat {
        guard let self, await self.keptConnection() else { return }
        // Stopped while the last attempt was under way: nobody keeps this one.
        if Task.isCancelled { return self.closeIfUnused() }
      } while await drop.next() != nil
    }
  }

  /// `reconnect()`'s backoff, but the opt-in's own: stopping it ends the waits, and no
  /// attempt begins after, so a host that never answers is not started again once the
  /// opt-in is off. True once connected, even if stopped during that last attempt.
  private func keptConnection() async -> Bool {
    var wait = Self.firstWait
    while !Task.isCancelled {
      if await connected() != nil { return true }
      guard !cannotStart, isReachable else { return false }
      do { try await Task.sleep(for: wait) } catch { return false }
      wait = min(wait * 2, Self.longestWait)
    }
    return false
  }

  /// No more reconnecting for the opt-in. The connection closes only when the opt-in was all
  /// that held it: no session took it and no window waits on it for a `released`. A host
  /// that holds nothing then leaves as it does once the app quits; one that was taken stays
  /// open as it would have without the opt-in.
  func stopKeepingConnected() {
    guard let keeping else { return }
    keeping.cancel()
    self.keeping = nil
    drops?.finish()
    drops = nil
    closeIfUnused()
  }

  /// Lets go for good, as Settings › Runner does of a runner it no longer names: no more
  /// connecting, the connection closed whoever took it, and its ssh ended. A session it
  /// carried finds no host to reconnect to.
  func close() {
    isClosed = true
    stopKeepingConnected()
    let connection = connection
    self.connection = nil
    isAvailable = false
    connection?.close()
    if let ssh { RunnerConnection.end(ssh) }
  }

  private func closeIfUnused() {
    releaseWatchers.removeAll { $0.owner == nil }
    guard keeping == nil, !taken, releaseWatchers.isEmpty, let connection else { return }
    self.connection = nil
    isAvailable = false
    connection.close()
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
    guard let client = await connected() else { return nil }
    return await Self.within(Self.helloLimit) { try await client.list() }
  }

  /// What the host holds, without starting one: with no socket there is no host, and nothing
  /// held. For a launch or a window opening, which have nothing to ask a host that isn't up.
  /// A runner's is never started from here, so it is asked as it is.
  func heldIfRunning() async -> [HeldProcess] {
    guard isRunner || connection != nil || hasSocket else { return [] }
    return await held()
  }

  /// What hosts of an older protocol hold (spec §5): each socket of a lower major in the
  /// directory is said hello to and listed, and nothing more is ever asked of it. All of it
  /// is held elsewhere for this app, attached to an app or not. None on a runner, whose
  /// relay reaches its host of our major alone.
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
  /// own host, not a test's nor a runner's.
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

  /// Nil for a runner, whose host is in a directory of the runner's.
  private var directory: URL? {
    guard !isRunner else { return nil }
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      return underTests
    }
    return Self.hostDirectory
  }

  /// Somewhere to connect to: a runner, or a host directory, while not closed for good.
  private var isReachable: Bool { !isClosed && (isRunner || directory != nil) }

  private func connect() async -> Outcome {
    switch endpoint {
    case .local:
      guard let directory else { return .cannotStart }
      return await connect(in: directory)
    case .runner(let settings):
      let target = target
      do {
        let (client, facts, ssh) = try await RunnerConnection.open(settings)
        // Retargeted meanwhile: `connected()` drops it, and says nothing of the new target.
        guard self.target == target else { return .connected(client, pid: nil, ssh: ssh) }
        self.facts = facts
        failure = nil
        name(after: facts.hostname)
        return .connected(client, pid: nil, ssh: ssh)
      } catch {
        // Tried again after the cooldown: the network, the runner's login or its Drakar may
        // all come back.
        if self.target == target { failure = error }
        return .noAnswer
      }
    }
  }

  /// Asked once the host refused to attach `id` again: true while that refusal is this Mac's
  /// own old connection, whose relay on the runner holds the process until the runner's sshd
  /// hangs it up (spec §3, "A stale relay"). Only for a runner's process still running there,
  /// attached to an app, and that `ownsProcess` says is this Mac's; never on a local host.
  func reattachRefused(_ id: String) async -> Bool {
    guard isRunner, let held = await listed()?.first(where: { $0.id == id }) else {
      return false
    }
    return held.running && held.attachedApp != nil && ownsProcess(held)
  }

  /// The host's refusal of an attach to a process another app holds.
  nonisolated static func isAttachedElsewhere(_ reason: String) -> Bool {
    reason.hasSuffix(" is attached to another app")
  }

  private func connect(in directory: URL) async -> Outcome {
    guard let socket = try? HostWire.socket(in: directory) else { return .cannotStart }
    let deadline = ContinuousClock.now + Self.patience
    var wait = Self.firstWait
    var spawned = false
    while true {
      if let (client, pid) = await Self.answering(socket, until: deadline) {
        return .connected(client, pid: pid, ssh: nil)
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

  static var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }

  private func adopt(_ client: HostClient, ssh: Process?) {
    connection = client
    self.ssh = ssh
    isAvailable = true
    releaseWatchers.removeAll { $0.owner == nil }
    for watcher in releaseWatchers { watcher.connected() }
    Task { [weak self] in
      for await id in client.released { self?.released(id) }
    }
    Task { [weak self] in
      for await _ in client.disconnected {}
      // Whoever ended the connection, its ssh serves nothing more.
      if let ssh { RunnerConnection.end(ssh) }
      guard let self else { return }
      if self.ssh === ssh { self.ssh = nil }
      if self.connection === client {
        self.connection = nil
        self.isAvailable = false
        self.taken = false
      }
      // Even for one already let go: whoever let it go may have found no host since.
      self.drops?.yield()
    }
  }

  /// `body`'s result, or nil once `limit` has gone by or it throws.
  static func within<T: Sendable>(
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
