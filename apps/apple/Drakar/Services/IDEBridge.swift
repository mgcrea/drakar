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
/// accepts it in the review window. It also hears what is selected in Drakar's editor
/// (`selection_changed`) and attaches it to the next prompt, and may open files there.
/// Headless sessions never connect, so Drakar's own windows keep their permission sheet
/// and attach the selection themselves (`ComposerView`).
@Observable
final class IDEBridge {
  static let shared = IDEBridge()

  /// An edit a terminal session proposed, waiting on Accept or Reject.
  struct PendingDiff: Identifiable {
    let id = UUID()
    let connection: IDEConnection
    let requestID: JSONValue
    let diff: OpenDiff
    /// The file as it was when the edit was proposed; nil when it does not exist yet.
    let existing: String?
    /// The proposed contents, which the user may edit before accepting: what Accept
    /// sends is what `claude` writes.
    let proposal: EditorDocument
    let claudePID: Int32?

    var change: FileChange {
      FileChange(path: diff.newFilePath, old: existing, new: proposal.storage.string)
    }
  }

  private(set) var port: UInt16?
  private(set) var pending: [PendingDiff] = []
  private(set) var failure: String?
  /// The pids of the terminal `claude`s connected now, from their `ide_connected`.
  private(set) var connectedPIDs: Set<Int32> = []

  @ObservationIgnored private var server: IDEServer?
  /// The last selection sent, for `getLatestSelection` and for a `claude` that connects.
  @ObservationIgnored private var latestSelection: EditorSelection?
  @ObservationIgnored private var selectionTask: Task<Void, Never>?
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

  /// Answers `FILE_SAVED` with the proposal as it stands, edits included: the CLI writes
  /// the contents it is sent back, not the ones it proposed.
  func accept(_ pendingDiff: PendingDiff) {
    resolve(
      pendingDiff, with: IDEReply.diffAccepted(contents: pendingDiff.proposal.storage.string))
  }

  func reject(_ pendingDiff: PendingDiff) {
    resolve(pendingDiff, with: IDEReply.diffRejected(tabName: pendingDiff.diff.tabName))
  }

  /// Closing the review window rejects what it held, as closing a diff tab does in VS Code.
  func rejectAll() {
    for pendingDiff in pending { reject(pendingDiff) }
  }

  // MARK: - Selection

  /// Sends `at_mentioned` to every connected `claude`; how many there were.
  func mention(_ selection: EditorSelection) -> Int {
    let clients = server?.clients ?? []
    for client in clients { client.send(IDEReply.atMentioned(selection)) }
    return clients.count
  }

  /// The active window's selection moved. Sent to every connected `claude` 300 ms after
  /// the last change, as the extension debounces it, and only when it differs.
  func selectionChanged(_ selection: EditorSelection) {
    guard selection != latestSelection else { return }
    latestSelection = selection
    selectionTask?.cancel()
    selectionTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled, let self, let clients = self.server?.clients else { return }
      for client in clients { client.send(IDEReply.selectionChanged(selection)) }
    }
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
        if let pid = connection.claudePID { connectedPIDs.insert(pid) }
      }
      if method == "notifications/initialized" {
        connection.isInitialized = true
        // The extension tells a new client the selection half a second after it connects.
        Task { [weak self, weak connection] in
          try? await Task.sleep(for: .milliseconds(500))
          if let selection = self?.latestSelection {
            connection?.send(IDEReply.selectionChanged(selection))
          }
        }
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
      pending.append(
        PendingDiff(
          connection: connection, requestID: id, diff: diff,
          existing: Self.contents(of: diff.oldFilePath),
          proposal: EditorDocument(url: URL(filePath: diff.newFilePath), text: diff.newContents),
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
      let current = Workspace.current
      return IDEReply.openEditors(
        Workspace.all.flatMap { workspace in
          workspace.documents.map { document in
            let isActive = workspace === current && document.id == workspace.activeID
            return EditorTab(
              filePath: document.path, isActive: isActive, isDirty: document.isDirty,
              lineCount: document.lineCount, selection: isActive ? workspace.selection : nil)
          }
        })
    case .getCurrentSelection:
      return IDEReply.currentSelection(Workspace.current?.active.map(\.selection))
    case .getLatestSelection:
      return IDEReply.latestSelection(latestSelection)
    case .checkDocumentDirty(let path):
      guard let document = Workspace.document(at: path) else { return IDEReply.notOpen(path) }
      return IDEReply.documentDirty(document.path, isDirty: document.isDirty)
    case .saveDocument(let path):
      guard let document = Workspace.document(at: path) else { return IDEReply.notOpen(path) }
      let wasDirty = document.isDirty
      if wasDirty { try? document.save() }
      return IDEReply.documentSaved(document.path, saved: wasDirty && !document.isDirty)
    case .openFile(let request):
      return open(request)
    case .unknown(let name):
      return IDEReply.json(
        .object(["success": .bool(false), "message": .string("Unknown tool: \(name)")]))
    }
  }

  /// Opens the file in the window whose folder holds it, selects what was asked, and
  /// brings that window forward without taking the keyboard from the terminal.
  private func open(_ request: OpenFile) -> JSONValue {
    let path = request.resolvedPath(workspaceFolders: folders)
    guard let workspace = Workspace.owning(path) else {
      return IDEReply.toolError("No Drakar window is open to show \(path)")
    }
    guard FileManager.default.fileExists(atPath: path) else {
      return IDEReply.toolError("File not found: \(path)")
    }
    guard let document = workspace.open(URL(filePath: path)) else {
      let problem = workspace.problem ?? "Could not open \(path)"
      workspace.problem = nil
      return IDEReply.toolError(problem)
    }
    var request = request
    request.filePath = document.path
    let (range, message) = request.selection(in: document.storage.string)
    if let range { document.select(NSRange(location: range.lowerBound, length: range.count)) }
    guard request.makeFrontmost else {
      guard request.startText == nil else { return IDEReply.text(message) }
      return IDEReply.openedInBackground(
        EditorTab(
          filePath: document.path, isActive: false, isDirty: document.isDirty,
          lineCount: document.lineCount))
    }
    workspace.window?.orderFrontRegardless()
    return IDEReply.text(message)
  }

  private func resolve(_ pendingDiff: PendingDiff, with reply: JSONValue) {
    guard let index = pending.firstIndex(where: { $0.id == pendingDiff.id }) else { return }
    pending.remove(at: index)
    pendingDiff.connection.send(IDEReply.result(id: pendingDiff.requestID, reply))
    if pending.isEmpty { review.hide() }
  }

  private func closed(_ connection: IDEConnection) {
    if let pid = connection.claudePID { connectedPIDs.remove(pid) }
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
