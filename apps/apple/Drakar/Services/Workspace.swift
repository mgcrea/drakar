import AppKit
import DrakarKit
import Observation
import SwiftUI

/// A window's folder as an editor: the file tree, the open tabs, and what is selected,
/// kept in step with the disk while the agent writes to it.
@Observable
final class Workspace {
  let folder: URL
  private(set) var tree: FileTree
  private(set) var documents: [EditorDocument] = []
  private(set) var activeID: EditorDocument.ID?
  /// The active tab's selection as `claude` counts it, settled a moment after the last
  /// change: what the composer attaches and the bridge sends.
  private(set) var selection: EditorSelection?
  /// Why the last file could not be opened or saved.
  var problem: String?
  var isQuickOpenShown = false
  var isSearchShown = false
  /// What the search starts with, for the debug launch argument.
  @ObservationIgnored private(set) var searchQuery = ""
  /// What quick open starts with, for the debug launch argument.
  @ObservationIgnored private(set) var quickOpenQuery = ""
  /// The folder's files for quick open, relative to it; nil while they are being read.
  private(set) var quickOpenFiles: [String]?

  /// The window, to bring forward for `openFile`.
  @ObservationIgnored weak var window: NSWindow?
  /// When this window was last the active one: the bridge's "current editor".
  @ObservationIgnored private(set) var lastActive = Date.distantPast
  @ObservationIgnored private var watcher: FolderWatcher?
  /// The folder as FSEvents names it (symbolic links resolved), and as the tree does.
  @ObservationIgnored private let resolvedRoot: String
  @ObservationIgnored private var selectionTask: Task<Void, Never>?

  init(folder: URL) {
    self.folder = folder
    let tree = FileTree(root: folder)
    self.tree = tree
    resolvedRoot = FileTree.realPath(tree.root)
    watcher = FolderWatcher(folder: folder) { [weak self] paths in self?.filesChanged(paths) }
    Self.open.append(Weak(self))
  }

  isolated deinit {
    watcher?.stop()
  }

  var active: EditorDocument? { documents.first { $0.id == activeID } }

  var unsavedDocuments: [EditorDocument] { documents.filter(\.isDirty) }

  /// Asks before the window closes with unsaved tabs; kept here, since a window holds its
  /// delegate weakly.
  @ObservationIgnored var closeGuard: WindowCloseGuard?

  // MARK: - Tabs

  /// Opens `url` in a tab, or brings its tab forward, and selects `range` (UTF-16
  /// offsets) in it if given.
  @discardableResult
  func open(_ url: URL, select range: Range<Int>? = nil) -> EditorDocument? {
    let path = FileTree.normalized(url.absoluteURL.standardized.path(percentEncoded: false))
    let document: EditorDocument
    if let existing = documents.first(where: { $0.path == path }) {
      document = existing
    } else {
      switch TextFile.read(URL(filePath: path)) {
      case .success(let text):
        document = EditorDocument(url: URL(filePath: path), text: text)
        let index = documents.firstIndex { $0.id == activeID }.map { $0 + 1 } ?? documents.count
        documents.insert(document, at: index)
      case .failure(let failure):
        problem = Self.describe(failure, name: url.lastPathComponent)
        return nil
      }
    }
    if let range { document.select(NSRange(location: range.lowerBound, length: range.count)) }
    tree.reveal(path)
    activate(document)
    return document
  }

  func activate(_ document: EditorDocument) {
    activeID = document.id
    selectionMoved()
  }

  /// The tab waiting on "Save changes?".
  var closing: EditorDocument?

  /// Closes a saved tab at once, and asks about an unsaved one.
  func requestClose(_ document: EditorDocument) {
    if document.isDirty { closing = document } else { close(document) }
  }

  func close(_ document: EditorDocument) {
    guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
    documents.remove(at: index)
    if activeID == document.id {
      activeID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id
      selectionMoved()
    }
  }

  func save(_ document: EditorDocument) {
    do {
      try document.save()
    } catch {
      problem = String(
        localized: "\(document.name) could not be saved: \(error.localizedDescription)")
    }
  }

  /// Shows quick open with the folder read afresh, off the main thread: a large project
  /// takes a moment to walk.
  func showQuickOpen(query: String = "") {
    quickOpenQuery = query
    isQuickOpenShown = true
    quickOpenFiles = nil
    let root = folder
    Task {
      let files = await Task.detached { QuickOpen.files(under: root) }.value
      quickOpenFiles = files
    }
  }

  func showSearch(query: String = "") {
    searchQuery = query
    isSearchShown = true
  }

  func saveAll() {
    for document in unsavedDocuments { save(document) }
  }

  func toggle(_ row: FileTree.Row) {
    if row.node.isDirectory {
      tree.toggle(row.node.path)
    } else {
      open(URL(filePath: row.node.path))
    }
  }

  // MARK: - Selection

  /// Called by the text view on every move; settles for 150 ms before anyone is told.
  func selectionMoved() {
    selectionTask?.cancel()
    selectionTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled, let self else { return }
      self.selection = self.active.map { $0.selection }
      self.publishSelection()
    }
  }

  /// This window came to the front: from now on it is the editor `claude` hears about.
  func becameActive() {
    lastActive = .now
    publishSelection()
  }

  private func publishSelection() {
    guard Workspace.current === self, let selection else { return }
    IDEBridge.shared.selectionChanged(selection)
  }

  // MARK: - The disk

  private func filesChanged(_ resolvedPaths: [String]) {
    // Back to the path the tree uses: FSEvents resolves `/tmp` to `/private/tmp`.
    let paths = resolvedPaths.map { path in
      path.hasPrefix(resolvedRoot) ? tree.root + path.dropFirst(resolvedRoot.count) : path
    }.map(FileTree.normalized).filter(tree.isRelevant)
    guard !paths.isEmpty else { return }
    tree.refresh(changedPaths: paths)
    for document in documents
    where paths.contains(where: { document.path == $0 || document.path.hasPrefix($0 + "/") }) {
      document.diskChanged()
    }
  }

  static func describe(_ failure: TextFile.Failure, name: String) -> String {
    switch failure {
    case .notFound: String(localized: "\(name) does not exist.")
    case .isDirectory: String(localized: "\(name) is a folder.")
    case .tooLarge(let bytes):
      String(
        localized:
          "\(name) is too large to open (\(bytes.formatted(.byteCount(style: .file)))).")
    case .binary: String(localized: "\(name) is not a text file.")
    case .notUTF8: String(localized: "\(name) is not UTF-8 text.")
    }
  }

  // MARK: - Every window

  private struct Weak {
    weak var workspace: Workspace?
    init(_ workspace: Workspace) { self.workspace = workspace }
  }

  private static var open: [Weak] = []

  /// The open windows' workspaces, most recently active first.
  static var all: [Workspace] {
    open.removeAll { $0.workspace == nil }
    return open.compactMap(\.workspace).sorted { $0.lastActive > $1.lastActive }
  }

  /// The window the user was last in.
  static var current: Workspace? { all.first }

  /// The workspace a file belongs in: the most recent whose folder holds it, or else the
  /// most recent of all.
  static func owning(_ path: String) -> Workspace? {
    all.first { path.hasPrefix($0.tree.root + "/") } ?? current
  }

  static func document(at path: String) -> EditorDocument? {
    let path = FileTree.normalized(URL(filePath: path).standardized.path(percentEncoded: false))
    return all.lazy.flatMap(\.documents).first { $0.path == path }
  }
}

/// A file open in a tab. The text lives in an `NSTextStorage` the text view edits in
/// place, so a keystroke in a large file copies nothing.
@Observable
final class EditorDocument: Identifiable {
  let id = UUID()
  let url: URL
  @ObservationIgnored let storage: NSTextStorage
  /// One per document: a window's shared undo manager would undo another tab's typing.
  @ObservationIgnored let undoManager = UndoManager()
  /// The contents last read from or written to disk.
  @ObservationIgnored private var saved: String
  private(set) var isDirty = false
  /// What the file says now, when it changed on disk under edits of the user's own.
  private(set) var conflict: String?
  private(set) var isDeleted = false
  /// The selection in UTF-16 offsets, kept while the tab is in the background.
  @ObservationIgnored private(set) var selectedRange = NSRange(location: 0, length: 0)

  static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
  static var attributes: [NSAttributedString.Key: Any] {
    [.font: font, .foregroundColor: NSColor.textColor]
  }

  init(url: URL, text: String) {
    self.url = url
    saved = text
    storage = NSTextStorage(string: text, attributes: Self.attributes)
  }

  var path: String { url.path(percentEncoded: false) }
  var name: String { url.lastPathComponent }
  var lineCount: Int { storage.string.reduce(into: 1) { if $1 == "\n" { $0 += 1 } } }

  var selection: EditorSelection {
    EditorSelection(
      filePath: path, contents: storage.string,
      range: selectedRange.location..<NSMaxRange(selectedRange))
  }

  /// The text view on screen for this document, if its tab is the active one.
  private var textView: NSTextView? { storage.layoutManagers.first?.firstTextView }

  func edited() {
    if !isDirty { isDirty = true }
  }

  func selectionDidChange(_ range: NSRange) {
    selectedRange = range
  }

  /// Selects `range` and scrolls to it, now if the tab is showing, else when it shows.
  func select(_ range: NSRange) {
    let range = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
    selectedRange = range
    if let textView {
      textView.setSelectedRange(range)
      textView.scrollRangeToVisible(range)
    }
  }

  /// Written in place, through a symbolic link to its target, so the file keeps its
  /// permissions (a script stays executable) and a link stays a link.
  func save() throws {
    let text = storage.string
    try Data(text.utf8).write(to: url.resolvingSymlinksInPath())
    saved = text
    isDirty = false
    conflict = nil
    isDeleted = false
  }

  func diskChanged() {
    switch TextFile.reconcile(saved: saved, current: storage.string, disk: TextFile.read(url)) {
    case .none: break
    case .reload(let text): take(text)
    case .conflict(let text):
      conflict = text
      isDeleted = false
    case .deleted: isDeleted = true
    }
  }

  /// The user chose the disk's version over their edits.
  func reloadFromDisk() {
    if let conflict { take(conflict) }
  }

  /// The user chose their edits: saving will overwrite the disk's version.
  func keepMine() {
    if let conflict { saved = conflict }
    conflict = nil
  }

  private func take(_ text: String) {
    if storage.string != text {
      let selection = selectedRange
      storage.replaceCharacters(
        in: NSRange(location: 0, length: storage.length),
        with: NSAttributedString(string: text, attributes: Self.attributes))
      // The history no longer matches the text: undoing into it would corrupt it.
      undoManager.removeAllActions()
      select(selection)
    }
    saved = text
    isDirty = false
    conflict = nil
    isDeleted = false
  }
}

extension FocusedValues {
  /// The focused window's workspace, for Save.
  @Entry var workspace: Workspace?
}

/// "Save changes?" for one window's unsaved tabs, or every window's at quit.
enum UnsavedChanges {
  enum Choice { case save, discard, cancel }

  static func alert(for documents: [EditorDocument]) -> NSAlert {
    let alert = NSAlert()
    alert.messageText =
      documents.count == 1
      ? String(localized: "Do you want to save the changes you made to \(documents[0].name)?")
      : String(localized: "Do you want to save the changes you made to \(documents.count) files?")
    alert.informativeText = String(localized: "Your changes will be lost if you don’t save them.")
    alert.addButton(
      withTitle: documents.count == 1 ? String(localized: "Save") : String(localized: "Save All"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    let discard = alert.addButton(withTitle: String(localized: "Don’t Save"))
    discard.hasDestructiveAction = true
    return alert
  }

  static func choice(_ response: NSApplication.ModalResponse) -> Choice {
    switch response {
    case .alertFirstButtonReturn: .save
    case .alertThirdButtonReturn: .discard
    default: .cancel
    }
  }
}

/// Stands in front of the delegate SwiftUI gives a window, to ask before it closes with
/// unsaved tabs, and forwards every other message to SwiftUI's.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
  /// Read by the runtime's forwarding, which is nonisolated in its signature but only
  /// ever asked on the main thread, where window delegates are messaged.
  nonisolated(unsafe) private weak var original: NSWindowDelegate?
  private weak var workspace: Workspace?

  static func install(on window: NSWindow, for workspace: Workspace) {
    guard !(window.delegate is WindowCloseGuard) else { return }
    let closeGuard = WindowCloseGuard(original: window.delegate, workspace: workspace)
    workspace.closeGuard = closeGuard
    window.delegate = closeGuard
  }

  private init(original: NSWindowDelegate?, workspace: Workspace) {
    self.original = original
    self.workspace = workspace
  }

  nonisolated override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || original?.responds(to: selector) == true
  }

  nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
    original
  }

  func windowShouldClose(_ window: NSWindow) -> Bool {
    let unsaved = workspace?.unsavedDocuments ?? []
    guard let workspace, !unsaved.isEmpty else {
      return original?.windowShouldClose?(window) ?? true
    }
    UnsavedChanges.alert(for: unsaved).beginSheetModal(for: window) { response in
      switch UnsavedChanges.choice(response) {
      case .save:
        workspace.saveAll()
        // A save that failed keeps the window, and says why.
        if workspace.unsavedDocuments.isEmpty { window.close() }
      case .discard: window.close()
      case .cancel: break
      }
    }
    return false
  }
}
