import DrakarKit
import Foundation

/// Runs `git`, both outputs read as they come so a full pipe never stalls it, and stops it
/// after a timeout. Waits on the termination handler rather than `waitUntilExit`, which can
/// hold a thread of the shared pool (see `ClaudeVersion.read`). Off the main actor: it waits
/// on a process.
nonisolated enum GitRunner {
  nonisolated struct Output: Sendable {
    var status: Int32
    var output: String
    var errors: String
    /// Stopped by the timeout.
    var timedOut: Bool
  }

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

  /// Reads `pipe` to its end on a dispatch thread, so the waits never hold the shared pool.
  private static func drain(_ pipe: Pipe) async -> Data {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: pipe.fileHandleForReading.readDataToEndOfFile())
      }
    }
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
    let (ended, ending) = AsyncStream<Void>.makeStream()
    process.terminationHandler = { _ in ending.finish() }
    try process.run()
    let watchdog = Task {
      try await Task.sleep(for: timeout)
      if process.isRunning { process.terminate() }
      return true
    }
    async let out = drain(output)
    async let err = drain(errors)
    let (outData, errData) = await (out, err)
    for await _ in ended {}
    watchdog.cancel()
    let timedOut = (try? await watchdog.value) == true
    return Output(
      status: process.terminationStatus, output: String(decoding: outData, as: UTF8.self),
      errors: String(decoding: errData, as: UTF8.self), timedOut: timedOut)
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
    guard let source = GitSource(address) else {
      throw SkillActionError(
        message: String(
          localized:
            "\(address) is not a git URL Drakar can clone. Use https://host/owner/repo or git@host:owner/repo."
        ))
    }
    let folder = source.folder(in: root)
    if FileManager.default.fileExists(atPath: folder.appending(path: ".git").skillPath) {
      try await git(["-C", folder.skillPath, "pull", "--ff-only"])
    } else {
      try FileManager.default.createDirectory(
        at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
      try await git(["clone", "--depth", "1", address, folder.skillPath])
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

  private func git(_ arguments: [String]) async throws {
    let environment = await environment()
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
  }
}
