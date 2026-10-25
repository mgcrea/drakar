import Foundation
import Testing

@testable import DrakarKit

@Suite struct HostLogTests {
  private func makeLog() throws -> (HostLog, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostlog-\(UUID().uuidString)")
    return (try HostLog(url: url), url)
  }

  private let time = Date(timeIntervalSince1970: 1_000)

  @Test func appendsAndReadsFromAnOffset() throws {
    let (log, url) = try makeLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let first = try log.append(.out, bytes: Data("one".utf8), time: time, attached: false)
    let second = try log.append(.in, bytes: Data("two".utf8), time: time, attached: true)
    let third = try log.append(.note, bytes: Data("three".utf8), time: time, attached: true)
    #expect(first.offset == 0)
    #expect(try log.records(from: second.offset) == [second, third])
    #expect(try log.records(from: 0).count == 3)
    #expect(try log.records(from: log.length).isEmpty)
  }

  @Test func aTornLastLineIsIgnored() throws {
    let (log, url) = try makeLog()
    defer { try? FileManager.default.removeItem(at: url) }
    try log.append(.out, bytes: Data("one".utf8), time: time, attached: false)
    try log.append(.out, bytes: Data("two".utf8), time: time, attached: false)
    let whole = log.length
    let writer = try FileHandle(forWritingTo: url)
    try writer.seekToEnd()
    try writer.write(contentsOf: Data(#"{"offset":9,"kind":"o"#.utf8))
    try writer.close()
    #expect(try log.records(from: 0).count == 2)
    #expect(log.length == whole)
    // The next append replaces the torn tail, and a reopened log agrees.
    let third = try log.append(.out, bytes: Data("three".utf8), time: time, attached: false)
    #expect(third.offset == whole)
    #expect(try HostLog(url: url).records(from: 0).count == 3)
  }

  @Test func aReopenedLogEndsWhereItEnded() throws {
    let (log, url) = try makeLog()
    defer { try? FileManager.default.removeItem(at: url) }
    try log.append(.out, bytes: Data("one".utf8), time: time, attached: false)
    #expect(try HostLog(url: url).length == log.length)
  }

  @Test func bytesSurviveExactly() throws {
    let (log, url) = try makeLog()
    defer { try? FileManager.default.removeItem(at: url) }
    let bytes = Data([0x00, 0x0A, 0xFF, 0xFE, 0xC3, 0x28, 0x0A])
    try log.append(.out, bytes: bytes, time: time, attached: false)
    let back = try log.records(from: 0)
    #expect(back.count == 1)
    #expect(back[0].bytes == bytes)
    #expect(back[0].time == time)
  }
}
