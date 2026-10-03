import AppKit
import DrakarKit
import Foundation
import Observation
import SwiftUI

/// Drakar as the editor of `claude` sessions run in a terminal: the lock files that
/// advertise it, the server they lead to, and the diffs waiting on the user.
///
/// A terminal `claude` started with `--ide` (or connected with `/ide`) in a folder Drakar
/// has open sends every edit here as an `openDiff`, and writes the file only if the user
/// accepts it in the review window. Headless sessions never connect, so Drakar's own
/// windows keep their permission sheet.
@Observable
final class IDEBridge {
  static let shared = IDEBridge()

  /// An edit a terminal session proposed, waiting on Accept or Reject.
  struct PendingDiff: Identifiable {
    let id = UUID()
    let connection: IDEConnection
    let requestID: JSONValue
    let diff: OpenDiff
    let change: FileChange
    let claudePID: Int32?
  }

  private(set) var port: UInt16?
  private(set) var pending: [PendingDiff] = []
  private(set) var failure: String?

  @ObservationIgnored private var server: IDEServer?
  @ObservationIgnored private var lockFiles: [URL] = []
  @ObservationIgnored private var folders: [String] = []
  @ObservationIgnored private lazy var review = ReviewWindowController(bridge: self)

  /// Sweeps the locks a crashed Drakar left (they would stop `claude --ide` connecting to
  /// anything), then listens and advertises.
  func start() {
    guard server == nil else { return }
    for account in ClaudeAccount.discover() {
      let directory = IDELockFile.directory(for: account)
      for stale in IDELockFile.stale(
        in: directory, ideName: IDEReply.ideName, isAlive: LiveSession.isAlive)
      {
        try? FileManager.default.removeItem(at: stale)
      }
    }
    let server = IDEServer(
      onMessage: { [weak self] connection, message in self?.handle(message, from: connection) },
      onClose: { [weak self] connection in self?.closed(connection) })
    do {
      try server.start(
        ready: { [weak self] port in
          self?.port = port
          self?.refreshFolders()
          self?.writeLocks()
        },
        failed: { [weak self] message in self?.failure = message })
      self.server = server
    } catch {
      failure = error.localizedDescription
    }
  }

  /// Removes the lock files; called as the app quits.
  func stop() {
    removeLocks()
    server?.stop()
    server = nil
  }

  /// Re-reads the setting and the open windows' folders.
  func refreshFolders() {
    switch EditorScope.current {
    case .openFolders: setFolders(OpenSessions.shared.folders)
    case .home:
      setFolders([FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)])
    case .off: setFolders([])
    }
  }

  /// The folders a terminal `claude` may be in for Drakar to offer itself as its editor.
  private func setFolders(_ folders: [String]) {
    let unique = Array(Set(folders)).sorted()
    guard unique != self.folders else { return }
    self.folders = unique
    writeLocks()
  }

  func accept(_ pendingDiff: PendingDiff) {
    resolve(pendingDiff, with: IDEReply.diffAccepted(contents: pendingDiff.diff.newContents))
  }

  func reject(_ pendingDiff: PendingDiff) {
    resolve(pendingDiff, with: IDEReply.diffRejected(tabName: pendingDiff.diff.tabName))
  }

  /// Closing the review window rejects what it held, as closing a diff tab does in VS Code.
  func rejectAll() {
    for pendingDiff in pending { reject(pendingDiff) }
  }

  // MARK: - Lock files

  /// One lock per account, so a `claude` under any `CLAUDE_CONFIG_DIR` finds it. Written
  /// owner-only from the first byte (a temporary file created 0600, then renamed into a
  /// 0700 folder), because it holds the token.
  private func writeLocks() {
    removeLocks()
    guard let port, let token = server?.token, !folders.isEmpty else { return }
    let lock = IDELockFile(
      port: port, pid: ProcessInfo.processInfo.processIdentifier, workspaceFolders: folders,
      ideName: IDEReply.ideName, authToken: token)
    guard let data = try? lock.json.line() else { return }
    let manager = FileManager.default
    for account in ClaudeAccount.discover() {
      let directory = IDELockFile.directory(for: account)
      do {
        try manager.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        let file = lock.file(in: directory)
        let temporary = directory.appending(path: ".\(port).lock.tmp")
        guard
          manager.createFile(
            atPath: temporary.path(percentEncoded: false), contents: data,
            attributes: [.posixPermissions: 0o600])
        else { continue }
        _ = try manager.replaceItemAt(file, withItemAt: temporary)
        lockFiles.append(file)
      } catch {
        continue
      }
    }
  }

  private func removeLocks() {
    for file in lockFiles { try? FileManager.default.removeItem(at: file) }
    lockFiles = []
  }

  // MARK: - Requests

  private func handle(_ message: IDEMessage, from connection: IDEConnection) {
    switch message {
    case .notification(let method, let params):
      if method == "ide_connected", let pid = params["pid"]?.intValue {
        connection.claudePID = Int32(exactly: pid)
      }
    case .request(let id, let call):
      switch call {
      case .initialize(let version):
        connection.send(IDEReply.result(id: id, IDEReply.initialize(protocolVersion: version)))
      case .listTools:
        connection.send(IDEReply.result(id: id, IDEReply.tools))
      case .ping:
        connection.send(IDEReply.result(id: id, .object([:])))
      case .tool(let tool):
        if let reply = answer(tool, id: id, from: connection) {
          connection.send(IDEReply.result(id: id, reply))
        }
      case .other(let method):
        connection.send(
          IDEReply.error(id: id, code: -32601, message: "Method not found: \(method)"))
      }
    }
  }

  /// The reply now, or nil for an `openDiff`, which is answered when the user decides.
  private func answer(_ tool: IDEToolCall, id: JSONValue, from connection: IDEConnection)
    -> JSONValue?
  {
    switch tool {
    case .openDiff(let diff):
      let existing = Self.contents(of: diff.oldFilePath)
      pending.append(
        PendingDiff(
          connection: connection, requestID: id, diff: diff,
          change: diff.change(existing: existing),
          claudePID: connection.claudePID))
      review.show()
      return nil
    case .closeTab(let tabName):
      // The user answered in the terminal: the diff resolves as rejected, as a closed tab
      // does in VS Code, and the CLI goes by the terminal's answer.
      for pendingDiff in pending
      where pendingDiff.connection === connection
        && pendingDiff.diff.tabName == tabName
      {
        reject(pendingDiff)
      }
      return IDEReply.tabClosed
    case .closeAllDiffTabs:
      let mine = pending.filter { $0.connection === connection }
      for pendingDiff in mine { reject(pendingDiff) }
      return IDEReply.closedDiffTabs(mine.count)
    case .getDiagnostics:
      return IDEReply.text("[]")
    case .getWorkspaceFolders:
      return IDEReply.workspaceFolders(folders)
    case .getOpenEditors:
      return IDEReply.json(.object(["tabs": .array([])]))
    case .getCurrentSelection, .getLatestSelection:
      return IDEReply.noSelection
    case .checkDocumentDirty(let path), .saveDocument(let path), .openFile(let path):
      return IDEReply.notOpen(path)
    case .unknown(let name):
      return IDEReply.json(
        .object(["success": .bool(false), "message": .string("Unknown tool: \(name)")]))
    }
  }

  private func resolve(_ pendingDiff: PendingDiff, with reply: JSONValue) {
    guard let index = pending.firstIndex(where: { $0.id == pendingDiff.id }) else { return }
    pending.remove(at: index)
    pendingDiff.connection.send(IDEReply.result(id: pendingDiff.requestID, reply))
    if pending.isEmpty { review.hide() }
  }

  private func closed(_ connection: IDEConnection) {
    pending.removeAll { $0.connection === connection }
    if pending.isEmpty { review.hide() }
  }

  /// The file as it is now, for the diff; nil when it does not exist yet. Past 1 MB the
  /// diff would be unreadable, so it is shown as a whole new file.
  private static func contents(of path: String) -> String? {
    let url = URL(filePath: path)
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000
    else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }
}

/// The window diffs from terminal sessions appear in. AppKit rather than a SwiftUI scene
/// because it has to open from the bridge, which no view owns, and come forward while
/// the user is in their terminal.
@MainActor
final class ReviewWindowController: NSObject, NSWindowDelegate {
  private unowned let bridge: IDEBridge
  private var window: NSWindow?

  init(bridge: IDEBridge) {
    self.bridge = bridge
  }

  func show() {
    let window = window ?? makeWindow()
    self.window = window
    // Forward without taking the user's keyboard from the terminal they are typing in;
    // the Dock icon bounces once to say something is waiting.
    window.orderFrontRegardless()
    NSApp.requestUserAttention(.informationalRequest)
  }

  func hide() {
    window?.orderOut(nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    bridge.rejectAll()
    return true
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
    window.title = String(localized: "Review Changes")
    window.identifier = NSUserInterfaceItemIdentifier("review")
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.contentViewController = NSHostingController(rootView: ReviewView(bridge: bridge))
    window.setFrameAutosaveName("drakar.reviewWindow")
    window.center()
    return window
  }
}
