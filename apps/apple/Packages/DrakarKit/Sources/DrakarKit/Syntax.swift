import Foundation

/// Colouring for the editor: a lexer per language family, not a parser. It knows comments,
/// strings, numbers, keywords, capitalised type names and `@`/`#` attributes, which is
/// what makes code readable at a glance, and nothing that needs a grammar. Ranges are in
/// UTF-16 offsets, the unit of the text view.
public enum Syntax {
  public enum Kind: Sendable, Equatable, CaseIterable {
    case keyword, string, comment, number, type, attribute
  }

  public struct Token: Sendable, Equatable {
    public var kind: Kind
    public var range: Range<Int>

    public init(_ kind: Kind, _ range: Range<Int>) {
      self.kind = kind
      self.range = range
    }
  }

  /// Past this the editor stays plain: lexing a large generated file on every keystroke
  /// is not worth its colours.
  public static let maximumLength = 2_000_000

  public struct Language: Sendable, Equatable {
    public var name: String
    var lineComments: [String] = []
    var blockComment: (open: String, close: String)?
    /// Longest first, so `"""` is tried before `"`.
    var strings: [String] = ["\""]
    /// `'` opens a character literal, closed within a few units, or it is not a string
    /// at all (a Rust lifetime, an apostrophe in a comment-less language).
    var quoteIsCharacter = false
    var keywords: Set<String> = []
    var capitalisedAreTypes = true
    var attributePrefixes: Set<Character> = []

    public static func == (a: Self, b: Self) -> Bool { a.name == b.name }
  }

  public static func language(forFile name: String) -> Language? {
    let lowered = name.lowercased()
    let ext = (lowered as NSString).pathExtension
    switch (lowered, ext) {
    case ("makefile", _), ("gnumakefile", _), (_, "mk"): return .make
    case ("dockerfile", _), (_, "sh"), (_, "bash"), (_, "zsh"), (_, "command"): return .shell
    case (_, "swift"): return .swift
    case (_, "js"), (_, "mjs"), (_, "cjs"), (_, "jsx"), (_, "ts"), (_, "tsx"), (_, "mts"):
      return .javaScript
    case (_, "py"), (_, "pyi"): return .python
    case (_, "rb"), (_, "rake"), ("gemfile", _): return .ruby
    case (_, "go"): return .go
    case (_, "rs"): return .rust
    case (_, "c"), (_, "h"), (_, "m"), (_, "mm"), (_, "cc"), (_, "cpp"), (_, "hpp"),
      (_, "java"), (_, "kt"), (_, "kts"), (_, "cs"), (_, "dart"), (_, "scala"):
      return .cFamily
    case (_, "json"), (_, "jsonl"), (_, "jsonc"): return .json
    case (_, "yaml"), (_, "yml"), (_, "toml"): return .config
    case (_, "css"), (_, "scss"): return .css
    case (_, "sql"): return .sql
    default: return nil
    }
  }

  // MARK: - Lexing

  public static func tokens(in text: String, language: Language) -> [Token] {
    let units = Array(text.utf16)
    guard units.count <= maximumLength else { return [] }
    let lineComments = language.lineComments.map { Array($0.utf16) }
    let block = language.blockComment.map { (Array($0.open.utf16), Array($0.close.utf16)) }
    let strings = language.strings.map { Array($0.utf16) }
    var tokens: [Token] = []
    var i = 0

    func starts(_ pattern: [UInt16], at index: Int) -> Bool {
      guard index + pattern.count <= units.count else { return false }
      for k in 0..<pattern.count where units[index + k] != pattern[k] { return false }
      return true
    }
    func endOfLine(_ index: Int) -> Int {
      var j = index
      while j < units.count, units[j] != 0x0A { j += 1 }
      return j
    }

    scan: while i < units.count {
      let unit = units[i]
      if unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D {
        i += 1
        continue
      }
      // A `#` comment starts a word: `$#` and `a#b` are not comments.
      for comment in lineComments where starts(comment, at: i) {
        if comment == [0x23], i > 0, !isSpace(units[i - 1]) { break }
        let end = endOfLine(i)
        tokens.append(Token(.comment, i..<end))
        i = end
        continue scan
      }
      if let (open, close) = block, starts(open, at: i) {
        var j = i + open.count
        while j < units.count, !starts(close, at: j) { j += 1 }
        let end = min(j + close.count, units.count)
        tokens.append(Token(.comment, i..<end))
        i = end
        continue
      }
      for delimiter in strings where starts(delimiter, at: i) {
        let isQuote = delimiter == [0x27]
        if let end = stringEnd(units, from: i, delimiter: delimiter) {
          if isQuote, language.quoteIsCharacter, end - i > 6 { break }
          tokens.append(Token(.string, i..<end))
          i = end
          continue scan
        }
        if isQuote, language.quoteIsCharacter { break }
        // Unterminated: to the end of the line.
        let end = endOfLine(i)
        tokens.append(Token(.string, i..<end))
        i = end
        continue scan
      }
      if isDigit(unit), i == 0 || !isIdentifier(units[i - 1]) {
        var j = i + 1
        while j < units.count,
          isIdentifier(units[j])
            || (units[j] == 0x2E && j + 1 < units.count && isDigit(units[j + 1]))
        {
          j += 1
        }
        tokens.append(Token(.number, i..<j))
        i = j
        continue
      }
      if unit < 0x80, language.attributePrefixes.contains(Character(Unicode.Scalar(UInt8(unit)))),
        i + 1 < units.count, isIdentifierStart(units[i + 1])
      {
        var j = i + 1
        while j < units.count, isIdentifier(units[j]) { j += 1 }
        tokens.append(Token(.attribute, i..<j))
        i = j
        continue
      }
      if isIdentifierStart(unit) {
        var j = i + 1
        while j < units.count, isIdentifier(units[j]) { j += 1 }
        let word = String(decoding: units[i..<j], as: UTF16.self)
        if language.keywords.contains(word) {
          tokens.append(Token(.keyword, i..<j))
        } else if language.capitalisedAreTypes, isUppercase(unit),
          word.contains(where: \.isLowercase)
        {
          tokens.append(Token(.type, i..<j))
        }
        i = j
        continue
      }
      i += 1
    }
    return tokens
  }

  /// Where the string opened at `start` ends, past its closing delimiter; nil when the
  /// line (or, for a triple quote, the file) ends first. A backslash escapes one unit.
  static func stringEnd(_ units: [UInt16], from start: Int, delimiter: [UInt16]) -> Int? {
    let multiline = delimiter.count == 3 || delimiter == [0x60]
    var j = start + delimiter.count
    while j < units.count {
      let unit = units[j]
      if unit == 0x5C {
        j += 2
        continue
      }
      if unit == 0x0A, !multiline { return nil }
      if units[j] == delimiter[0], j + delimiter.count <= units.count,
        Array(units[j..<(j + delimiter.count)]) == delimiter
      {
        return j + delimiter.count
      }
      j += 1
    }
    return nil
  }

  static func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A }
  static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }
  static func isUppercase(_ unit: UInt16) -> Bool { unit >= 0x41 && unit <= 0x5A }
  static func isIdentifierStart(_ unit: UInt16) -> Bool {
    (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
      || unit == 0x24
  }
  static func isIdentifier(_ unit: UInt16) -> Bool { isIdentifierStart(unit) || isDigit(unit) }
}

extension Syntax.Language {
  private static func words(_ list: String) -> Set<String> {
    Set(list.split(separator: " ").map(String.init))
  }

  static let swift = Self(
    name: "Swift", lineComments: ["//"], blockComment: ("/*", "*/"), strings: ["\"\"\"", "\""],
    keywords: words(
      "actor any as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate final for func get guard if import in indirect init inout internal is isolated lazy let mutating nil nonisolated nonmutating open operator optional override private protocol public repeat required rethrows return self Self set some static struct subscript super switch throw throws true try typealias unowned var weak where while willSet didSet consuming borrowing sending package macro"
    ), attributePrefixes: ["@", "#"])

  static let javaScript = Self(
    name: "JavaScript", lineComments: ["//"], blockComment: ("/*", "*/"),
    strings: ["\"", "'", "`"],
    keywords: words(
      "abstract as async await break case catch class const constructor continue debugger declare default delete do else enum export extends false finally for from function get if implements import in instanceof interface keyof let namespace new null of private protected public readonly return satisfies set static super switch this throw true try type typeof undefined var void while with yield"
    ), attributePrefixes: ["@"])

  static let python = Self(
    name: "Python", lineComments: ["#"], strings: ["\"\"\"", "'''", "\"", "'"],
    keywords: words(
      "and as assert async await break case class continue def del elif else except False finally for from global if import in is lambda match None nonlocal not or pass raise return self True try while with yield"
    ), attributePrefixes: ["@"])

  static let ruby = Self(
    name: "Ruby", lineComments: ["#"], strings: ["\"", "'"],
    keywords: words(
      "alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require attr_reader attr_accessor"
    ), attributePrefixes: ["@", ":"])

  static let go = Self(
    name: "Go", lineComments: ["//"], blockComment: ("/*", "*/"), strings: ["\"", "`", "'"],
    quoteIsCharacter: true,
    keywords: words(
      "break case chan const continue default defer else fallthrough false for func go goto if import interface iota map nil package range return select struct switch true type var"
    ))

  static let rust = Self(
    name: "Rust", lineComments: ["//"], blockComment: ("/*", "*/"), strings: ["\"", "'"],
    quoteIsCharacter: true,
    keywords: words(
      "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"
    ), attributePrefixes: ["#"])

  static let cFamily = Self(
    name: "C", lineComments: ["//"], blockComment: ("/*", "*/"), strings: ["\"", "'"],
    quoteIsCharacter: true,
    keywords: words(
      "abstract auto bool break case catch char class const continue default delete do double else enum extends extern false final float for fun if implements import int interface long namespace new null nullptr object override package private protected public return short signed sizeof static struct super switch template this throw throws true try typedef typename union unsigned using val var virtual void volatile when while"
    ), attributePrefixes: ["@", "#"])

  static let shell = Self(
    name: "Shell", lineComments: ["#"], strings: ["\"", "'"], capitalisedAreTypes: false
  )
  .with(
    keywords:
      "case do done elif else esac export fi for function if in local readonly return set shift source then until while"
  )

  static let make = Self(
    name: "Make", lineComments: ["#"], strings: ["\"", "'"], capitalisedAreTypes: false
  )
  .with(keywords: "define else endef endif export ifdef ifeq ifndef ifneq include override")

  static let json = Self(
    name: "JSON", strings: ["\""], keywords: words("true false null"), capitalisedAreTypes: false)

  static let config = Self(
    name: "Config", lineComments: ["#"], strings: ["\"", "'"],
    keywords: words("true false null yes no on off"), capitalisedAreTypes: false)

  static let css = Self(
    name: "CSS", blockComment: ("/*", "*/"), strings: ["\"", "'"], capitalisedAreTypes: false,
    attributePrefixes: ["@", "#", "."])

  static let sql = Self(
    name: "SQL", lineComments: ["--"], blockComment: ("/*", "*/"), strings: ["'", "\""],
    keywords: words(
      "select from where and or not insert into values update set delete create table index view drop alter join left right inner outer on group by order having limit offset as distinct union all null is in like between case when then else end primary key foreign references default SELECT FROM WHERE AND OR NOT INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE INDEX VIEW DROP ALTER JOIN LEFT RIGHT INNER OUTER ON GROUP BY ORDER HAVING LIMIT OFFSET AS DISTINCT UNION ALL NULL IS IN LIKE BETWEEN CASE WHEN THEN ELSE END PRIMARY KEY FOREIGN REFERENCES DEFAULT"
    ), capitalisedAreTypes: false)

  private func with(keywords list: String) -> Self {
    var copy = self
    copy.keywords = Self.words(list)
    return copy
  }
}

/// Where each line starts, for line numbers: built once per text, then any offset's line
/// is a binary search away.
public struct LineIndex: Sendable, Equatable {
  /// UTF-16 offset of each line's first unit; the first is 0.
  public private(set) var starts: [Int]

  public init(_ text: String) {
    var starts = [0]
    var offset = 0
    for unit in text.utf16 {
      offset += 1
      if unit == 0x0A { starts.append(offset) }
    }
    self.starts = starts
  }

  public var count: Int { starts.count }

  /// The 0-based line holding `offset`.
  public func line(containing offset: Int) -> Int {
    var low = 0
    var high = starts.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if starts[middle] <= offset { low = middle } else { high = middle - 1 }
    }
    return low
  }
}
