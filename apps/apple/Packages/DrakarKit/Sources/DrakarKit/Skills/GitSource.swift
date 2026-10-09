import Foundation

/// A git repository's address, read for where its clone goes: `<host>/<owner>/<repo>` below
/// the folder Drakar keeps clones in.
public struct GitSource: Sendable, Hashable {
  public var host: String
  public var owner: String
  public var repo: String

  public init(host: String, owner: String, repo: String) {
    self.host = host
    self.owner = owner
    self.repo = repo
  }

  /// `https://host/owner/repo(.git)`, `git@host:owner/repo(.git)`, or `file://…` (host
  /// `local`, for a repository on this Mac); nil for anything else, `http`, `git://` and
  /// `ssh://` included, or a path with `.` or `..` in it.
  public init?(_ text: String) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let host: String
    let path: String
    if text.hasPrefix("git@"), !text.contains("://"), let colon = text.firstIndex(of: ":") {
      host = String(text[text.index(text.startIndex, offsetBy: 4)..<colon])
      path = String(text[text.index(after: colon)...])
    } else if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "file"
    {
      host = url.host(percentEncoded: false) ?? (scheme == "file" ? "local" : "")
      path = url.path(percentEncoded: false)
    } else {
      return nil
    }
    let parts = path.split(separator: "/").map(String.init)
    guard parts.count >= 2, parts.allSatisfy({ $0.contains { $0 != "." } }) else { return nil }
    var repo = parts[parts.count - 1]
    if repo.hasSuffix(".git") { repo.removeLast(4) }
    let lowered = host.lowercased()
    let owner = parts[parts.count - 2]
    guard [lowered, owner, repo].allSatisfy(Self.isFolderName) else { return nil }
    self.host = lowered
    self.owner = owner
    self.repo = repo
  }

  /// A name that is one plain folder: letters, digits, `.`, `_` and `-`, and not only dots.
  private static func isFolderName(_ name: String) -> Bool {
    !name.isEmpty && name.contains { $0 != "." }
      && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
  }

  /// Where the clone goes. A source built by hand with an unsafe name is a programmer error.
  public func folder(in root: URL) -> URL {
    precondition(
      [host, owner, repo].allSatisfy(Self.isFolderName), "unsafe clone folder name in \(self)")
    return root.appending(path: host, directoryHint: .isDirectory)
      .appending(path: owner, directoryHint: .isDirectory)
      .appending(path: repo, directoryHint: .isDirectory)
  }
}
