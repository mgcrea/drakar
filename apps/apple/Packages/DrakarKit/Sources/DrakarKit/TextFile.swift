import Foundation

/// What the editor opens, and how a file that changed on disk is folded back into it.
public enum TextFile {
  /// Past this the file is a log or a dump, not something to edit in a text view.
  public static let maximumSize = 8_000_000

  public enum Failure: Error, Sendable, Equatable {
    case notFound
    case isDirectory
    case tooLarge(bytes: Int)
    /// A NUL byte in the first 8 KB: an image, an archive, a compiled file.
    case binary
    case notUTF8
  }

  public static func read(_ url: URL) -> Result<String, Failure> {
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
    else { return .failure(.notFound) }
    if isDirectory.boolValue { return .failure(.isDirectory) }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size <= maximumSize else { return .failure(.tooLarge(bytes: size)) }
    guard let data = try? Data(contentsOf: url) else { return .failure(.notFound) }
    return decode(data)
  }

  public static func decode(_ data: Data) -> Result<String, Failure> {
    if data.prefix(8192).contains(0) { return .failure(.binary) }
    guard let text = String(data: data, encoding: .utf8) else { return .failure(.notUTF8) }
    return .success(text)
  }

  /// What an open document should do now that its file reads `disk`.
  public enum DiskChange: Sendable, Equatable {
    /// Nothing the document does not already know, such as the echo of its own save.
    case none
    /// Take the new contents: the user had not edited it, or had made the same edit.
    case reload(String)
    /// Both the user and something else changed it. The user decides.
    case conflict(String)
    case deleted
  }

  /// - Parameters:
  ///   - saved: the contents last read from or written to disk.
  ///   - current: the editor's contents now.
  ///   - disk: the file read again.
  public static func reconcile(saved: String, current: String, disk: Result<String, Failure>)
    -> DiskChange
  {
    switch disk {
    case .failure(.notFound): return .deleted
    // Turned binary or huge under the editor: keep what is open, the user saves or not.
    case .failure: return .none
    case .success(let text) where text == saved: return .none
    case .success(let text) where current == saved || current == text: return .reload(text)
    case .success(let text): return .conflict(text)
    }
  }
}
