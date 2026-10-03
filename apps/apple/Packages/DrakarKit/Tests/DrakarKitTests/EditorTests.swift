import DrakarKit
import Foundation
import Testing

@Suite("The file tree")
struct FileTreeTests {

  /// A folder on disk, removed after the test.
  private func folder(_ files: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-tree-\(UUID().uuidString)", directoryHint: .isDirectory)
    for file in files {
      let url = root.appending(path: file)
      if file.hasSuffix("/") {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      } else {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
      }
    }
    return root
  }

  @Test func listsFoldersFirstAndHidesGit() throws {
    let root = try folder([
      "b.txt", "A.txt", "src/", "file10.txt", "file9.txt", ".git/HEAD", ".gitignore",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let tree = FileTree(root: root)
    #expect(
      tree.rows.map(\.node.name) == [
        "src", ".gitignore", "A.txt", "b.txt", "file9.txt", "file10.txt",
      ])
    #expect(tree.rows.allSatisfy { $0.depth == 0 })
  }

  @Test func readsAFolderOnlyWhenExpanded() throws {
    let root = try folder(["src/main.swift", "src/lib/util.swift", "README.md"])
    defer { try? FileManager.default.removeItem(at: root) }
    var tree = FileTree(root: root)
    #expect(tree.rows.count == 2)
    tree.toggle(tree.root + "/src")
    #expect(tree.rows.map(\.node.name) == ["src", "lib", "main.swift", "README.md"])
    #expect(tree.rows.map(\.depth) == [0, 1, 1, 0])
    tree.toggle(tree.root + "/src")
    #expect(tree.rows.count == 2)
  }

  @Test func revealsAFileDeepInside() throws {
    let root = try folder(["a/b/c.txt"])
    defer { try? FileManager.default.removeItem(at: root) }
    var tree = FileTree(root: root)
    let inside = tree.reveal(tree.root + "/a/b/c.txt")
    let outside = tree.reveal("/elsewhere/c.txt")
    #expect(inside)
    #expect(!outside)
    #expect(tree.rows.map(\.node.name) == ["a", "b", "c.txt"])
  }

  @Test func picksUpWhatChangedOnDisk() throws {
    let root = try folder(["src/main.swift"])
    defer { try? FileManager.default.removeItem(at: root) }
    var tree = FileTree(root: root)
    tree.expand(tree.root + "/src")
    let added = tree.root + "/src/new.swift"
    try Data().write(to: URL(filePath: added))
    #expect(tree.rows.count == 2)
    tree.refresh(changedPaths: [added])
    #expect(tree.rows.map(\.node.name) == ["src", "main.swift", "new.swift"])
    #expect(tree.isRelevant(added))
    #expect(!tree.isRelevant(tree.root + "/.git/index"))
    #expect(!tree.isRelevant("/elsewhere/x"))
  }

  /// FSEvents names `/tmp/x` as `/private/tmp/x`; `resolvingSymlinksInPath` does not.
  @Test func namesAPathAsTheKernelDoes() {
    #expect(FileTree.realPath("/tmp") == "/private/tmp")
    #expect(FileTree.realPath("/tmp/") == "/private/tmp")
    #expect(FileTree.realPath("/nonexistent/drakar") == "/nonexistent/drakar")
  }
}

@Suite("Opening and reloading a file")
struct TextFileTests {

  @Test func opensTextAndRefusesTheRest() {
    #expect(TextFile.decode(Data("café\n".utf8)) == .success("café\n"))
    #expect(TextFile.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])) == .failure(.binary))
    #expect(TextFile.decode(Data([0xC3, 0x28])) == .failure(.notUTF8))
    #expect(TextFile.read(URL(filePath: "/nonexistent/drakar")) == .failure(.notFound))
    #expect(TextFile.read(URL(filePath: "/tmp")) == .failure(.isDirectory))
  }

  /// The agent edits files under an open editor all the time; only a real conflict asks.
  @Test func reconcilesWithTheDisk() {
    let saved = "a\n"
    #expect(TextFile.reconcile(saved: saved, current: saved, disk: .success(saved)) == .none)
    #expect(
      TextFile.reconcile(saved: saved, current: saved, disk: .success("b\n")) == .reload("b\n"))
    #expect(
      TextFile.reconcile(saved: saved, current: "b\n", disk: .success("b\n")) == .reload("b\n"))
    #expect(
      TextFile.reconcile(saved: saved, current: "mine\n", disk: .success("theirs\n"))
        == .conflict("theirs\n"))
    #expect(TextFile.reconcile(saved: saved, current: saved, disk: .failure(.notFound)) == .deleted)
    #expect(TextFile.reconcile(saved: saved, current: saved, disk: .failure(.binary)) == .none)
  }
}

@Suite("The editor as claude sees it")
struct EditorSelectionTests {

  private let contents = "alpha\nbeta\r\ngamma é\ndelta"

  @Test func countsLinesAndCharactersFromZero() {
    let caret = EditorSelection(filePath: "/p/a.txt", contents: contents, range: 8..<8)
    #expect(caret.start == TextPosition(line: 1, character: 2))
    #expect(caret.isEmpty)
    #expect(caret.text == "")
    // "gamma é" starts after "\r\n", which is one line break; the é is one UTF-16 unit.
    let gamma = (contents as NSString).range(of: "gamma é")
    let selection = EditorSelection(
      filePath: "/p/a.txt", contents: contents, range: gamma.location..<(NSMaxRange(gamma) + 3))
    #expect(selection.start == TextPosition(line: 2, character: 0))
    #expect(selection.end == TextPosition(line: 3, character: 2))
    #expect(selection.text == "gamma é\nde")
  }

  /// `selection_changed` as the extension sends it (extension.js 2.1.288).
  @Test func notifiesInTheExtensionsShape() {
    let selection = EditorSelection(filePath: "/p/a.txt", contents: contents, range: 0..<5)
    let notification = IDEReply.selectionChanged(selection)
    #expect(notification["method"] == .string("selection_changed"))
    #expect(notification["id"] == nil)
    let params = notification["params"]
    #expect(params?["text"] == .string("alpha"))
    #expect(params?["fileUrl"] == .string("file:///p/a.txt"))
    #expect(params?["selection"]?["end"]?["character"] == .number(5))
    #expect(params?["selection"]?["isEmpty"] == .bool(false))
  }

  @Test func putsTheExtensionsBlockAheadOfAPrompt() throws {
    let selection = EditorSelection(filePath: "/p/a.txt", contents: contents, range: 0..<10)
    #expect(
      selection.promptContext
        == "<ide_selection>The user selected the lines 1 to 2 from /p/a.txt:\nalpha\nbeta\n\nThis may or may not be related to the current task.</ide_selection>"
    )
    #expect(selection.label == "a.txt:1–2")
    let caret = EditorSelection(filePath: "/p/a.txt", contents: contents, range: 3..<3)
    #expect(
      caret.promptContext.hasPrefix(
        "<ide_opened_file>The user opened the file /p/a.txt in the IDE."))
    #expect(caret.label == "a.txt")

    let line = try ClientMessage.prompt("Fix it", context: [caret.promptContext]).line()
    let json = try JSONValue.parse(line)
    let blocks = json["message"]?["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }
    #expect(blocks == [caret.promptContext, "Fix it"])
  }

  /// A prompt sent with a selection reads back with its label, from Drakar or from VS Code.
  @Test func readsTheContextBackFromHistory() throws {
    let selection = EditorSelection(filePath: "/p/a.txt", contents: contents, range: 0..<10)
    let message = ClientMessage.prompt("Explain", context: [selection.promptContext]).json
    let line = try JSONValue.object([
      "type": .string("user"), "message": message["message"] ?? .null,
    ]).line()
    let transcript = Transcript.history(lines: [line])
    #expect(transcript.entries.map(\.kind) == [.prompt("Explain")])
    #expect(transcript.entries.first?.context == "a.txt:1–2")
  }

  /// The extension's ⌥K reference and ⌘⌥K notification.
  @Test func mentionsASelection() {
    let lines = EditorSelection(filePath: "/p/src/a.txt", contents: contents, range: 0..<10)
    #expect(lines.mention(relativeTo: "/p") == "@src/a.txt#L1-2")
    let one = EditorSelection(filePath: "/p/src/a.txt", contents: contents, range: 0..<3)
    #expect(one.mention(relativeTo: "/p/") == "@src/a.txt#L1")
    let caret = EditorSelection(filePath: "/p/src/a.txt", contents: contents, range: 3..<3)
    #expect(caret.mention(relativeTo: "/p") == "@src/a.txt")
    #expect(caret.mention(relativeTo: "/elsewhere") == "@/p/src/a.txt")
    #expect(
      EditorSelection(filePath: "/p/a#b.txt", contents: contents, range: 0..<0)
        .mention(relativeTo: "/p") == nil)

    let notification = IDEReply.atMentioned(lines)
    #expect(notification["method"] == .string("at_mentioned"))
    #expect(notification["params"]?["lineStart"] == .number(0))
    #expect(notification["params"]?["lineEnd"] == .number(1))
    #expect(IDEReply.atMentioned(caret)["params"]?["lineStart"] == nil)
  }

  @Test func selectsWhatOpenFileAsksFor() {
    let text = "func a() {\n  return 1\n}\nfunc b() {}\n"
    func selected(_ open: OpenFile) -> String? {
      guard let range = open.selection(in: text).range else { return nil }
      return (text as NSString).substring(
        with: NSRange(location: range.lowerBound, length: range.count))
    }
    #expect(selected(OpenFile(filePath: "/p/x", startText: "return")) == "return")
    #expect(
      selected(OpenFile(filePath: "/p/x", startText: "func a", endText: "}"))
        == "func a() {\n  return 1\n}")
    #expect(
      selected(
        OpenFile(filePath: "/p/x", startText: "return", endText: "1", selectToEndOfLine: true))
        == "return 1")
    #expect(selected(OpenFile(filePath: "/p/x", startText: "return", endText: "nowhere")) == "")
    #expect(OpenFile(filePath: "/p/x", startText: "nowhere").selection(in: text).range == nil)
    #expect(OpenFile(filePath: "src/x").resolvedPath(workspaceFolders: ["/p"]) == "/p/src/x")
    #expect(OpenFile(filePath: "/abs/x").resolvedPath(workspaceFolders: ["/p"]) == "/abs/x")
  }

  @Test func readsOpenFilesArguments() throws {
    let line =
      #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"openFile","arguments":{"filePath":"/p/x","startText":"a","makeFrontmost":false}}}"#
    let message = try #require(IDEMessage(Data(line.utf8)))
    #expect(
      message
        == .request(
          id: .number(7),
          call: .tool(.openFile(OpenFile(filePath: "/p/x", startText: "a", makeFrontmost: false)))))
  }

  @Test func answersTheEditorTools() throws {
    func payload(_ reply: JSONValue) throws -> JSONValue {
      let text = try #require(reply["content"]?.arrayValue?.first?["text"]?.stringValue)
      return try JSONValue.parse(Data(text.utf8))
    }
    let selection = EditorSelection(filePath: "/p/a.txt", contents: contents, range: 0..<5)
    #expect(try payload(IDEReply.currentSelection(selection))["success"] == .bool(true))
    #expect(
      try payload(IDEReply.currentSelection(nil))["message"] == .string("No active editor found"))
    #expect(
      try payload(IDEReply.latestSelection(nil))["message"] == .string("No selection available"))
    #expect(try payload(IDEReply.latestSelection(selection))["text"] == .string("alpha"))

    let tabs = try payload(
      IDEReply.openEditors([
        EditorTab(
          filePath: "/p/a.txt", isActive: true, isDirty: true, lineCount: 4, selection: selection),
        EditorTab(filePath: "/p/b.txt", isActive: false, isDirty: false, lineCount: 1),
      ]))["tabs"]?.arrayValue
    #expect(tabs?.count == 2)
    #expect(tabs?.first?["label"] == .string("a.txt"))
    #expect(tabs?.first?["isDirty"] == .bool(true))
    #expect(tabs?.first?["selection"]?["end"]?["character"] == .number(5))
    #expect(tabs?.last?["selection"] == nil)

    #expect(
      try payload(IDEReply.documentDirty("/p/a.txt", isDirty: true))["isDirty"] == .bool(true))
    #expect(try payload(IDEReply.documentSaved("/p/a.txt", saved: true))["saved"] == .bool(true))
    #expect(IDEReply.toolError("File not found: /p/x")["isError"] == .bool(true))
    let names = IDEReply.tools["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    #expect(names.contains("openFile"))
  }
}
