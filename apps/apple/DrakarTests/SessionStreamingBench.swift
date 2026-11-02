import AppKit
import DrakarKit
import Foundation
import SwiftUI
import Testing

@testable import Drakar

/// What a session streaming into the pane on screen costs the main thread. Not a test: it
/// asserts nothing about time (loaded runs make wall-clock budgets noise) and runs only when
/// asked, `make bench`, which prints the figures to compare before and after a change.
@MainActor
@Suite(
  "Streaming benchmark",
  .enabled(if: ProcessInfo.processInfo.environment["DRAKAR_BENCH"] != nil),
  .serialized)
struct SessionStreamingBench {
  private let folder: URL
  private let fake: URL
  /// Replies already in the transcript when the streaming one starts.
  private static let history = 60
  /// Tokens the streamed reply comes in, at `pace` seconds apart.
  private static let tokens = 1_000
  private static let pace = "0.01"

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(
      path: "drakar-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    fake = folder.appending(path: "claude")
    let reply =
      "Here is **what changed**, in order:\\n\\n- the `status` split\\n- the sidebar rows\\n\\n```swift\\nlet x = 1\\n```\\n\\nAnd a paragraph of plain prose to read through, long enough to wrap twice in the pane."
    let script = """
      #!/bin/sh
      read -r line
      printf '%s\\n' '{"type":"system","subtype":"init","cwd":"/tmp","session_id":"s-bench","model":"m","permissionMode":"default"}'
      while read -r line; do case "$line" in *'"type":"user"'*) break;; esac; done
      i=0
      while [ $i -lt \(Self.history) ]; do
        printf '%s\\n' '{"type":"assistant","message":{"id":"h'$i'","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"\(reply)"}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"s-bench"}'
        i=$((i + 1))
      done
      touch "$0.ready"
      while [ ! -f "$0.go" ]; do sleep 0.02; done
      printf '%s\\n' '{"type":"stream_event","event":{"type":"message_start","message":{"id":"live"}}}'
      printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}'
      i=0
      while [ $i -lt \(Self.tokens) ]; do
        case $((i % 40)) in
          0) word='\\n\\n**Point** ';;
          20) word='\\n- `item` ';;
          *) word='word ';;
        esac
        printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"'"$word"'"}}}'
        sleep \(Self.pace)
        i=$((i + 1))
      done
      touch "$0.done"
      exec cat > /dev/null

      """
    try Data(script.utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
  }

  /// CPU time the main thread has used, user and system.
  private static func mainThreadCPU() -> Duration {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let port = pthread_mach_thread_np(pthread_self())
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return .zero }
    func duration(_ time: time_value_t) -> Duration {
      .seconds(Int64(time.seconds)) + .microseconds(Int64(time.microseconds))
    }
    return duration(info.user_time) + duration(info.system_time)
  }

  private func wait(for file: URL, timeout: Duration = .seconds(60)) async throws {
    let deadline = ContinuousClock.now + timeout
    while !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
      guard ContinuousClock.now < deadline else { throw CancellationError() }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  @Test func aSessionStreamingOnScreen() async throws {
    defer { try? FileManager.default.removeItem(at: folder) }
    let project = Project(folder: folder)
    let item = project.newSession(agent: .claude)
    item.session.executableOverride = fake
    item.session.accounts = { [] }
    item.session.makeTransport = { AgentProcess($0) }
    defer { item.session.stop() }

    let window = NSWindow(
      contentRect: NSRect(x: 80, y: 80, width: 900, height: 900),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: SessionView(item: item, project: project))
    window.orderFrontRegardless()
    defer { window.close() }

    item.session.send("go")
    try await wait(for: fake.appendingPathExtension("ready"))
    // Let the history land and draw before anything is measured.
    try await Task.sleep(for: .seconds(2))

    let span = Duration.seconds(Double(Self.tokens) * (Double(Self.pace) ?? 0.01) * 1.2)
    let idleStart = Self.mainThreadCPU()
    try await Task.sleep(for: span)
    let idle = Self.mainThreadCPU() - idleStart

    let clock = ContinuousClock()
    let start = clock.now
    let cpuStart = Self.mainThreadCPU()
    try Data().write(to: fake.appendingPathExtension("go"))
    try await wait(for: fake.appendingPathExtension("done"))
    // The last lines are read and drawn shortly after the stand-in says it is done.
    try await Task.sleep(for: .milliseconds(500))
    let streaming = Self.mainThreadCPU() - cpuStart
    let wall = clock.now - start

    let entries = item.session.transcript.entries.count
    func ms(_ d: Duration) -> Double {
      Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
    print(
      String(
        format:
          "BENCH streaming: %d tokens over %.1f s, %d entries; main thread %.0f ms (%.1f%% of a core, %.2f ms a token); idle control %.0f ms over %.1f s",
        Self.tokens, ms(wall) / 1000, entries, ms(streaming), 100 * ms(streaming) / ms(wall),
        ms(streaming) / Double(Self.tokens), ms(idle), ms(span) / 1000))
    #expect(entries > Self.history)
  }
}
