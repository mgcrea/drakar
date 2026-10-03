import Foundation

/// A place in a file as VS Code counts it, which is what `claude` expects: lines and
/// characters from 0, characters in UTF-16 code units (the unit of `NSString` ranges).
public struct TextPosition: Sendable, Equatable {
  public var line: Int
  public var character: Int

  public init(line: Int, character: Int) {
    self.line = line
    self.character = character
  }

  var json: JSONValue {
    .object(["line": .number(Double(line)), "character": .number(Double(character))])
  }
}

/// What is selected in the editor, or where the caret is when nothing is: what the
/// extension sends a terminal `claude` as `selection_changed`, and what its own chat puts
/// ahead of a prompt as `<ide_selection>` or `<ide_opened_file>`.
public struct EditorSelection: Sendable, Equatable {
  public var filePath: String
  public var text: String
  public var start: TextPosition
  public var end: TextPosition

  public var isEmpty: Bool { start == end }

  public init(filePath: String, text: String, start: TextPosition, end: TextPosition) {
    self.filePath = filePath
    self.text = text
    self.start = start
    self.end = end
  }

  /// The selection `range` (UTF-16 offsets) of `contents`. A `\r\n` ends one line, as a
  /// lone `\r` does.
  public init(filePath: String, contents: String, range: Range<Int>) {
    let units = Array(contents.utf16)
    let lower = min(max(range.lowerBound, 0), units.count)
    let upper = min(max(range.upperBound, lower), units.count)
    func position(_ offset: Int) -> TextPosition {
      var line = 0
      var lineStart = 0
      var index = 0
      while index < offset {
        let unit = units[index]
        if unit == 0x0A || (unit == 0x0D && (index + 1 >= units.count || units[index + 1] != 0x0A))
        {
          line += 1
          lineStart = index + 1
        }
        index += 1
      }
      return TextPosition(line: line, character: offset - lineStart)
    }
    self.init(
      filePath: filePath,
      text: String(decoding: units[lower..<upper], as: UTF16.self),
      start: position(lower), end: position(upper))
  }

  public var fileURL: String { URL(filePath: filePath).absoluteString }

  /// `selection_changed`'s params, and `getLatestSelection`'s answer.
  public var json: JSONValue {
    .object([
      "text": .string(text),
      "filePath": .string(filePath),
      "fileUrl": .string(fileURL),
      "selection": .object([
        "start": start.json, "end": end.json, "isEmpty": .bool(isEmpty),
      ]),
    ])
  }

  /// The block the extension's chat puts ahead of a prompt, word for word (webview
  /// 2.1.288): the selected lines counted from 1, or only the file when nothing is
  /// selected.
  public var promptContext: String {
    if isEmpty {
      return
        "<ide_opened_file>The user opened the file \(filePath) in the IDE. This may or may not be related to the current task.</ide_opened_file>"
    }
    return
      "<ide_selection>The user selected the lines \(start.line + 1) to \(end.line + 1) from \(filePath):\n\(text)\n\nThis may or may not be related to the current task.</ide_selection>"
  }

  /// How the context shows beside the prompt: `notes.md`, `notes.md:3` or `notes.md:3–5`.
  public var label: String {
    Self.label(path: filePath, lines: isEmpty ? nil : (start.line + 1, end.line + 1))
  }

  static func label(path: String, lines: (Int, Int)?) -> String {
    let name = (path as NSString).lastPathComponent
    guard let (first, last) = lines else { return name }
    return first == last ? "\(name):\(first)" : "\(name):\(first)–\(last)"
  }

  /// The label for a context block read back from a transcript, or nil if `text` is not
  /// one of the two the extension writes.
  public static func label(context text: String) -> String? {
    if let inner = UserText.element("ide_opened_file", in: text),
      let path = inner.between("The user opened the file ", and: " in the IDE")
    {
      return label(path: path, lines: nil)
    }
    if let inner = UserText.element("ide_selection", in: text),
      let lines = inner.between("The user selected the lines ", and: " from "),
      let path = inner.between(" from ", and: ":\n")
    {
      let bounds = lines.components(separatedBy: " to ").compactMap { Int($0) }
      guard bounds.count == 2 else { return label(path: path, lines: nil) }
      return label(path: path, lines: (bounds[0], bounds[1]))
    }
    return nil
  }
}

/// `openFile`: a file to show, and optionally text to select in it.
public struct OpenFile: Sendable, Equatable {
  public var filePath: String
  public var startText: String?
  public var endText: String?
  public var selectToEndOfLine: Bool
  /// False opens the file without bringing it to the front.
  public var makeFrontmost: Bool

  public init(
    filePath: String, startText: String? = nil, endText: String? = nil,
    selectToEndOfLine: Bool = false, makeFrontmost: Bool = true
  ) {
    self.filePath = filePath
    self.startText = startText
    self.endText = endText
    self.selectToEndOfLine = selectToEndOfLine
    self.makeFrontmost = makeFrontmost
  }

  /// A relative path is relative to the first workspace folder, as in the extension.
  public func resolvedPath(workspaceFolders: [String]) -> String {
    guard !filePath.hasPrefix("/"), let first = workspaceFolders.first else { return filePath }
    return (first as NSString).appendingPathComponent(filePath)
  }

  /// The range (UTF-16 offsets) to select in `contents`, and the message the extension
  /// answers with. The first match of `startText`; with `endText`, through the end of its
  /// first match after that, or to the end of that line; nil range when nothing matched.
  public func selection(in contents: String) -> (range: Range<Int>?, message: String) {
    guard let startText, !startText.isEmpty else { return (nil, "Opened file: \(filePath)") }
    let text = contents as NSString
    let start = text.range(of: startText)
    guard start.location != NSNotFound else {
      return (nil, "Opened file, but text \"\(startText)\" not found")
    }
    guard let endText, !endText.isEmpty else {
      return (start.location..<NSMaxRange(start), "Opened file and selected text \"\(startText)\"")
    }
    let after = NSRange(location: NSMaxRange(start), length: text.length - NSMaxRange(start))
    let end = text.range(of: endText, range: after)
    guard end.location != NSNotFound else {
      return (
        start.location..<start.location,
        "Opened file and positioned at \"\(startText)\" (end text \"\(endText)\" not found)"
      )
    }
    var upper = NSMaxRange(end)
    if selectToEndOfLine {
      var lineEnd = 0
      text.getLineStart(
        nil, end: nil, contentsEnd: &lineEnd, for: NSRange(location: upper, length: 0))
      upper = max(upper, lineEnd)
    }
    return (
      start.location..<upper,
      "Opened file and selected text from \"\(startText)\" to \"\(endText)\""
    )
  }
}

/// A tab, for `getOpenEditors`.
public struct EditorTab: Sendable, Equatable {
  public var filePath: String
  public var isActive: Bool
  public var isDirty: Bool
  public var lineCount: Int
  /// The active tab's selection; the extension gives no other tab's.
  public var selection: EditorSelection?

  public init(
    filePath: String, isActive: Bool, isDirty: Bool, lineCount: Int,
    selection: EditorSelection? = nil
  ) {
    self.filePath = filePath
    self.isActive = isActive
    self.isDirty = isDirty
    self.lineCount = lineCount
    self.selection = selection
  }

  var json: JSONValue {
    var object: [String: JSONValue] = [
      "uri": .string(URL(filePath: filePath).absoluteString),
      "isActive": .bool(isActive), "isPinned": .bool(false), "isPreview": .bool(false),
      "isDirty": .bool(isDirty), "label": .string((filePath as NSString).lastPathComponent),
      "groupIndex": .number(0), "viewColumn": .number(1), "isGroupActive": .bool(true),
      "fileName": .string(filePath), "lineCount": .number(Double(lineCount)),
      "isUntitled": .bool(false),
    ]
    if let selection {
      object["selection"] = .object([
        "start": selection.start.json, "end": selection.end.json, "isReversed": .bool(false),
      ])
    }
    return .object(object)
  }
}

extension String {
  /// The text between the first `start` and the next `end`, or nil.
  fileprivate func between(_ start: String, and end: String) -> String? {
    guard let open = range(of: start), let close = range(of: end, range: open.upperBound..<endIndex)
    else { return nil }
    return String(self[open.upperBound..<close.lowerBound])
  }
}
