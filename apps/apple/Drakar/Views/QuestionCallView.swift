import DrakarKit
import SwiftUI

/// The question waiting on the person, answered in its card in the transcript: which call it
/// is, and how the answers go back. Equal by call, as `OpenInEditorAction` is by workspace,
/// so the closures made on each update do not redraw the card.
struct AskedQuestion: Equatable {
  let callID: String
  let answer: ([String: String]) -> Void
  let skip: () -> Void

  static func == (a: Self, b: Self) -> Bool { a.callID == b.callID }
}

extension EnvironmentValues {
  /// Set by the session; nil while no question waits, or where it cannot be answered.
  @Entry var askedQuestion: AskedQuestion?
}

/// An `AskUserQuestion` in the transcript, as the extension draws it: what became of it, and
/// each question with the options it offered, the picked ones marked and the rest faded.
/// Open from the start, since what was answered is the point of it. While it waits, the card
/// is where it is answered: the question is read where it was asked, after what led to it.
struct QuestionCallView: View {
  let call: Transcript.ToolCall
  @State private var isExpanded = true
  @Environment(\.askedQuestion) private var asked

  private var questions: [UserQuestion] { UserQuestion.list(call.input) }
  private var outcome: Transcript.QuestionOutcome { call.questionOutcome ?? .other }

  private var answers: [String: String]? {
    if case .answered(let answers) = outcome, !answers.isEmpty { return answers }
    return nil
  }

  var body: some View {
    if let asked, asked.callID == call.id {
      // Not collapsible: folded away, an unanswered question would stall the turn unseen.
      QuestionPanel(questions: questions, answer: asked.answer, skip: asked.skip)
        .id(call.id)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.tint.opacity(0.6)))
    } else {
      record
    }
  }

  private var record: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 12) {
        if case .declined(let reason?) = outcome {
          Text("Reason: \(reason)").font(.callout).textSelection(.enabled)
        }
        ForEach(questions) { question in
          answered(question)
        }
        // An answer that cannot be read back as options, or a result of another kind.
        if let result = call.result, answers == nil, showsResult {
          CodeBlock(text: result.content)
            .foregroundStyle(result.isError ? .red : .primary)
        }
      }
      .padding(.top, 6)
    } label: {
      HStack(spacing: 8) {
        statusIcon
        Text(questions.count == 1 ? "Question" : "Questions").fontWeight(.semibold)
        Text(status).font(.callout).foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    .accessibilityIdentifier("tool.\(call.id)")
  }

  private func answered(_ question: UserQuestion) -> some View {
    let reading = answers?[question.question].map(question.reading)
    return VStack(alignment: .leading, spacing: 2) {
      Text(question.question)
        .fontWeight(.semibold)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .padding(.bottom, 4)
      ForEach(question.options, id: \.label) { option in
        let isPicked = reading?.picked.contains(option.label) == true
        OptionRow(
          label: option.label, description: option.description,
          multiSelect: question.multiSelect, isSelected: isPicked,
          isDimmed: reading != nil && !isPicked)
      }
      if let typed = reading?.other {
        OptionRow(
          label: String(localized: "Other"), description: typed,
          multiSelect: question.multiSelect, isSelected: true)
      }
    }
  }

  /// The result's own text is worth showing only when nothing above says it better.
  private var showsResult: Bool {
    switch outcome {
    case .answered, .other: true
    case .waiting, .declined, .unanswered, .sessionEnded: false
    }
  }

  private var status: String {
    let state =
      switch outcome {
      case .waiting: String(localized: "Waiting for your answer")
      case .answered: String(localized: "Answered")
      case .declined: String(localized: "Declined")
      case .unanswered: String(localized: "No answer")
      case .sessionEnded: String(localized: "Session ended before an answer")
      case .other:
        call.result?.isError == true ? String(localized: "Failed") : String(localized: "Done")
      }
    return questions.count > 1 ? "\(state) · \(questions.count) questions" : state
  }

  @ViewBuilder private var statusIcon: some View {
    switch outcome {
    case .waiting: Image(systemName: "questionmark.bubble").foregroundStyle(.tint)
    case .answered: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .declined, .unanswered, .sessionEnded:
      Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
    case .other:
      Image(
        systemName: call.result?.isError == true ? "xmark.circle.fill" : "checkmark.circle.fill"
      )
      .foregroundStyle(call.result?.isError == true ? .red : .green)
    }
  }
}
