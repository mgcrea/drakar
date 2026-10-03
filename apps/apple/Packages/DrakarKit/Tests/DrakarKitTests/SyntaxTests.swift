import DrakarKit
import Foundation
import Testing

@Suite("Syntax colouring")
struct SyntaxTests {

  /// What each token covers, as text, for readable expectations.
  private func tokens(_ text: String, _ file: String) throws -> [(Syntax.Kind, String)] {
    let language = try #require(Syntax.language(forFile: file))
    let units = Array(text.utf16)
    return Syntax.tokens(in: text, language: language).map {
      ($0.kind, String(decoding: units[$0.range], as: UTF16.self))
    }
  }

  private func kinds(_ text: String, _ file: String, _ kind: Syntax.Kind) throws -> [String] {
    try tokens(text, file).filter { $0.0 == kind }.map(\.1)
  }

  @Test func readsSwift() throws {
    let source = """
      @MainActor
      func greet(_ name: String) -> String { // say hi
        let count = 42 /* not a "string" */
        return "Hello, \\(name) \\"friend\\"!"
      }
      """
    #expect(try kinds(source, "a.swift", .keyword) == ["func", "let", "return"])
    #expect(try kinds(source, "a.swift", .type) == ["String", "String"])
    #expect(try kinds(source, "a.swift", .attribute) == ["@MainActor"])
    #expect(try kinds(source, "a.swift", .number) == ["42"])
    #expect(try kinds(source, "a.swift", .comment) == ["// say hi", "/* not a \"string\" */"])
    #expect(try kinds(source, "a.swift", .string) == ["\"Hello, \\(name) \\\"friend\\\"!\""])
  }

  @Test func keepsTripleQuotedStringsWhole() throws {
    let source = "x = \"\"\"\nline \"one\"\n\"\"\"\ny = 1"
    #expect(try kinds(source, "a.py", .string) == ["\"\"\"\nline \"one\"\n\"\"\""])
    #expect(try kinds(source, "a.py", .number) == ["1"])
  }

  @Test func tellsAShellCommentFromAHash() throws {
    let source = "echo $# a#b # real\nexit 0"
    #expect(try kinds(source, "run.sh", .comment) == ["# real"])
    #expect(try kinds(source, "Makefile", .comment) == ["# real"])
  }

  /// A Rust lifetime is not a character literal running to the end of the line.
  @Test func readsALifetimeAsNoString() throws {
    let source = "fn f<'a>(x: &'a str) -> char { 'x' }"
    #expect(try kinds(source, "a.rs", .string) == ["'x'"])
    #expect(try kinds(source, "a.rs", .keyword) == ["fn"])
  }

  @Test func endsAnUnterminatedStringWithItsLine() throws {
    let source = "let s = \"open\nlet t = 1"
    #expect(try kinds(source, "a.swift", .string) == ["\"open"])
    #expect(try kinds(source, "a.swift", .keyword) == ["let", "let"])
  }

  @Test func colorsJSONAndLeavesTheUnknownPlain() throws {
    #expect(try kinds(#"{"a": [1.5, true, null]}"#, "x.json", .keyword) == ["true", "null"])
    #expect(try kinds(#"{"a": [1.5, true, null]}"#, "x.json", .number) == ["1.5"])
    #expect(Syntax.language(forFile: "notes.txt") == nil)
    #expect(Syntax.language(forFile: "Makefile")?.name == "Make")
    #expect(Syntax.language(forFile: "App.TSX")?.name == "JavaScript")
  }

  @Test func countsInUTF16() throws {
    let source = "let é = \"ü\" // 🐉"
    let language = try #require(Syntax.language(forFile: "a.swift"))
    let found = Syntax.tokens(in: source, language: language)
    let comment = try #require(found.first { $0.kind == .comment })
    #expect(comment.range.upperBound == (source as NSString).length)
  }

  @Test func findsTheLineOfAnOffset() {
    let index = LineIndex("ab\ncd\n\nef")
    #expect(index.starts == [0, 3, 6, 7])
    #expect(index.count == 4)
    #expect(index.line(containing: 0) == 0)
    #expect(index.line(containing: 2) == 0)
    #expect(index.line(containing: 3) == 1)
    #expect(index.line(containing: 6) == 2)
    #expect(index.line(containing: 9) == 3)
  }
}
