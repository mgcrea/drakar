import Foundation

/// One entry of a session host's log of a process: a line the CLI wrote (`out`), one it was
/// sent (`in`), or a note the app left for its own replay (`note`). The host never reads
/// `bytes`.
public struct HostRecord: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable { case out, `in`, note }

  /// Its position in the log, in bytes: what an attach resumes from.
  public var offset: UInt64
  public var kind: Kind
  public var time: Date
  /// An app was attached when the host logged it. Says nothing of a reply: only a logged
  /// `in` says one was written.
  public var attached: Bool
  public var bytes: Data

  public init(offset: UInt64, kind: Kind, time: Date, attached: Bool, bytes: Data) {
    self.offset = offset
    self.kind = kind
    self.time = time
    self.attached = attached
    self.bytes = bytes
  }
}
