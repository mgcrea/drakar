import Foundation
import Synchronization
import Testing

@testable import DrakarKit

/// `HostChild` against a stand-in agent that prints one line of several megabytes, which the
/// pipe hands over in hundreds of chunks.
@Suite struct HostChildTests {
  @Test func aLongLineIsFramedWholeAndFast() async throws {
    let alphabet = "abcdefghijklmnopqrstuvwxyz"
    let count = 320_000
    let child = HostChild(
      AgentProcess.Configuration(
        executable: URL(fileURLWithPath: "/usr/bin/perl"),
        arguments: ["-e", "print '\(alphabet)' x \(count), \"\\n\""], environment: [:],
        currentDirectory: URL(fileURLWithPath: "/tmp")))
    let lines = Mutex<[Data]>([])
    let started = ContinuousClock.now
    let status: Int32 = await withCheckedContinuation { continuation in
      do {
        try child.start { output in
          switch output {
          case .line(let line): lines.withLock { $0.append(line) }
          case .stderr: break
          case .exited(let status): continuation.resume(returning: status)
          }
        }
      } catch {
        continuation.resume(returning: -1)
      }
    }
    let elapsed = ContinuousClock.now - started
    #expect(status == 0)
    let expected = Data(String(repeating: alphabet, count: count).utf8) + [0x0A]
    let framed = lines.withLock { $0 }
    #expect(framed.count == 1)
    #expect(framed.first == expected)
    // `LineBuffer` once searched the whole line again for every chunk: 8 MB took seconds.
    #expect(elapsed < .seconds(2))
  }
}
