import DrakarKit
import Foundation

// The session host (spec §1): holds the CLIs Drakar's sessions run, so they outlive the
// app. Started by the app's `SessionHost`, detached; it leaves once it has nothing to hold.

/// Each process held takes about four descriptors (three pipes and its log), and a
/// connected app one more: the default soft limit of 256 runs out near sixty sessions.
/// Raised as far as the hard limit lets, and `OPEN_MAX`, past which `setrlimit` refuses.
func raiseDescriptorLimit() {
  var limit = rlimit()
  guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
  let wanted = min(limit.rlim_max, rlim_t(OPEN_MAX))
  guard limit.rlim_cur < wanted else { return }
  limit.rlim_cur = wanted
  setrlimit(RLIMIT_NOFILE, &limit)
}

let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: "--directory"), flag + 1 < arguments.count else {
  FileHandle.standardError.write(Data("usage: DrakarHost --directory <dir>\n".utf8))
  exit(64)
}
let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
let version =
  Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

raiseDescriptorLimit()
// A write to an app or a CLI that left fails with EPIPE rather than ending every session.
signal(SIGPIPE, SIG_IGN)

let core = HostCore(directory: directory, hostVersion: version)
let server: HostServer
do {
  // Nil when another host holds the directory: that one serves the apps.
  guard
    let started = try HostServer.start(
      directory: directory, core: core, peerCheck: PeerSignature.sameTeam(fd:))
  else { exit(0) }
  server = started
} catch {
  FileHandle.standardError.write(Data("DrakarHost: \(error)\n".utf8))
  exit(1)
}

/// Idle (nothing held, no app connected) for 30 seconds in a row, checked every 5.
let idleLimit = 30.0
let timer = DispatchSource.makeTimerSource(queue: .main)
var idleSince: Date?
timer.schedule(deadline: .now() + 5, repeating: 5)
timer.setEventHandler {
  guard core.isIdle else {
    idleSince = nil
    return
  }
  let since = idleSince ?? Date()
  idleSince = since
  if Date().timeIntervalSince(since) >= idleLimit {
    server.stop()
    exit(0)
  }
}
timer.activate()
dispatchMain()
