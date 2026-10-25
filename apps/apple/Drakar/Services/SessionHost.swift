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
  static let shared = SessionHost()

  /// Tests only: a directory to use under XCTest instead of none.
  static var testDirectory: URL?

  /// The helper in the bundle. Not `url(forAuxiliaryExecutable:)`, which looks only in
  /// `Contents/MacOS`.
  static var helper: URL {
    Bundle.main.bundleURL.appending(path: "Contents/Helpers/DrakarHost")
  }

  /// False until connected, and while reconnecting; false for good once the helper could
  /// not start.
  private(set) var isAvailable = false
  var onReleased: ((String) -> Void)?

  /// Tests only: the helper this instance started, if it started one.
  private(set) var started: pid_t?

  private var connection: HostClient?
  private var connecting: Task<HostClient?, Never>?
  private var cannotStart = false

  /// The first wait after starting the helper, doubled up to `longestWait`; `client()` gives
  /// up after `patience`. A hello gets `helloLimit`, so a host that takes the connection but
  /// never answers holds nothing up for long.
  private static let firstWait = Duration.milliseconds(50)
  private static let longestWait = Duration.seconds(2)
  private static let patience = Duration.seconds(5)
  private static let helloLimit = Duration.seconds(2)

  init() {}

  /// The connection to the host, starting it when nothing answers. Nil when there is no host
  /// to have: under tests without `testDirectory`, or once the helper could not start.
  func client() async -> HostClient? {
    if let connection { return connection }
    if let connecting { return await connecting.value }
    guard !cannotStart, let directory = Self.directory else { return nil }
    let task = Task { await connect(in: directory) }
    connecting = task
    let client = await task.value
    connecting = nil
    if let client {
      adopt(client)
    } else {
      cannotStart = true
    }
    return client
  }

  /// What the host holds, or nothing when there is no host or it does not answer.
  func held() async -> [HeldProcess] {
    guard let client = await client() else { return [] }
    return await Self.within(Self.helloLimit) { try await client.list() } ?? []
  }

  private static var directory: URL? {
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      return testDirectory
    }
    return HostWire.directory(
      bundleID: Bundle.main.bundleIdentifier ?? "io.mgcrea.Drakar",
      home: FileManager.default.homeDirectoryForCurrentUser)
  }

  private func connect(in directory: URL) async -> HostClient? {
    guard let socket = try? HostWire.socket(in: directory) else { return nil }
    let deadline = ContinuousClock.now + Self.patience
    var wait = Self.firstWait
    var spawned = false
    while true {
      if let client = await Self.answering(socket, until: deadline) { return client }
      if !spawned {
        // A socket a crashed host left is the new host's to remove, under its lock.
        guard let pid = Self.startHelper(in: directory) else { return nil }
        started = pid
        spawned = true
      }
      guard ContinuousClock.now + wait < deadline else { return nil }
      try? await Task.sleep(for: wait)
      wait = min(wait * 2, Self.longestWait)
    }
  }

  /// A connection whose host says hello in our major in time, or nil.
  private static func answering(_ socket: URL, until deadline: ContinuousClock.Instant) async
    -> HostClient?
  {
    guard let client = try? HostClient.connect(socket: socket) else { return nil }
    let limit = min(helloLimit, deadline - .now)
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
    let appVersion = version as? String ?? "0"
    let welcome = await within(limit) { try await client.hello(appVersion: appVersion) }
    guard welcome?.protocol == HostWire.major else {
      client.close()
      return nil
    }
    return client
  }

  private func adopt(_ client: HostClient) {
    connection = client
    isAvailable = true
    Task { [weak self] in
      for await id in client.released { self?.onReleased?(id) }
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
  static func startHelper(in directory: URL) -> pid_t? {
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
