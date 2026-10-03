import AmiralKit
import Testing

@Suite("Splitting Markdown into blocks")
struct MarkdownTests {

  @Test func readsHeadingsAndParagraphs() {
    #expect(
      MarkdownBlock.parse("# The Last Command\n\nAdmiral Voss stood\non the deck.") == [
        .heading(level: 1, text: "The Last Command"),
        .paragraph("Admiral Voss stood\non the deck."),
      ])
    // No space after the hashes: not a heading (a `#hashtag`, a C preprocessor line).
    #expect(MarkdownBlock.parse("#include <x>") == [.paragraph("#include <x>")])
  }

  /// The answer Haiku wrote during the thinking spike, as it arrived.
  @Test func readsTheCapturedAnswer() {
    let text = """
      **Calculation:**
      17 × 23 = **391**

      **Two facts about 391:**
      - **Semiprime:** It's the product of two primes
      - **Odd number:** 391 is odd
      """
    #expect(
      MarkdownBlock.parse(text) == [
        .paragraph("**Calculation:**\n17 × 23 = **391**"),
        .paragraph("**Two facts about 391:**"),
        .listItem(marker: nil, indent: 0, text: "**Semiprime:** It's the product of two primes"),
        .listItem(marker: nil, indent: 0, text: "**Odd number:** 391 is odd"),
      ])
  }

  @Test func readsOrderedAndNestedItems() {
    #expect(
      MarkdownBlock.parse("1. First\n  - nested\n10) Tenth") == [
        .listItem(marker: "1.", indent: 0, text: "First"),
        .listItem(marker: nil, indent: 1, text: "nested"),
        .listItem(marker: "10.", indent: 0, text: "Tenth"),
      ])
  }

  @Test func keepsCodeVerbatim() {
    let text = "Run:\n```swift\nlet x = 1\n\n# not a heading\n```\nDone."
    #expect(
      MarkdownBlock.parse(text) == [
        .paragraph("Run:"),
        .code(language: "swift", text: "let x = 1\n\n# not a heading"),
        .paragraph("Done."),
      ])
  }

  /// Streaming cuts a message anywhere; an open fence is code in progress.
  @Test func showsAnUnclosedFenceAsCode() {
    #expect(
      MarkdownBlock.parse("```\nmake test\nmake bu") == [
        .code(language: nil, text: "make test\nmake bu")
      ])
  }

  @Test func readsQuotesTablesAndRules() {
    let text = "> one\n> two\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---\nafter"
    #expect(
      MarkdownBlock.parse(text) == [
        .quote("one\ntwo"),
        .table(["| a | b |", "|---|---|", "| 1 | 2 |"]),
        .rule,
        .paragraph("after"),
      ])
  }

  /// `- item` is a list, `---` is a rule, `-x` is text: the three a dash can start.
  @Test func tellsDashesApart() {
    #expect(MarkdownBlock.parse("- item") == [.listItem(marker: nil, indent: 0, text: "item")])
    #expect(MarkdownBlock.parse("- - -") == [.rule])
    #expect(MarkdownBlock.parse("-x") == [.paragraph("-x")])
  }
}
