import Foundation

/// The VS Code window a session runs in. Its `claude` is a child of the window's extension
/// host, which listens on the port its lock file is named for, and the lock names the
/// window's folder. The port in the session's own `CLAUDE_CODE_SSE_PORT` can be stale.
public enum VSCodeWindow {
  /// What the Claude Code extension shows `sessionID` for, in VS Code's front window. A
  /// `prompt` in it is dropped for a session already open, so none is passed.
  public static func link(sessionID: String) -> URL? {
    var components = URLComponents()
    components.scheme = "vscode"
    components.host = "anthropic.claude-code"
    components.path = "/open"
    components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
    return components.url
  }

  /// The first workspace folder of the lock file named for one of `ports`, in any of
  /// `directories`.
  public static func folder(listeningOn ports: [Int], in directories: [URL]) -> String? {
    for port in ports {
      for directory in directories {
        guard let data = try? Data(contentsOf: directory.appending(path: "\(port).lock")),
          let json = try? JSONValue.parse(data),
          let folder = json["workspaceFolders"]?.arrayValue?.first?.stringValue
        else { continue }
        return folder
      }
    }
    return nil
  }
}
