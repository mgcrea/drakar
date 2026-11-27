import Darwin
import DrakarKit
import Foundation

/// Asking the Antigravity CLI (`agy`) for the account's live quotas and plan tier.
///
/// `agy` writes no plan limits to disk and `agy acp` does not expose a quota method yet.
/// Its documented `statusLine` hook does emit them as structured JSON (`quota` buckets plus
/// `plan_tier`), and `--settings` passes a session-only settings object that is never saved
/// to `~/.gemini/antigravity-cli/settings.json`.
///
/// **Isolated in an empty, untrusted directory.** Running `agy` inside a fresh `0700` temp
/// directory not in `trustedWorkspaces` holds the TUI at its workspace trust prompt
/// (`agent_state: "initializing"`): `agy` authenticates and pipes live quotas and `plan_tier`
/// in ~1.2–2.0s while starting no MCP servers, loading no workspace hooks, creating no
/// `conversation_summaries.db` row and holding no `presence/*.lock`. Drakar never opens
/// `~/.gemini/antigravity-cli`'s encrypted files or credentials, and sends no prompt.
nonisolated enum AgyLimitsProbe {
  static let timeout: Duration = .seconds(15)
  /// `plan_tier` arrives ~0.5–1s after the first payload carrying `quota`. Waiting briefly
  /// picks up the plan label without hanging on accounts that report none.
  static let tierGrace: Duration = .seconds(1.5)
  static let killGrace: Duration = .seconds(2)
  static let pollInterval: Duration = .milliseconds(80)

  /// True once `~/.gemini/antigravity-cli` exists on this Mac, so Macs that have never run
  /// `agy` skip probing altogether.
  static func isHomePresent(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Bool {
    let directory = home.appending(path: ".gemini/antigravity-cli", directoryHint: .isDirectory)
    return FileManager.default.fileExists(atPath: directory.path(percentEncoded: false))
  }

  /// Probes `executable` in a fresh untrusted directory and returns the parsed quotas, or nil
  /// on timeout, cancellation, or error.
  static func limits(
    executable: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    timeout: Duration = timeout,
    tierGrace: Duration = tierGrace,
    killGrace: Duration = killGrace
  ) async -> AgyUsage? {
    guard !Task.isCancelled else { return nil }
    let fileManager = FileManager.default
    let probeDir = fileManager.temporaryDirectory.appending(
      path: "drakar-agy-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
    do {
      try fileManager.createDirectory(
        at: probeDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      return nil
    }
    defer { try? fileManager.removeItem(at: probeDir) }

    let payloadURL = probeDir.appending(path: "payload.json", directoryHint: .notDirectory)
    let tempURL = probeDir.appending(path: "payload.tmp", directoryHint: .notDirectory)
    let scriptURL = probeDir.appending(path: "capture.sh", directoryHint: .notDirectory)

    let script = """
      #!/bin/sh
      cat > \(shellQuoted(tempURL.path(percentEncoded: false))) \
      && /bin/mv -f \(shellQuoted(tempURL.path(percentEncoded: false))) \
      \(shellQuoted(payloadURL.path(percentEncoded: false)))
      """
    do {
      try Data(script.utf8).write(to: scriptURL, options: .atomic)
      try fileManager.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: scriptURL.path(percentEncoded: false))
    } catch {
      return nil
    }

    let settingsObject: [String: Any] = [
      "statusLine": [
        "type": "command",
        "command": scriptURL.path(percentEncoded: false),
      ]
    ]
    guard let settingsData = try? JSONSerialization.data(withJSONObject: settingsObject),
      let settingsJSON = String(data: settingsData, encoding: .utf8)
    else { return nil }

    var env = environment
    if env["TERM"] == nil { env["TERM"] = "xterm-256color" }

    return await runInPTY(
      executable: executable,
      arguments: ["--settings", settingsJSON],
      environment: env,
      directory: probeDir,
      payloadURL: payloadURL,
      timeout: timeout,
      tierGrace: tierGrace,
      killGrace: killGrace
    )
  }

  /// Spawns `executable` in its own session (`POSIX_SPAWN_SETSID`) attached to a fresh PTY,
  /// drains the master fd while polling `payloadURL`, and tears down the child's process group
  /// before returning.
  private static func runInPTY(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    directory: URL,
    payloadURL: URL,
    timeout: Duration,
    tierGrace: Duration,
    killGrace: Duration
  ) async -> AgyUsage? {
    let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
    guard masterFD >= 0 else { return nil }
    defer { Darwin.close(masterFD) }

    guard grantpt(masterFD) == 0, unlockpt(masterFD) == 0,
      let slaveCPath = ptsname(masterFD)
    else { return nil }
    let slavePath = String(cString: slaveCPath)

    let closeFlags = fcntl(masterFD, F_GETFD)
    if closeFlags >= 0 { _ = fcntl(masterFD, F_SETFD, closeFlags | FD_CLOEXEC) }
    let ioFlags = fcntl(masterFD, F_GETFL)
    if ioFlags >= 0 { _ = fcntl(masterFD, F_SETFL, ioFlags | O_NONBLOCK) }

    var attr: posix_spawnattr_t?
    guard posix_spawnattr_init(&attr) == 0 else { return nil }
    defer { posix_spawnattr_destroy(&attr) }
    guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID)) == 0 else { return nil }

    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
    defer { posix_spawn_file_actions_destroy(&actions) }

    let dirPath = directory.path(percentEncoded: false)
    guard posix_spawn_file_actions_addchdir_np(&actions, dirPath) == 0,
      posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slavePath, O_RDWR, 0) == 0,
      posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO) == 0
    else { return nil }

    let executablePath = executable.path(percentEncoded: false)
    let cArgs = ([executablePath] + arguments).map { strdup($0) }
    defer { for ptr in cArgs { free(ptr) } }
    var argv = cArgs + [nil]

    let cEnv = environment.map { strdup("\($0.key)=\($0.value)") }
    defer { for ptr in cEnv { free(ptr) } }
    var envp = cEnv + [nil]

    var pid: pid_t = 0
    let spawnResult = posix_spawn(&pid, executablePath, &actions, &attr, &argv, &envp)
    guard spawnResult == 0, pid > 0 else { return nil }

    var best: AgyUsage?
    var tierDeadline: ContinuousClock.Instant?
    let overallDeadline = ContinuousClock.now + timeout
    var drainBuffer = [UInt8](repeating: 0, count: 4096)
    var reaped = false

    while !Task.isCancelled {
      var eof = false
      while true {
        let count = Darwin.read(masterFD, &drainBuffer, drainBuffer.count)
        if count > 0 { continue }
        if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { eof = true }
        break
      }

      if !reaped {
        var waitStatus: Int32 = 0
        if waitpid(pid, &waitStatus, WNOHANG) > 0 { reaped = true }
      }

      if let data = try? Data(contentsOf: payloadURL),
        let parsed = AgyUsage(statusLineData: data, at: .now)
      {
        best = parsed
        if parsed.plan != nil { break }
        if tierDeadline == nil { tierDeadline = ContinuousClock.now + tierGrace }
      }

      let now = ContinuousClock.now
      if let tierDeadline, now >= tierDeadline { break }
      if reaped || eof || now >= overallDeadline { break }

      try? await Task.sleep(for: pollInterval)
    }

    if !reaped {
      await stopProcessGroup(pid, grace: killGrace)
    }

    return Task.isCancelled ? nil : best
  }

  /// Sends `SIGTERM` to the child's process group, waits up to `grace` without blocking a
  /// cooperative thread (even when cancelled), then sends `SIGKILL` and reaps the leader.
  private static func stopProcessGroup(_ pid: pid_t, grace: Duration) async {
    var status: Int32 = 0
    if waitpid(pid, &status, WNOHANG) > 0 { return }
    _ = Darwin.kill(-pid, SIGTERM)
    let deadline = ContinuousClock.now + grace
    while ContinuousClock.now < deadline {
      if waitpid(pid, &status, WNOHANG) > 0 { return }
      await uncancellableSleep(milliseconds: 50)
    }
    if waitpid(pid, &status, WNOHANG) > 0 { return }
    _ = Darwin.kill(-pid, SIGKILL)
    _ = waitpid(pid, &status, 0)
  }

  private static func uncancellableSleep(milliseconds: Int) async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).asyncAfter(
        deadline: .now() + .milliseconds(milliseconds)
      ) {
        continuation.resume()
      }
    }
  }

  private static func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
