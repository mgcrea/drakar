import DrakarKit
import Foundation
import Observation

/// What a window shows: a new session in a folder, or an existing session resumed.
///
/// A window's value, so SwiftUI restores it at launch and `openWindow(value:)` brings
/// forward the window already showing a session instead of opening a second one: two
/// windows resuming one session would be two writers on one transcript.
enum SessionRoute: Codable, Hashable {
  /// `token` keeps two new sessions in the same folder apart.
  case new(folder: String, token: UUID)
  case resume(ResumeTarget)

  static func new(folder: URL) -> SessionRoute {
    .new(folder: folder.path(percentEncoded: false), token: UUID())
  }

  static func resume(_ summary: SessionSummary, forking: Bool = false) -> SessionRoute? {
    guard let cwd = summary.cwd else { return nil }
    return .resume(
      ResumeTarget(
        sessionID: summary.sessionID, cwd: cwd, file: summary.file.path(percentEncoded: false),
        accountDirectory: summary.account.directory.path(percentEncoded: false),
        accountIsDefault: summary.account.isDefault, forks: forking ? true : nil))
  }

  var folder: URL {
    switch self {
    case .new(let folder, _): URL(filePath: folder, directoryHint: .isDirectory)
    case .resume(let target): URL(filePath: target.cwd, directoryHint: .isDirectory)
    }
  }

  var sessionID: String? {
    if case .resume(let target) = self { return target.sessionID }
    return nil
  }
}

struct ResumeTarget: Codable, Hashable {
  var sessionID: String
  var cwd: String
  var file: String
  var accountDirectory: String
  var accountIsDefault: Bool
  /// Continue a copy under a new id: the session is open in another process. Optional so
  /// that a window restored from before the field existed still decodes.
  var forks: Bool?

  var account: ClaudeAccount {
    ClaudeAccount(
      directory: URL(filePath: accountDirectory, directoryHint: .isDirectory),
      isDefault: accountIsDefault)
  }

  var transcriptFile: URL { URL(filePath: file) }
}

/// The sessions Drakar's own windows have open, by session id, with the route each window
/// holds. `openWindow(value:)` with that exact route brings the window forward rather than
/// opening a second writer on the same transcript.
@Observable
final class OpenSessions {
  static let shared = OpenSessions()
  private(set) var routes: [String: SessionRoute] = [:]

  func register(_ route: SessionRoute, for sessionID: String) { routes[sessionID] = route }

  func unregister(_ sessionID: String) { routes[sessionID] = nil }
}
