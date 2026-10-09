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

  /// `https://host/owner/repo(.git)`, `ssh://…`, `git://…`, `file://…` (host `local`), or
  /// `git@host:owner/repo(.git)`; nil for anything else, or a path with `.` or `..` in it.
  public init?(_ text: String) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let host: String
    let path: String
    if !text.contains("://"), let at = text.firstIndex(of: "@"),
      let colon = text[at...].firstIndex(of: ":")
    {
      host = String(text[text.index(after: at)..<colon])
      path = String(text[text.index(after: colon)...])
    } else if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
      ["https", "http", "ssh", "git", "file"].contains(scheme)
    {
      host = url.host(percentEncoded: false) ?? (scheme == "file" ? "local" : "")
      path = url.path(percentEncoded: false)
    } else {
      return nil
    }
    let parts = path.split(separator: "/").map(String.init)
    guard parts.count >= 2, !host.isEmpty, !host.contains("/"),
      parts.allSatisfy({ $0 != "." && $0 != ".." })
    else { return nil }
    var repo = parts[parts.count - 1]
    if repo.hasSuffix(".git") { repo.removeLast(4) }
    guard !repo.isEmpty else { return nil }
    self.host = host.lowercased()
    self.owner = parts[parts.count - 2]
    self.repo = repo
  }

  public func folder(in root: URL) -> URL {
    root.appending(path: host, directoryHint: .isDirectory)
      .appending(path: owner, directoryHint: .isDirectory)
      .appending(path: repo, directoryHint: .isDirectory)
  }
}
