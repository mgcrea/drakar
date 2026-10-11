import DrakarKit
import Foundation
import Testing

/// Links in an agent's message that name a file: opened in the editor at their line, where
/// the system would refuse them (-50) for having no scheme.
@Suite("File links")
struct FileLinkTests {
  private let folder = URL(filePath: "/work/app", directoryHint: .isDirectory)

  /// As SwiftUI's Markdown hands the destination over.
  private func link(_ destination: String) throws -> FileLink? {
    let text = try AttributedString(markdown: "[x](\(destination))")
    let url = try #require(text.runs.compactMap(\.link).first)
    return FileLink(url, relativeTo: folder)
  }

  @Test func claudesRelativeLinksWithAFragment() throws {
    #expect(try link("src/a.ts") == FileLink(path: "/work/app/src/a.ts"))
    #expect(try link("src/a.ts#L42") == FileLink(path: "/work/app/src/a.ts", line: 42))
    #expect(try link("src/a.ts#L42-L51") == FileLink(path: "/work/app/src/a.ts", line: 42))
    #expect(try link("../b/c.swift#L3") == FileLink(path: "/work/b/c.swift", line: 3))
  }

  @Test func codexsAbsolutePathsWithALineSuffix() throws {
    #expect(try link("/src/a.swift:12") == FileLink(path: "/src/a.swift", line: 12))
    #expect(try link("/src/a.swift:12:5") == FileLink(path: "/src/a.swift", line: 12, column: 5))
    #expect(try link("/src/a.swift:12-20") == FileLink(path: "/src/a.swift", line: 12))
    // No slash before the colon: Foundation reads `a.swift` as a scheme.
    #expect(try link("a.swift:7") == FileLink(path: "/work/app/a.swift", line: 7))
  }

  @Test func fileURLsAndEncodedNames() throws {
    #expect(try link("file:///src/a.swift#L2") == FileLink(path: "/src/a.swift", line: 2))
    #expect(try link("/src/my%20file.md") == FileLink(path: "/src/my file.md"))
  }

  @Test func webAndOtherSchemesAreNotFiles() throws {
    #expect(try link("https://example.com/a.swift#L2") == nil)
    #expect(try link("mailto:a@example.com") == nil)
    #expect(try link("vscode://file/a") == nil)
  }

  @Test func theOffsetOfALineAndColumn() {
    let text = "one\ntwo\nthree"
    #expect(FileLink(path: "/a").offset(in: text) == nil)
    #expect(FileLink(path: "/a", line: 1).offset(in: text) == 0)
    #expect(FileLink(path: "/a", line: 2).offset(in: text) == 4)
    #expect(FileLink(path: "/a", line: 3, column: 3).offset(in: text) == 10)
    // A column past the line's end stops there; a line past the file's, at its end.
    #expect(FileLink(path: "/a", line: 2, column: 40).offset(in: text) == 7)
    #expect(FileLink(path: "/a", line: 9).offset(in: text) == 13)
  }
}
