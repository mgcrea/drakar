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

    public init(label: String, description: String?) {
      self.label = label
      self.description = description
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
            Option(label: $0, description: option["description"]?.stringValue)
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
}
