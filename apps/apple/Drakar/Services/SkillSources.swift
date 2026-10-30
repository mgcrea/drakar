import DrakarKit
import Foundation

/// Runs `git` through DrakarKit's `ProcessRunner`: both outputs read as they come, stopped
/// after a timeout or when the caller is cancelled, and no thread of the shared pool held
/// while it waits. Off the main actor: it waits on a process.
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

  static func run(
    _ executable: URL, _ arguments: [String], environment: [String: String], timeout: Duration
  ) async throws -> Output {
    let result = try await ProcessRunner.run(
      executable, arguments, environment: environment, timeout: timeout)
    return Output(
      status: result.status, output: String(decoding: result.output, as: UTF8.self),
      errors: String(decoding: result.errors, as: UTF8.self), timedOut: result.timedOut)
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
