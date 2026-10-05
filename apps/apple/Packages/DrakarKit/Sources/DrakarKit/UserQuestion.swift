import Foundation

/// One question of an `AskUserQuestion` call, and how its answer goes back.
///
/// Verified on 2.1.288 (docs/claude-stream-json.md, "AskUserQuestion"): the answer rides in
/// the permission's `updatedInput` as `answers: {question: answer}`; a plain `allow`
/// tells the model the person did not answer. A multi-select answer is its labels joined
/// with ", ", as the CLI's own picker writes it.
public struct UserQuestion: Sendable, Equatable, Identifiable {
  public struct Option: Sendable, Equatable {
    public var label: String
    public var description: String?
    /// What picking it would look like (a mockup, a snippet), shown beside the options.
    public var preview: String?

    public init(label: String, description: String?, preview: String? = nil) {
      self.label = label
      self.description = description
      self.preview = preview
    }
  }

  /// An answer read back as the options it picked and the text typed beside them.
  public struct Reading: Sendable, Equatable {
    public var picked: [String]
    public var other: String?

    public init(picked: [String], other: String?) {
      self.picked = picked
      self.other = other
    }
  }

  public static let toolName = "AskUserQuestion"

  public var id: String { question }
  public var question: String
  public var header: String?
  public var options: [Option]
  public var multiSelect: Bool

  public init(question: String, header: String?, options: [Option], multiSelect: Bool) {
    self.question = question
    self.header = header
    self.options = options
    self.multiSelect = multiSelect
  }

  /// The questions of an `AskUserQuestion` input, in order.
  public static func list(_ input: JSONValue) -> [UserQuestion] {
    (input["questions"]?.arrayValue ?? []).compactMap { entry in
      guard let question = entry["question"]?.stringValue else { return nil }
      return UserQuestion(
        question: question, header: entry["header"]?.stringValue,
        options: (entry["options"]?.arrayValue ?? []).compactMap { option in
          option["label"]?.stringValue.map {
            let preview = option["preview"]?.stringValue
            return Option(
              label: $0, description: option["description"]?.stringValue,
              preview: preview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? preview : nil)
          }
        },
        multiSelect: entry["multiSelect"]?.boolValue ?? false)
    }
  }

  /// The answer for `picked` labels and a typed `other`: the labels in the options' order,
  /// then the typed text; nil when there is neither.
  public func answer(picked: Set<String>, other: String) -> String? {
    var parts = options.map(\.label).filter(picked.contains)
    let typed = other.trimmingCharacters(in: .whitespacesAndNewlines)
    if !typed.isEmpty { parts.append(typed) }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }

  /// `input` with `answers` added: the `updatedInput` of the `allow` that answers.
  public static func answering(_ input: JSONValue, with answers: [String: String]) -> JSONValue {
    guard case .object(var object) = input else { return input }
    object["answers"] = .object(answers.mapValues { .string($0) })
    return .object(object)
  }

  /// `answer` read back as options, as the extension reads it: a single choice is its label
  /// or typed text; a multiple one, the longest labels that start it, each followed by
  /// ", ", then whatever is left as typed text. A label holding ", " makes that ambiguous,
  /// and the whole answer reads as typed.
  public func reading(_ answer: String) -> Reading {
    let labels = options.map(\.label)
    guard multiSelect else {
      return labels.contains(answer)
        ? Reading(picked: [answer], other: nil) : Reading(picked: [], other: answer)
    }
    guard !labels.contains(where: { $0.contains(", ") }) else {
      return Reading(picked: [], other: answer)
    }
    var picked: [String] = []
    var rest = Substring(answer)
    while let label = labels.filter({ rest == $0 || rest.hasPrefix($0 + ", ") })
      .max(by: { $0.count < $1.count })
    {
      picked.append(label)
      rest = rest.dropFirst(label.count)
      if rest.isEmpty { return Reading(picked: picked, other: nil) }
      rest = rest.dropFirst(2)
    }
    return Reading(picked: picked, other: String(rest))
  }

  // MARK: - The tool result

  /// What `deny` says when the person skips, the extension's own rejection: the model stops
  /// and waits, rather than guessing the answer it asked for.
  public static let declinedMessage =
    "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed."
  static let declinedPrefix = "The user doesn't want to proceed with this tool use."
  static let declinedReasonMarker = "The user provided the following reason for the rejection: "
  static let unansweredMessage = "The user did not answer the questions."
  static let answeredPrefixes = ["Your questions have been answered: ", "The user answered: "]
  static let answeredSuffixes = [
    ". You can now continue with these answers in mind.",
    ". Read the answers carefully — they may request clarification, changes, or that you not proceed — and follow what they actually say.",
  ]

  /// The answers a result names, `"<question>"="<answer>", …`, for `questions` in their
  /// order; nil when the text is not an answer. The structured `answers` the CLI writes
  /// beside it is the reliable source, and this the fallback for a line without one.
  public static func answers(inResult text: String, questions: [String]) -> [String: String]? {
    guard let prefix = answeredPrefixes.first(where: text.hasPrefix),
      let suffix = answeredSuffixes.first(where: text.hasSuffix),
      text.count >= prefix.count + suffix.count
    else { return nil }
    let body = String(text.dropFirst(prefix.count).dropLast(suffix.count))
    let found = values(
      in: body, questions: questions, marker: { "\"\($0)\"=\"" }, between: ", ")
    // Each value still ends on its closing quote.
    return found.isEmpty ? nil : found.mapValues { $0.hasSuffix("\"") ? String($0.dropLast()) : $0 }
  }

  // MARK: - An earlier question

  static let earlierPrefix = "Answering your earlier question \""
  static let earlierHeader = "Answering your earlier questions:"

  /// The prompt that answers a question its process never got the answer to, worded as
  /// the extension words it, so either app reads the other's.
  public static func earlierAnswerPrompt(_ answers: [(question: String, answer: String)])
    -> String
  {
    if answers.count == 1, let only = answers.first {
      return "\(earlierPrefix)\(only.question)\": \(only.answer)"
    }
    return ([earlierHeader] + answers.map { "- \"\($0.question)\": \($0.answer)" })
      .joined(separator: "\n")
  }

  /// The answers `prompt` gives to `questions`, when it is an `earlierAnswerPrompt`.
  public static func earlierAnswers(in prompt: String, questions: [String]) -> [String: String]? {
    if prompt.hasPrefix(earlierPrefix) {
      let rest = prompt.dropFirst(earlierPrefix.count)
      guard
        let question = questions.filter({ rest.hasPrefix($0 + "\": ") })
          .max(by: { $0.count < $1.count })
      else { return nil }
      return [question: String(rest.dropFirst(question.count + 3))]
    }
    guard prompt.hasPrefix(earlierHeader + "\n") else { return nil }
    let found = values(
      in: String(prompt.dropFirst(earlierHeader.count + 1)), questions: questions,
      marker: { "- \"\($0)\": " }, between: "\n")
    return found.isEmpty ? nil : found
  }

  /// `body` cut at each question's `marker`, in order: a value runs to `between` and the
  /// marker of any later question, or to the end.
  private static func values(
    in body: String, questions: [String], marker: (String) -> String, between: String
  ) -> [String: String] {
    var found: [String: String] = [:]
    var cursor = body.startIndex
    for (index, question) in questions.enumerated() {
      guard body[cursor...].hasPrefix(marker(question)) else { continue }
      let start = body.index(cursor, offsetBy: marker(question).count)
      let end =
        questions[(index + 1)...].compactMap {
          body.range(of: between + marker($0), range: start..<body.endIndex)?.lowerBound
        }.min() ?? body.endIndex
      found[question] = String(body[start..<end])
      cursor = end == body.endIndex ? end : body.index(end, offsetBy: between.count)
    }
    return found
  }
}
