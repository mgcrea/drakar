import Foundation

/// A process's log on disk: one JSON line per `HostRecord`, `Data` as base64. A record's
/// `offset` is where its line starts. The host never reads `bytes`.
public final class HostLog: @unchecked Sendable {
  private let url: URL
  private let handle: FileHandle
  private let lock = NSLock()
  private var end: UInt64

  /// Opens or creates the file. A last line the host died halfway through writing is not a
  /// record: the log ends before it, and the next append overwrites it.
  public init(url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
      let made = FileManager.default.createFile(
        atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
      guard made else { throw CocoaError(.fileWriteUnknown) }
    }
    self.url = url
    handle = try FileHandle(forUpdating: url)
    let existing = try handle.readToEnd() ?? Data()
    end = existing.lastIndex(of: 0x0A).map { UInt64($0 + 1) } ?? 0
  }

  deinit { try? handle.close() }

  /// Where the last whole record ends.
  public var length: UInt64 { lock.withLock { end } }

  @discardableResult
  public func append(
    _ kind: HostRecord.Kind, bytes: Data, time: Date, attached: Bool
  ) throws -> HostRecord {
    try lock.withLock {
      let record = HostRecord(offset: end, kind: kind, time: time, attached: attached, bytes: bytes)
      var line = try JSONEncoder().encode(record)
      line.append(0x0A)
      try handle.seek(toOffset: end)
      try handle.write(contentsOf: line)
      try handle.truncate(atOffset: end + UInt64(line.count))
      end += UInt64(line.count)
      return record
    }
  }

  /// Every whole record from `offset` up to `limit` (the end when nil), each of which must be
  /// where a record starts or the end. Appends past `limit` meanwhile change nothing read.
  /// Decoded once the lock is let go: an append, which the host makes under its own lock,
  /// waits only for the read.
  public func records(from offset: UInt64, to limit: UInt64? = nil) throws -> [HostRecord] {
    let data = try lock.withLock { () throws -> Data in
      let stop = min(limit ?? end, end)
      guard offset < stop else { return Data() }
      try handle.seek(toOffset: offset)
      return try handle.read(upToCount: Int(stop - offset)) ?? Data()
    }
    let decoder = JSONDecoder()
    return try data.split(separator: 0x0A).map {
      try decoder.decode(HostRecord.self, from: Data($0))
    }
  }

  public func remove() throws {
    try lock.withLock {
      try handle.close()
      try FileManager.default.removeItem(at: url)
    }
  }
}
