import Foundation

/// The text a turn ended on: its last assistant message's text blocks, joined.
public struct ClosingText: Sendable, Equatable {
  /// `message.id` of that assistant message: what a dismissal remembers.
  public var messageID: String
  public var text: String

  public init(messageID: String, text: String) {
    self.messageID = messageID
    self.text = text
  }
}

/// What a turn ended on, when it wants the person: a question ("Want me to build it that
/// way?") or an offer ("Say the word and I'll add it").
///
/// A model often asks for a go-ahead in prose rather than through `AskUserQuestion`, and
/// such a turn waits for the person as surely as a permission request does. Rules, not a
/// model: Drakar makes no outgoing connection. Measured on a hundred labelled endings
/// (`closing-endings.jsonl`): most asks explain themselves after the question, so any
/// question in the closing paragraphs counts, the last one shown.
public struct ClosingAsk: Sendable, Hashable {
  public enum Kind: String, Sendable {
    case question, offer
  }

  public var kind: Kind
  /// The sentence a row and a notification show.
  public var text: String

  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }

  /// Asks without a question mark, at the start of a sentence, folded.
  public static let asks = [
    "want me to", "should i ", "shall i ", "would you like", "do you want",
    "ready to proceed", "go ahead with", "which one do you", "which option do you",
    "which approach do you",
  ]
  /// The person is asked to act, anywhere in a sentence, folded.
  public static let requests = ["tell me when", ", tell me,", "waiting on your go-ahead"]
  /// Sign-offs: never a question, even with a question mark.
  public static let signOffs = ["let me know if", "feel free to", "happy to"]
  /// Offers without asking, anywhere in a sentence, folded.
  public static let offers = [
    "let me know if", "feel free to", "if you want", "if you'd like", "if you like", "say the word",
    "say if you want", "happy to",
  ]
  /// What a row and a notification show at most.
  public static let maxLength = 140

  public static func detect(_ text: String) -> ClosingAsk? {
    let sentences = paragraphs(of: stripped(text)).suffix(2).flatMap(sentences(of:))
    if let sentence = sentences.last(where: isQuestion) {
      return ClosingAsk(kind: .question, text: shortened(sentence))
    }
    if let sentence = sentences.last(where: isOffer) {
      return ClosingAsk(kind: .offer, text: shortened(sentence))
    }
    return nil
  }

  /// Code, quotes and links taken out: a `?` in a regex, a URL or a quoted message is not
  /// the model asking.
  static func stripped(_ text: String) -> String {
    var text = text.replacingOccurrences(of: "\r\n", with: "\n")
    // An unclosed fence runs to the end: a reply cut off mid-block is code from there on.
    text = text.replacing(#/(?:```|~~~)[\s\S]*?(?:```|~~~|\z)/#, with: "\n\n")
    text = text.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
      .joined(separator: "\n")
    text = text.replacing(#/`[^`\n]*`/#, with: "")
    return text.replacing(#/https?://\S+/#, with: "")
  }

  static func paragraphs(of text: String) -> [String] {
    text.split(separator: #/\n[ \t]*\n/#)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  /// Every line break ends a sentence, and so does `.`, `?`, `!` (or their full-width
  /// forms) before a space or the end of the line, closing quotes and emphasis included.
  static func sentences(of paragraph: String) -> [String] {
    var sentences: [String] = []
    func add(_ raw: String) {
      let sentence = raw.trimmingCharacters(in: decoration)
      if !sentence.isEmpty { sentences.append(sentence) }
    }
    for line in paragraph.split(separator: "\n") {
      let characters = Array(line)
      var current = ""
      var index = 0
      while index < characters.count {
        let character = characters[index]
        current.append(character)
        index += 1
        guard ".?!？！。".contains(character) else { continue }
        var next = index
        while next < characters.count, closers.contains(characters[next]) { next += 1 }
        if next == characters.count || characters[next].isWhitespace {
          current.append(contentsOf: characters[index..<next])
          index = next
          add(current)
          current = ""
        }
      }
      add(current)
    }
    return sentences
  }

  static let closers: Set<Character> = ["\"", "”", "'", "’", ")", "]", "*", "_"]

  /// Markdown emphasis, headings, list bullets and brackets around a sentence.
  static let decoration = CharacterSet.whitespacesAndNewlines.union(
    CharacterSet(charactersIn: "*_#-()[]\"“”"))

  static func isQuestion(_ sentence: String) -> Bool {
    let folded = folded(sentence)
    if signOffs.contains(where: folded.hasPrefix) { return false }
    if let last = sentence.last, last == "?" || last == "？" { return true }
    return asks.contains(where: folded.hasPrefix) || requests.contains(where: folded.contains)
  }

  static func isOffer(_ sentence: String) -> Bool {
    let folded = folded(sentence)
    return offers.contains(where: folded.contains)
  }

  /// Lowercased, with typographic apostrophes straight: models write "I’d" as often as "I'd".
  static func folded(_ sentence: String) -> String {
    sentence.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
  }

  static func shortened(_ sentence: String) -> String {
    let words = sentence.split(whereSeparator: \.isWhitespace)
    let collapsed = words.joined(separator: " ")
    guard collapsed.count > maxLength else { return collapsed }
    var shown = ""
    for word in words {
      let next = shown.isEmpty ? String(word) : shown + " " + word
      if next.count > maxLength - 1 { break }
      shown = next
    }
    return shown + "…"
  }
}
