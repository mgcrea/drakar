import DrakarKit
import Testing

@Suite("A tool's output as its card shows it")
struct ToolOutputTests {

  @Test func escapesAreRemoved() {
    #expect(ToolOutput.cleaned("\u{1B}[1;31mred\u{1B}[0m ok") == "red ok")
    // OSC, ended by BEL or by ESC \ (a terminal hyperlink).
    #expect(ToolOutput.cleaned("\u{1B}]0;title\u{07}x") == "x")
    #expect(ToolOutput.cleaned("\u{1B}]8;;https://a\u{1B}\\link\u{1B}]8;;\u{1B}\\") == "link")
    // A two-character escape, and one cut short at the end.
    #expect(ToolOutput.cleaned("a\u{1B}=b\u{1B}[3") == "ab")
  }

  @Test func returnsRewriteTheLine() {
    #expect(ToolOutput.cleaned("a\r\nb") == "a\nb")
    #expect(ToolOutput.cleaned("10%\r50%\r100%\ndone") == "100%\ndone")
    // A return with nothing written after it leaves the line as it was.
    #expect(ToolOutput.cleaned("kept\r\nnext\r") == "kept\nnext")
  }

  @Test func controlCharactersAreDropped() {
    #expect(ToolOutput.cleaned("a\u{07}b\u{08}c\td") == "abc\td")
  }

  @Test func thePreviewIsTheFirstLines() throws {
    let preview = try #require(ToolOutput.preview(of: "\n\none\ntwo\nthree\nfour\n", lines: 3))
    #expect(preview.text == "one\ntwo\nthree")
    #expect(preview.isClipped)

    let short = try #require(ToolOutput.preview(of: "one\n  two\n\n", lines: 3))
    #expect(short.text == "one\n  two")
    #expect(!short.isClipped)

    #expect(ToolOutput.preview(of: "", lines: 3) == nil)
    #expect(ToolOutput.preview(of: " \n\u{1B}[0m\n", lines: 3) == nil)
  }

  /// A long result is read only so far, and the line the cut went through is left out.
  @Test func aLongResultIsReadOnlyAtItsStart() throws {
    let log = (1...100_000).map { "line \($0)" }.joined(separator: "\n")
    let preview = try #require(ToolOutput.preview(of: log, lines: 3))
    #expect(preview.text == "line 1\nline 2\nline 3")
    #expect(preview.isClipped)

    let oneLine = String(repeating: "x", count: 20_000)
    let cut = try #require(ToolOutput.preview(of: oneLine, lines: 3))
    #expect(cut.isClipped)
    #expect(!cut.text.isEmpty)
  }

  @Test func aRefusalSaysItsReason() {
    let prefix =
      "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). "
    let withReason = Transcript.ToolResult(
      content: prefix + "The user provided the following reason for the rejection:  not now\n",
      isError: true)
    #expect(ToolOutput.refusal(in: withReason)?.reason == "not now")

    let bare = Transcript.ToolResult(
      content: prefix + "STOP what you are doing and wait for the user to tell you how to proceed.",
      isError: true)
    let refused = ToolOutput.refusal(in: bare)
    #expect(refused != nil && refused?.reason == nil)

    #expect(ToolOutput.refusal(in: .init(content: "Exit code 1", isError: true)) == nil)
    #expect(ToolOutput.refusal(in: .init(content: prefix, isError: false)) == nil)
  }

  @Test func aSearchIsCounted() {
    #expect(ToolOutput.searchSummary(of: "/a\n/b\n/c\n", isFileList: true) == "Found 3 files")
    #expect(ToolOutput.searchSummary(of: "/a", isFileList: true) == "Found 1 file")
    #expect(ToolOutput.searchSummary(of: "No files found", isFileList: true) == "No files found")

    #expect(
      ToolOutput.searchSummary(of: "Found 2 files\n/a\n/b", isFileList: false)
        == "Found 2 files")
    #expect(
      ToolOutput.searchSummary(of: "a:1:x\nb:2:y", isFileList: false)
        == "2 lines of output")
    #expect(ToolOutput.searchSummary(of: "a:1:x", isFileList: false) == "1 line of output")
    #expect(
      ToolOutput.searchSummary(of: "No matches found", isFileList: false)
        == "No matches found")
    #expect(ToolOutput.searchSummary(of: "", isFileList: false) == "No matches found")
  }

  @Test func aStoppedSearchCountsOnlyItsResults() {
    let note =
      "The search stopped before it finished, most likely at its time limit, so these results are incomplete: more matches may exist. Search a more specific path or pattern."
    #expect(ToolOutput.searchSummary(of: note + "\n/a\n/b", isFileList: true) == "Found 2 files")
  }
}
