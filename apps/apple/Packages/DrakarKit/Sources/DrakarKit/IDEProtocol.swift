import Foundation

/// The lock file that tells a terminal `claude` an editor is listening
/// (`docs/claude-ide-bridge.md`).
public struct IDELockFile: Sendable, Equatable {
  public var port: UInt16
  public var pid: Int32
  public var workspaceFolders: [String]
  public var ideName: String
  public var authToken: String

  public init(
    port: UInt16, pid: Int32, workspaceFolders: [String], ideName: String, authToken: String
  ) {
    self.port = port
    self.pid = pid
    self.workspaceFolders = workspaceFolders
    self.ideName = ideName
    self.authToken = authToken
  }

  public var json: JSONValue {
    .object([
      "pid": .number(Double(pid)),
      "workspaceFolders": .array(workspaceFolders.map(JSONValue.string)),
      "ideName": .string(ideName),
      "transport": .string("ws"),
      "runningInWindows": .bool(false),
      "authToken": .string(authToken),
    ])
  }

  /// `<config>/ide`: where the CLI of that account looks.
  public static func directory(for account: ClaudeAccount) -> URL {
    account.directory.appending(path: "ide", directoryHint: .isDirectory)
  }

  public func file(in directory: URL) -> URL {
    directory.appending(path: "\(port).lock")
  }

  /// Lock files `ideName` left behind in `directory` by a process that is gone. They
  /// matter: `claude --ide` connects only when exactly one editor matches its folder, so
  /// one stale lock beside the live one is enough to make it connect to neither.
  public static func stale(in directory: URL, ideName: String, isAlive: (Int32) -> Bool)
    -> [URL]
  {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    return files.filter { file in
      guard file.pathExtension == "lock", let data = try? Data(contentsOf: file),
        let json = try? JSONValue.parse(data), json["ideName"]?.stringValue == ideName,
        let pid = json["pid"]?.intValue.flatMap(Int32.init(exactly:))
      else { return false }
      return !isAlive(pid)
    }
  }
}

/// One MCP message from a connected `claude`.
public enum IDEMessage: Sendable, Equatable {
  case request(id: JSONValue, call: IDERequest)
  case notification(method: String, params: JSONValue)

  public init?(_ data: Data) {
    guard let json = try? JSONValue.parse(data), let method = json["method"]?.stringValue else {
      return nil  // a response to something we sent, or not JSON-RPC at all
    }
    let params = json["params"] ?? .object([:])
    guard let id = json["id"] else {
      self = .notification(method: method, params: params)
      return
    }
    self = .request(id: id, call: IDERequest(method: method, params: params))
  }
}

public enum IDERequest: Sendable, Equatable {
  case initialize(protocolVersion: String?)
  case listTools
  case tool(IDEToolCall)
  case ping
  case other(method: String)

  init(method: String, params: JSONValue) {
    switch method {
    case "initialize": self = .initialize(protocolVersion: params["protocolVersion"]?.stringValue)
    case "tools/list": self = .listTools
    case "tools/call": self = .tool(IDEToolCall(params))
    case "ping": self = .ping
    default: self = .other(method: method)
    }
  }
}

/// What `claude` asks the editor to do.
public enum IDEToolCall: Sendable, Equatable {
  case openDiff(OpenDiff)
  case closeTab(String)
  case closeAllDiffTabs
  case getDiagnostics(uri: String?)
  case getWorkspaceFolders
  case getOpenEditors
  case getCurrentSelection
  case getLatestSelection
  case checkDocumentDirty(filePath: String)
  case saveDocument(filePath: String)
  case openFile(OpenFile)
  case unknown(name: String)

  init(_ params: JSONValue) {
    let name = params["name"]?.stringValue ?? ""
    let arguments = params["arguments"] ?? .object([:])
    func string(_ key: String) -> String { arguments[key]?.stringValue ?? "" }
    switch name {
    case "openDiff":
      self = .openDiff(
        OpenDiff(
          oldFilePath: string("old_file_path"), newFilePath: string("new_file_path"),
          newContents: string("new_file_contents"), tabName: string("tab_name")))
    case "close_tab": self = .closeTab(string("tab_name"))
    case "closeAllDiffTabs": self = .closeAllDiffTabs
    case "getDiagnostics": self = .getDiagnostics(uri: arguments["uri"]?.stringValue)
    case "getWorkspaceFolders": self = .getWorkspaceFolders
    case "getOpenEditors": self = .getOpenEditors
    case "getCurrentSelection": self = .getCurrentSelection
    case "getLatestSelection": self = .getLatestSelection
    case "checkDocumentDirty": self = .checkDocumentDirty(filePath: string("filePath"))
    case "saveDocument": self = .saveDocument(filePath: string("filePath"))
    case "openFile":
      self = .openFile(
        OpenFile(
          filePath: string("filePath"), startText: arguments["startText"]?.stringValue,
          endText: arguments["endText"]?.stringValue,
          selectToEndOfLine: arguments["selectToEndOfLine"]?.boolValue ?? false,
          makeFrontmost: arguments["makeFrontmost"]?.boolValue ?? true))
    default: self = .unknown(name: name)
    }
  }
}

/// A proposed edit, waiting on the user. The CLI writes the file itself once told
/// `FILE_SAVED`; the editor only shows and answers.
public struct OpenDiff: Sendable, Equatable {
  public var oldFilePath: String
  public var newFilePath: String
  public var newContents: String
  public var tabName: String

  public init(oldFilePath: String, newFilePath: String, newContents: String, tabName: String) {
    self.oldFilePath = oldFilePath
    self.newFilePath = newFilePath
    self.newContents = newContents
    self.tabName = tabName
  }

  /// The change against the file as it is now; nil `existing` means it does not exist.
  public func change(existing: String?) -> FileChange {
    FileChange(path: newFilePath, old: existing, new: newContents)
  }
}

/// The answers, in the shapes the VS Code extension sends.
public enum IDEReply {
  public static let ideName = "Drakar"
  public static let serverVersion = "0.1.0"

  public static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
    .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
  }

  public static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
    .object([
      "jsonrpc": .string("2.0"), "id": id,
      "error": .object(["code": .number(Double(code)), "message": .string(message)]),
    ])
  }

  /// Echoes the client's protocol version: the CLI asked for 2025-11-25 and the
  /// extension's SDK answers with what it was asked when it supports it.
  public static func initialize(protocolVersion: String?) -> JSONValue {
    .object([
      "protocolVersion": .string(protocolVersion ?? "2025-06-18"),
      "capabilities": .object(["tools": .object(["listChanged": .bool(true)])]),
      "serverInfo": .object(["name": .string(ideName), "version": .string(serverVersion)]),
    ])
  }

  /// The tools Drakar honours. The CLI exposes them to the model as `mcp__ide__<name>`, so
  /// none is listed that would only ever fail: not the extension's Jupyter `executeCode`.
  public static var tools: JSONValue {
    func tool(_ name: String, _ description: String, _ properties: [String: String] = [:])
      -> JSONValue
    {
      .object([
        "name": .string(name), "description": .string(description),
        "inputSchema": .object([
          "type": .string("object"),
          "properties": .object(
            properties.mapValues { .object(["type": .string($0)]) }),
        ]),
      ])
    }
    return .object([
      "tools": .array([
        tool(
          "openDiff", "Open a diff for the user to accept or reject",
          [
            "old_file_path": "string", "new_file_path": "string", "new_file_contents": "string",
            "tab_name": "string",
          ]),
        tool("close_tab", "Close a diff", ["tab_name": "string"]),
        tool("closeAllDiffTabs", "Close all diffs"),
        tool("getDiagnostics", "Get language diagnostics", ["uri": "string"]),
        tool(
          "openFile", "Open a file in the editor and optionally select a range of text",
          [
            "filePath": "string", "preview": "boolean", "startText": "string",
            "endText": "string", "selectToEndOfLine": "boolean", "makeFrontmost": "boolean",
          ]),
        tool("getWorkspaceFolders", "Get the folders open in the editor"),
        tool("getOpenEditors", "Get the files open in the editor"),
        tool("getCurrentSelection", "Get the current text selection"),
        tool("getLatestSelection", "Get the most recent text selection"),
        tool(
          "checkDocumentDirty", "Check if a document has unsaved changes", ["filePath": "string"]),
        tool("saveDocument", "Save a document with unsaved changes", ["filePath": "string"]),
      ])
    ])
  }

  /// MCP tool content: one text block per string.
  public static func text(_ parts: String...) -> JSONValue {
    .object([
      "content": .array(parts.map { .object(["type": .string("text"), "text": .string($0)]) })
    ])
  }

  public static func diffAccepted(contents: String) -> JSONValue { text("FILE_SAVED", contents) }
  public static func diffRejected(tabName: String) -> JSONValue { text("DIFF_REJECTED", tabName) }
  public static var tabClosed: JSONValue { text("TAB_CLOSED") }
  public static func closedDiffTabs(_ count: Int) -> JSONValue { text("CLOSED_\(count)_DIFF_TABS") }

  public static func json(_ value: JSONValue) -> JSONValue {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(value)) ?? Data()
    return text(String(decoding: data, as: UTF8.self))
  }

  public static func workspaceFolders(_ folders: [String]) -> JSONValue {
    json(
      .object([
        "success": .bool(true),
        "folders": .array(
          folders.enumerated().map { index, path in
            .object([
              "name": .string(URL(filePath: path).lastPathComponent),
              "uri": .string(URL(filePath: path, directoryHint: .isDirectory).absoluteString),
              "path": .string(path), "index": .number(Double(index)),
            ])
          }),
        "rootPath": folders.first.map(JSONValue.string) ?? .null,
        "workspaceFile": .null,
      ]))
  }

  public static var noSelection: JSONValue {
    json(.object(["success": .bool(false), "message": .string("No active editor found")]))
  }

  /// `getCurrentSelection`: the active editor's, which is the caret when nothing is
  /// selected (the extension's default, `attachOpenFile`, sends the file either way).
  public static func currentSelection(_ selection: EditorSelection?) -> JSONValue {
    guard let selection, case .object(var object) = selection.json else { return noSelection }
    object["success"] = .bool(true)
    return json(.object(object))
  }

  /// `getLatestSelection`: the last one sent, wherever it was.
  public static func latestSelection(_ selection: EditorSelection?) -> JSONValue {
    json(
      selection?.json
        ?? .object(["success": .bool(false), "message": .string("No selection available")]))
  }

  /// `openFile` with `makeFrontmost: false` and nothing to select: the extension answers
  /// with what it opened rather than a sentence.
  public static func openedInBackground(_ tab: EditorTab) -> JSONValue {
    json(
      .object([
        "success": .bool(true), "filePath": .string(tab.filePath),
        "fileUrl": .string(URL(filePath: tab.filePath).absoluteString),
        "message": .string("Opened file: \(tab.filePath)"),
        "lineCount": .number(Double(tab.lineCount)), "isDirty": .bool(tab.isDirty),
        "isUntitled": .bool(false), "isClosed": .bool(false),
      ]))
  }

  public static func openEditors(_ tabs: [EditorTab]) -> JSONValue {
    json(.object(["tabs": .array(tabs.map(\.json))]))
  }

  public static func documentDirty(_ filePath: String, isDirty: Bool) -> JSONValue {
    json(
      .object([
        "success": .bool(true), "filePath": .string(filePath), "isDirty": .bool(isDirty),
        "isUntitled": .bool(false),
      ]))
  }

  public static func documentSaved(_ filePath: String, saved: Bool) -> JSONValue {
    json(
      .object([
        "success": .bool(true), "filePath": .string(filePath), "saved": .bool(saved),
        "message": .string(
          saved ? "Document saved successfully" : "Document was not dirty or save failed"),
      ]))
  }

  /// A tool that failed, as the MCP SDK reports a handler that threw: the message, flagged.
  public static func toolError(_ message: String) -> JSONValue {
    .object([
      "content": .array([.object(["type": .string("text"), "text": .string(message)])]),
      "isError": .bool(true),
    ])
  }

  /// Sent unasked to every connected `claude`, which shows the file or the line count in
  /// its prompt and attaches the selection to the next message.
  public static func selectionChanged(_ selection: EditorSelection) -> JSONValue {
    .object([
      "jsonrpc": .string("2.0"), "method": .string("selection_changed"), "params": selection.json,
    ])
  }

  public static func notOpen(_ filePath: String) -> JSONValue {
    json(
      .object([
        "success": .bool(false), "message": .string("Document not open: \(filePath)"),
      ]))
  }
}

extension FileChange {
  /// A whole-file change, from what is on disk to what is proposed: what `openDiff` asks.
  public init(path: String, old: String?, new: String) {
    self.path = path
    diffs = [LineDiff.hunks(old: old ?? "", new: new, context: 3)]
    isNewFile = old == nil
  }
}
