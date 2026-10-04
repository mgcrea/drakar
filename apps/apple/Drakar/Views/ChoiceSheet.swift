import DrakarKit
import SwiftUI

/// An `AskUserQuestion`, answered: each question with its options, an "Other" field, and
/// the picked labels sent back the way the CLI's own picker sends them. A plain Allow would
/// tell the model the person did not answer.
struct ChoiceSheet: View {
  let pending: Transcript.PendingPermission
  let answer: (PermissionDecision) -> Void

  @State private var picked: [String: Set<String>] = [:]
  @State private var other: [String: String] = [:]

  private var questions: [UserQuestion] { UserQuestion.list(pending.request.input) }

  /// `allow` with every question answered, or nil while one is not.
  static func decision(
    for questions: [UserQuestion], input: JSONValue, picked: [String: Set<String>],
    other: [String: String]
  ) -> PermissionDecision? {
    var answers: [String: String] = [:]
    for question in questions {
      guard
        let answer = question.answer(
          picked: picked[question.question] ?? [], other: other[question.question] ?? "")
      else { return nil }
      answers[question.question] = answer
    }
    return .allow(updatedInput: UserQuestion.answering(input, with: answers))
  }

  private var decision: PermissionDecision? {
    Self.decision(for: questions, input: pending.request.input, picked: picked, other: other)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      ForEach(questions) { question in
        VStack(alignment: .leading, spacing: 8) {
          if let header = question.header {
            Text(header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          }
          Text(question.question).font(.title3.weight(.semibold))
          ForEach(question.options, id: \.label) { option in
            Toggle(isOn: binding(question, option.label)) {
              VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                if let description = option.description {
                  Text(description).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("choice.option.\(option.label)")
          }
          TextField("Other", text: otherBinding(question))
            .accessibilityIdentifier("choice.other")
        }
      }
      HStack {
        Spacer()
        Button("Skip") { answer(.deny(message: "The user chose not to answer.")) }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("choice.skip")
        Button("Answer") { if let decision { answer(decision) } }
          .keyboardShortcut(.defaultAction)
          .disabled(decision == nil)
          .accessibilityIdentifier("choice.answer")
      }
    }
    .padding(20)
    .frame(width: 460)
    .interactiveDismissDisabled()
  }

  /// A checkbox per option; picking one of a single-choice question unpicks the rest.
  private func binding(_ question: UserQuestion, _ label: String) -> Binding<Bool> {
    Binding(
      get: { picked[question.question]?.contains(label) == true },
      set: { isOn in
        var set = question.multiSelect ? picked[question.question] ?? [] : []
        if isOn { set.insert(label) } else { set.remove(label) }
        picked[question.question] = set
      })
  }

  private func otherBinding(_ question: UserQuestion) -> Binding<String> {
    Binding(
      get: { other[question.question] ?? "" },
      set: { other[question.question] = $0 })
  }
}
