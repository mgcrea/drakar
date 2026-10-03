import DrakarKit
import Foundation
import Testing

@Suite("Searching a folder")
struct ProjectSearchTests {

  private func folder(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "drakar-search-\(UUID().uuidString)", directoryHint: .isDirectory)
    for (path, text) in files {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: false, encoding: .utf8)
    }
    return root
  }

  @Test func findsEveryMatchWithItsLine() throws {
    let root = try folder([
      "a.swift": "import Foundation\n\n    func greet() { greet() }\n",
      "b.md": "Nothing here\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let hits = ProjectSearch.search("greet", in: ["a.swift", "b.md"], under: root)
    #expect(hits.map(\.line) == [3, 3])
    #expect(hits.first?.preview == "func greet() { greet() }")
    #expect(hits.first?.previewRange == 5..<10)
    let text = "import Foundation\n\n    func greet() { greet() }\n" as NSString
    #expect(
      hits.first?.range == text.range(of: "greet").location..<(text.range(of: "greet").location + 5)
    )
  }

  /// Smart case: lower case ignores case, a capital asks for it.
  @Test func matchesCaseOnlyWhenAskedTo() throws {
    let root = try folder(["a.txt": "Drakar drakar DRAKAR\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(ProjectSearch.search("drakar", in: ["a.txt"], under: root).count == 3)
    #expect(ProjectSearch.search("Drakar", in: ["a.txt"], under: root).count == 1)
  }

  @Test func skipsWhatIsNotTextAndStopsAtTheLimit() throws {
    let root = try folder(["a.txt": String(repeating: "x\n", count: 10)])
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([0x78, 0x00, 0x78]).write(to: root.appending(path: "b.bin"))
    #expect(ProjectSearch.search("x", in: ["b.bin"], under: root).isEmpty)
    #expect(ProjectSearch.search("x", in: ["a.txt"], under: root, limit: 4).count == 4)
    #expect(ProjectSearch.search("x", in: ["a.txt"], under: root, isCancelled: { true }).isEmpty)
    #expect(ProjectSearch.search("", in: ["a.txt"], under: root).isEmpty)
  }

  @Test func cutsALongLineAroundTheMatch() throws {
    let line = String(repeating: "a", count: 300) + "needle" + String(repeating: "b", count: 300)
    let root = try folder(["long.txt": line])
    defer { try? FileManager.default.removeItem(at: root) }
    let hit = try #require(ProjectSearch.search("needle", in: ["long.txt"], under: root).first)
    let preview = hit.preview as NSString
    #expect(
      preview.substring(with: NSRange(location: hit.previewRange.lowerBound, length: 6)) == "needle"
    )
    #expect(preview.length <= 202)
  }
}
