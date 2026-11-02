import DrakarKit
import Foundation

/// `Drakar --relay`, the runner's end of a remote session (spec §1). sshd starts it for the
/// Mac's `ssh`: it states the runner's facts in one line on stdout, makes sure the runner's
/// host is up, then copies bytes between its stdio and the host's socket until either side
/// closes, parsing none of them.
///
/// It is the app's own binary, so the host's peer check passes it as it stands. `DrakarMain`
/// branches here before anything brings up AppKit, SwiftUI, Sparkle or the licence, and
/// nothing on this path reaches the app's main-actor singletons.
nonisolated enum RelayCommand {
  /// How the relay ends, in sysexits' terms. Every one but `ended` writes one line to stderr
  /// first, which reaches the Mac as ssh's stderr and is shown as it is.
  enum Exit: Int32 {
    /// The pump ended, on either side.
    case ended = 0
    /// The runner has not opted in (`EX_USAGE`).
    case notAccepted = 64
    /// No host answered within `patience` (`EX_UNAVAILABLE`).
    case noHost = 69
    /// The socket's path does not fit `sun_path` (`EX_SOFTWARE`).
    case pathTooLong = 70
  }

  /// What tests give the relay. A Debug build's alone (the hosted tests run one): a release
  /// relay reaches its own host, with its own opt-in, whatever an ssh command line says.
  struct Options {
    /// The host's directory, for tests: with it the relay never runs `open`.
    var directory: URL?
    /// The defaults suite the opt-in is read from, for tests, which run under the app's own
    /// bundle id and must not touch the person's settings. Only taken with `directory`.
    var defaultsSuite: String?
    /// The home the facts are found in, for tests, which must not read the person's own nor
    /// run its `claude`. Only taken with `directory`.
    var home: URL?

    init(arguments: [String]) {
      #if DEBUG
        func value(after flag: String) -> String? {
          guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
          }
          return arguments[index + 1]
        }
        directory = value(after: "--directory").map {
          URL(filePath: $0, directoryHint: .isDirectory)
        }
        guard directory != nil else { return }
        defaultsSuite = value(after: "--defaults-suite")
        home = value(after: "--home").map { URL(filePath: $0, directoryHint: .isDirectory) }
      #endif
    }
  }

  /// How long the host has to answer, the app's launch included (spec §2).
  static let patience = Duration.seconds(15)
  /// Each `claude --version`: the Mac waits ten seconds for the facts, and the login shell
  /// may already have taken five of them.
  private static let versionLimit = Duration.seconds(3)

  static func run(arguments: [String]) -> Never {
    // A write to an ssh that left fails rather than killing the relay.
    signal(SIGPIPE, SIG_IGN)
    // A hang-up or a kill ends the relay at once, never a disposition a parent left ignored:
    // the socket closes as the process goes, which the host takes for the app leaving, and
    // says `released` to the others. Both reset to the default in anything spawned.
    signal(SIGHUP) { _ in _exit(0) }
    signal(SIGTERM) { _ in _exit(0) }
    var signals = sigset_t()
    sigemptyset(&signals)
    sigaddset(&signals, SIGHUP)
    sigaddset(&signals, SIGTERM)
    sigprocmask(SIG_UNBLOCK, &signals, nil)

    let options = Options(arguments: arguments)
    Task.detached { exit(await relay(options).rawValue) }
    // The main thread only waits, with the two signals unblocked, so it is there to take them.
    while true { pause() }
  }

  private static func relay(_ options: Options) async -> Exit {
    let defaults = options.defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    guard defaults.bool(forKey: RunnerRole.acceptsKey) else {
      say(
        "This Mac does not take sessions from other Macs. To let it, open Drakar there and turn on “Let my other Macs start sessions here” in Settings › Runner."
      )
      return .notAccepted
    }
    let directory = options.directory ?? SessionHost.hostDirectory
    let socket: URL
    do {
      socket = try HostWire.socket(in: directory)
    } catch {
      say(
        "Drakar's session host cannot be reached on this Mac: the path of its socket is too long (\(directory.path(percentEncoded: false)))."
      )
      return .pathTooLong
    }

    // Asked at once, so an app that has to be started comes up while the facts are gathered.
    let host = Task { await connect(to: socket, launching: options.directory == nil) }
    let environmentFile = RunnerEnvironment.file(in: directory.deletingLastPathComponent())
    let facts = await facts(
      environmentFile: environmentFile,
      home: options.home ?? FileManager.default.homeDirectoryForCurrentUser)
    // Nobody to read them: the Mac has gone already.
    guard let line = try? facts.line(), write(line, to: STDOUT_FILENO) else { return .ended }

    guard let fd = await host.value else {
      say(
        "Drakar's session host did not start on this Mac within \(patience.components.seconds) seconds. Someone must be logged in to its desktop, where Drakar opens."
      )
      return .noHost
    }
    _ = await Relay.pump(input: STDIN_FILENO, output: STDOUT_FILENO, socket: fd)
    close(fd)
    return .ended
  }

  /// A connection to the host, or nil once `patience` has gone by, tried with
  /// `SessionHost`'s backoff. With `launching`, a socket that does not answer the first time
  /// has LaunchServices start the app once, in the person's GUI session, where the opt-in has
  /// it start its host (spec §2). Never the host from here: it, and every `claude` it runs,
  /// would live in sshd's context, without the login Keychain.
  private static func connect(to socket: URL, launching: Bool) async -> Int32? {
    let deadline = ContinuousClock.now + patience
    var wait = SessionHost.firstWait
    var launched = !launching
    while true {
      if let fd = try? Relay.connectedSocket(to: socket) { return fd }
      if !launched {
        launched = true
        launchApp()
      }
      let left = deadline - .now
      guard left > .zero else { return nil }
      try? await Task.sleep(for: min(wait, left))
      wait = min(wait * 2, SessionHost.longestWait)
    }
  }

  /// `open -g -j -a` on this bundle: in the background and hidden, and an app already running
  /// is only asked to activate, which `-g` stops. Its output is not the relay's, whose stdout
  /// is the Mac's stream.
  private static func launchApp() {
    let open = Process()
    open.executableURL = URL(filePath: "/usr/bin/open")
    open.arguments = ["-g", "-j", "-a", Bundle.main.bundleURL.path(percentEncoded: false)]
    open.standardInput = FileHandle.nullDevice
    open.standardOutput = FileHandle.nullDevice
    open.standardError = FileHandle.nullDevice
    try? open.run()
  }

  /// What the relay states first (spec §1). The environment is the GUI session's, from the
  /// file the runner's app writes there; without it, the login shell's (`shellEnvironment`,
  /// replaced in tests), less the ssh session's own variables. The `claude` candidates and
  /// accounts are found as Settings › General finds them locally, with that environment, in
  /// `home` (a test's own, never the person's).
  static func facts(
    environmentFile: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
    shellEnvironment: @Sendable () async -> [String: String]? = { await ShellEnvironment.read() }
  ) async -> RunnerFacts {
    let environment: [String: String]
    let source: EnvironmentSource
    if let gui = RunnerEnvironment.read(from: environmentFile) {
      environment = gui
      source = .gui
    } else {
      let shell = await shellEnvironment() ?? ProcessInfo.processInfo.environment
      environment = RunnerEnvironment.withoutSSH(shell)
      source = .ssh
    }
    let installs = ClaudeLocator.installed(home: home, path: environment["PATH"])
    // Each asked at once, as Settings does: an npm install takes a while to answer.
    let claude = await withTaskGroup(of: (Int, ClaudeCandidate).self) { group in
      for (index, url) in installs.enumerated() {
        group.addTask {
          let version = await ClaudeVersion.read(
            of: url, environment: environment, timeout: versionLimit)
          return (
            index,
            ClaudeCandidate(path: url.path(percentEncoded: false), version: version?.description)
          )
        }
      }
      var found: [(Int, ClaudeCandidate)] = []
      for await item in group { found.append(item) }
      return found.sorted { $0.0 < $1.0 }.map(\.1)
    }
    let shellDirectory = environment["CLAUDE_CONFIG_DIR"]
    let accounts = ClaudeAccount.discover(
      home: home,
      extra: shellDirectory.map { [URL(filePath: $0, directoryHint: .isDirectory)] } ?? [])
    let info = Bundle.main.infoDictionary ?? [:]
    return RunnerFacts(
      drakar: info["CFBundleShortVersionString"] as? String ?? "0",
      build: info["CFBundleVersion"] as? String ?? "0",
      hostMajors: [HostWire.major],
      home: ProjectPath.normalize(home),
      user: NSUserName(),
      hostname: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
      environment: environment, environmentFrom: source, claude: claude,
      accounts: accounts.map(\.key))
  }

  /// Writes all of `data`, waiting while the descriptor is full; false once it fails, as it
  /// does when ssh has gone.
  private static func write(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { bytes in
      var written = 0
      while written < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress! + written, bytes.count - written)
        if count > 0 {
          written += count
        } else if count < 0, errno == EINTR {
          continue
        } else if count < 0, errno == EAGAIN {
          var writable = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
          _ = poll(&writable, 1, -1)
        } else {
          return false
        }
      }
      return true
    }
  }

  /// One line on stderr, ssh's on the Mac, which shows it as it is.
  private static func say(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }
}
