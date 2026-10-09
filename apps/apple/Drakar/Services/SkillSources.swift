import DrakarKit
import Foundation

/// Runs `git`, both outputs read as they come so a full pipe never stalls it, and stops it
/// after a timeout or when the caller is cancelled. Waits on the termination handler rather
/// than `waitUntilExit`, which can hold a thread of the shared pool (see `ClaudeVersion.read`).
/// Off the main actor: it waits on a process.
nonisolated enum GitRunner {
  nonisolated struct Output: Sendable {
    var status: Int32
    var output: String
    var errors: String
    /// Stopped by the timeout.
    var timedOut: Bool
  }

  /// How long a stopped git has to end, and its pipes to close: a process it started, such as
  /// ssh or a credential helper, can hold them open after git is gone.
  static let grace = DispatchTimeInterval.seconds(2)

  /// The first `git` on `path`; nil when there is none.
  static func locate(
    path: String?,
    isExecutable: (URL) -> Bool = {
      FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false))
    }
  ) -> URL? {
    (path ?? "").split(separator: ":").lazy
      .map { URL(filePath: String($0)).appending(path: "git") }
      .first(where: isExecutable)
  }

  /// A value given once, waited for by one caller whether or not its task is cancelled: git's
  /// end and its outputs are waited for even after a cancel asked git to stop.
  private final class Latch<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var waiter: CheckedContinuation<Value, Never>?

    func give(_ value: Value) {
      lock.lock()
      guard self.value == nil else { return lock.unlock() }
      self.value = value
      let waiter = waiter
      self.waiter = nil
      lock.unlock()
      waiter?.resume(returning: value)
    }

    func wait() async -> Value {
      await withCheckedContinuation { continuation in
        lock.lock()
        if let value {
          lock.unlock()
          continuation.resume(returning: value)
        } else {
          waiter = continuation
          lock.unlock()
        }
      }
    }
  }

  /// What one pipe says, read as it comes on a queue of its own, to its end or until `stop()`,
  /// which closes the read end.
  private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let source: DispatchSourceRead
    private let result = Latch<Data>()
    /// Touched on the source's queue only.
    private var data = Data()

    init(_ pipe: Pipe) {
      handle = pipe.fileHandleForReading
      let descriptor = handle.fileDescriptor
      source = DispatchSource.makeReadSource(
        fileDescriptor: descriptor, queue: DispatchQueue(label: "drakar.git.pipe"))
      source.setEventHandler { [self] in
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count > 0 {
          data.append(contentsOf: buffer[..<count])
        } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
          source.cancel()
        }
      }
      // After the cancel handler no event handler runs, so the read end closes safely here.
      source.setCancelHandler { [self] in
        try? handle.close()
        result.give(data)
      }
      source.resume()
    }

    func stop() { source.cancel() }

    func read() async -> Data { await result.wait() }
  }

  static func run(
    _ executable: URL, _ arguments: [String], environment: [String: String], timeout: Duration
  ) async throws -> Output {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    let ended = Latch<Bool>()
    process.terminationHandler = { _ in ended.give(true) }
    try process.run()
    let out = PipeReader(output)
    let err = PipeReader(errors)
    // Asks git to end; after the grace, ends it, and stops reading pipes something else holds.
    let stop: @Sendable () -> Void = {
      process.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        out.stop()
        err.stop()
      }
    }
    return await withTaskCancellationHandler {
      let watchdog = Task {
        try await Task.sleep(for: timeout)
        guard process.isRunning else { return false }
        stop()
        return true
      }
      let outData = await out.read()
      let errData = await err.read()
      _ = await ended.wait()
      watchdog.cancel()
      let timedOut = (try? await watchdog.value) == true
      return Output(
        status: process.terminationStatus, output: String(decoding: outData, as: UTF8.self),
        errors: String(decoding: errData, as: UTF8.self), timedOut: timedOut)
    } onCancel: {
      stop()
    }
  }
}

/// Skills installed from git: each repository cloned once, shallow, under
/// `~/.agents/skill-sources/<host>/<owner>/<repo>`, pulled to update, and its skills linked
/// into the agents' folders like any other.
struct SkillSources {
  var root: URL
  /// The login shell's, so `git` and its credential helpers are found as in a terminal.
  var environment: () async -> [String: String] = { await AgentSession.environment.value }
  var timeout: Duration = .seconds(120)

  /// Clones `address`, or pulls the clone already there; returns the clone's folder.
  func fetch(_ address: String) async throws -> URL {
    let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !address.hasPrefix("-"), !address.contains("::"), let source = GitSource(address) else {
      throw SkillActionError(
        message: String(
          localized:
            "\(address) is not a git URL Drakar can clone. Use https://host/owner/repo or git@host:owner/repo."
        ))
    }
    let folder = source.folder(in: root)
    if FileManager.default.fileExists(atPath: folder.appending(path: ".git").skillPath) {
      let stored = try await git(["-C", folder.skillPath, "remote", "get-url", "origin"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard Self.isSameRepository(stored, address) else {
        throw SkillActionError(
          message: String(
            localized: "A different repository is already cloned at \(folder.skillPath)."))
      }
      try await git(["-C", folder.skillPath, "pull", "--ff-only"])
    } else {
      try FileManager.default.createDirectory(
        at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
      try await git(["clone", "--depth", "1", "--", address, folder.skillPath])
    }
    return folder
  }

  /// Pulls the clone `record` was installed from.
  func update(_ record: SkillRecord) async throws {
    guard let clone = SkillPlaces.clone(containing: record.realPath, sources: root) else {
      throw SkillActionError(
        message: String(localized: "\(record.name) was not installed from git."))
    }
    try await git(["-C", clone.skillPath, "pull", "--ff-only"])
  }

  /// Whether a clone's `stored` origin is the repository `address` names: the same host, owner
  /// and repository however spelled (https or scp, `.git` or not). A local path, or an origin
  /// Drakar cannot read, only as written, give or take a trailing `/` or `.git`.
  static func isSameRepository(_ stored: String, _ address: String) -> Bool {
    func isLocal(_ text: String) -> Bool { text.lowercased().hasPrefix("file:") }
    if !isLocal(stored), !isLocal(address), let mine = GitSource(stored),
      let theirs = GitSource(address)
    {
      return mine == theirs
    }
    func spelling(_ text: String) -> String {
      var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
      while text.hasSuffix("/") { text.removeLast() }
      if text.hasSuffix(".git") { text.removeLast(4) }
      return text
    }
    return spelling(stored) == spelling(address)
  }

  /// `base` with git kept from asking anyone: no terminal prompt for a password, and ssh in
  /// batch mode, so a missing credential fails at once instead of waiting for the timeout. A
  /// value `base` already sets stays.
  static func gitEnvironment(_ base: [String: String]) -> [String: String] {
    var environment = base
    if environment["GIT_TERMINAL_PROMPT"] == nil { environment["GIT_TERMINAL_PROMPT"] = "0" }
    if environment["GIT_SSH_COMMAND"] == nil {
      environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
    }
    return environment
  }

  @discardableResult
  private func git(_ arguments: [String]) async throws -> String {
    let environment = Self.gitEnvironment(await environment())
    guard let executable = GitRunner.locate(path: environment["PATH"]) else {
      throw SkillActionError(
        message: String(localized: "Git was not found. Install the Xcode command line tools."))
    }
    let result = try await GitRunner.run(
      executable, arguments, environment: environment, timeout: timeout)
    if result.timedOut {
      throw SkillActionError(
        message: String(
          localized:
            "Git took longer than \(Int(timeout.components.seconds)) seconds and was stopped."))
    }
    guard result.status == 0 else {
      let words = result.errors.trimmingCharacters(in: .whitespacesAndNewlines)
      throw SkillActionError(
        message: words.isEmpty
          ? String(localized: "Git failed with status \(result.status).") : words)
    }
    return result.output
  }
}
