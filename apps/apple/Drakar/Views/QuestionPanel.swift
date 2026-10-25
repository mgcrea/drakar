import AppKit
import DrakarKit
import SwiftUI

/// An `AskUserQuestion`, answered in its transcript card or in place of the composer: a
/// tab per question, its options as radio buttons (checkboxes when it takes several), an
/// "Other" with its own field, and a preview beside the options when they carry one. The
/// transcript stays in sight above it, since a question usually refers to what was just said.
///
/// The same panel answers a live request and a question whose process ended before an
/// answer; the caller decides how the answers go back. A plain Allow would tell the model the
/// person did not answer, so Answer waits until every question has one.
struct QuestionPanel: View {
  let questions: [UserQuestion]
  let answer: ([String: String]) -> Void
  let skip: () -> Void
  /// Nil in place of the composer, where the panel takes the keys on appearing and scrolls its
  /// options itself. In a transcript card, the panel takes them each time this changes, and
  /// grows with its options: a lazy stack puts a row back as it scrolls, and a row that
  /// changed the focus on appearing, or sized a scroll view of its own, laid the transcript
  /// out again without end until AppKit stopped the app.
  var focusRequest: Int?

  @State private var current = 0
  @State private var picked: [String: Set<String>] = [:]
  /// The questions whose "Other" is picked, and what was typed in each.
  @State private var otherPicked: Set<String> = []
  @State private var other: [String: String] = [:]
  /// The row under the keyboard or the pointer; `options.count` is "Other".
  @State private var highlighted: Int?
  @State private var advance: Task<Void, Never>?
  @FocusState private var focus: Focus?

  private enum Focus: Hashable { case panel, other }

  /// Every question's answer, or nil while one has none.
  static func answers(
    for questions: [UserQuestion], picked: [String: Set<String>], otherPicked: Set<String>,
    other: [String: String]
  ) -> [String: String]? {
    var answers: [String: String] = [:]
    for question in questions {
      let typed = otherPicked.contains(question.question) ? other[question.question] ?? "" : ""
      guard let answer = question.answer(picked: picked[question.question] ?? [], other: typed)
      else { return nil }
      answers[question.question] = answer
    }
    return answers
  }

  /// What a digit does: the row it picks, and whether ⌘ held with it answers too. Nil while
  /// "Other"'s field takes the typing, and with any other modifier.
  static func digitPick(_ characters: String, modifiers: EventModifiers, typing: Bool)
    -> (row: Int, answers: Bool)?
  {
    guard !typing, let digit = Int(characters), digit >= 1 else { return nil }
    switch modifiers.subtracting([.capsLock, .numericPad]) {
    case []: return (digit - 1, false)
    case .command: return (digit - 1, true)
    default: return nil
    }
  }

  /// Row `index` of `question` picked: a single choice replaces the pick, a multiple one
  /// toggles it; "Other" (`options.count`) toggles, and keeps a single choice's pick off.
  static func pick(
    _ index: Int, in question: UserQuestion, picked: inout [String: Set<String>],
    otherPicked: inout Set<String>
  ) {
    let key = question.question
    if index == question.options.count {
      if question.multiSelect || !otherPicked.contains(key) {
        otherPicked.formSymmetricDifference([key])
      }
      if !question.multiSelect { picked[key] = [] }
      return
    }
    let label = question.options[index].label
    if question.multiSelect {
      picked[key, default: []].formSymmetricDifference([label])
    } else {
      picked[key] = [label]
      otherPicked.remove(key)
    }
  }

  private var answers: [String: String]? {
    Self.answers(for: questions, picked: picked, otherPicked: otherPicked, other: other)
  }

  private var question: UserQuestion? {
    questions.indices.contains(current) ? questions[current] : nil
  }

  private func isAnswered(_ question: UserQuestion) -> Bool {
    Self.answers(for: [question], picked: picked, otherPicked: otherPicked, other: other) != nil
  }

  var body: some View {
    if let focusRequest {
      panel.onChange(of: focusRequest) { focus = .panel }
    } else {
      panel.onAppear { focus = .panel }
    }
  }

  private var panel: some View {
    VStack(alignment: .leading, spacing: 10) {
      tabs
      if let question {
        if focusRequest == nil {
          ScrollView { choices(question) }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          choices(question)
        }
      }
      footer
    }
    .padding(12)
    .focusable()
    .focusEffectDisabled()
    .focused($focus, equals: .panel)
    // The panel's keys are the field's while "Other" is typed in.
    .onKeyPress(.upArrow) { isTyping ? .ignored : move(-1) }
    .onKeyPress(.downArrow) { isTyping ? .ignored : move(1) }
    .onKeyPress(.leftArrow) { isTyping ? .ignored : show(current - 1) }
    .onKeyPress(.rightArrow) { isTyping ? .ignored : show(current + 1) }
    .onKeyPress(.space) {
      guard !isTyping, let highlighted else { return .ignored }
      pick(highlighted)
      return .handled
    }
    .onKeyPress(characters: .decimalDigits, phases: .down) { press in
      guard
        let (row, answering) = Self.digitPick(
          press.characters, modifiers: press.modifiers, typing: isTyping)
      else { return .ignored }
      pick(row, answering: answering)
      return .handled
    }
    .onDisappear { advance?.cancel() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Claude is asking you a question")
    .accessibilityIdentifier("question.panel")
  }

  private func choices(_ question: UserQuestion) -> some View {
    HStack(alignment: .top, spacing: 12) {
      options(question)
      if question.options.contains(where: { $0.preview != nil }) {
        preview(question).frame(width: 320)
      }
    }
  }

  /// One tab per question when there are several, named by its header and checked once
  /// answered; a lone question shows its header alone.
  private var tabs: some View {
    HStack(spacing: 6) {
      Image(systemName: "questionmark.bubble").foregroundStyle(.tint)
      if questions.count > 1 {
        ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
          Button {
            _ = show(index)
          } label: {
            Label(
              question.header ?? String(localized: "Question \(index + 1)"),
              systemImage: isAnswered(question) ? "checkmark.circle.fill" : "circle"
            )
            .font(.caption.weight(index == current ? .semibold : .regular))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
              index == current ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
          }
          .buttonStyle(.plain)
          .foregroundStyle(index == current ? .primary : .secondary)
          .accessibilityAddTraits(index == current ? .isSelected : [])
          .accessibilityIdentifier("question.tab.\(index)")
        }
      } else if let header = question?.header {
        Text(header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      }
      Spacer()
    }
  }

  private func options(_ question: UserQuestion) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(question.question)
        .font(.headline)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .padding(.bottom, 6)
      ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
        OptionRow(
          label: option.label, description: option.description,
          multiSelect: question.multiSelect,
          isSelected: picked[question.question]?.contains(option.label) == true,
          isHighlighted: highlighted == index, number: index + 1,
          pick: { pick(index, answering: NSEvent.modifierFlags.contains(.command)) },
          hover: { highlighted = $0 ? index : nil }
        )
        .accessibilityIdentifier("question.option.\(option.label)")
      }
      let otherIndex = question.options.count
      OptionRow(
        label: String(localized: "Other"), description: nil, multiSelect: question.multiSelect,
        isSelected: otherPicked.contains(question.question),
        isHighlighted: highlighted == otherIndex, number: otherIndex + 1,
        pick: { pick(otherIndex) }, hover: { highlighted = $0 ? otherIndex : nil }
      )
      .accessibilityIdentifier("question.other")
      if otherPicked.contains(question.question) {
        TextField("Type your answer…", text: otherBinding(question), axis: .vertical)
          .lineLimit(1...5)
          .focused($focus, equals: .other)
          .padding(.leading, 30)
          .accessibilityIdentifier("question.otherField")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The preview of the option under the pointer or the keyboard, else of the one picked.
  /// Text with a fence is Markdown; anything else, a mockup drawn in characters, is kept
  /// monospaced as the extension keeps it.
  private func preview(_ question: UserQuestion) -> some View {
    let options = question.options
    let shown =
      highlighted.flatMap { options.indices.contains($0) ? options[$0] : nil }
      ?? options.first { picked[question.question]?.contains($0.label) == true }
    return VStack(alignment: .leading, spacing: 6) {
      if let shown {
        Text(shown.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        if let preview = shown.preview {
          if preview.contains("```") {
            MarkdownView(text: preview)
          } else {
            CodeBlock(text: preview)
          }
        } else {
          Text("No preview for this option").font(.callout).foregroundStyle(.tertiary)
        }
      } else {
        Text("Point at an option to preview it").font(.callout).foregroundStyle(.tertiary)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    .accessibilityIdentifier("question.preview")
  }

  private var footer: some View {
    HStack {
      Text(hint).font(.caption).foregroundStyle(.tertiary)
      Spacer()
      Button("Skip", action: skip)
        .keyboardShortcut(.cancelAction)
        .help("Tell Claude you won't answer, and let it wait for your next message")
        .accessibilityIdentifier("question.skip")
      Button(
        answers == nil ? String(localized: "Next") : String(localized: "Answer"), action: primary
      )
      .keyboardShortcut(.defaultAction)
      .disabled(answers == nil && !(question.map(isAnswered) ?? false))
      .accessibilityIdentifier("question.answer")
    }
  }

  private var hint: String {
    let count = (question?.options.count ?? 0) + 1
    return questions.count > 1
      ? String(
        localized: "1–\(count) to pick, with ⌘ to answer too, ←→ between questions, ⏎ to go on")
      : String(localized: "1–\(count) to pick, with ⌘ to answer too, ⏎ to answer")
  }

  private var isTyping: Bool { focus == .other }

  /// Answer once every question has one; until then, on to the next one without.
  private func primary() {
    if let answers { return answer(answers) }
    let order = questions.indices.map { (current + 1 + $0) % questions.count }
    if let next = order.first(where: { !isAnswered(questions[$0]) }) { _ = show(next) }
  }

  /// Picks row `index` of the current question; `answering` (⌘ held) answers at once when
  /// the pick leaves every question with an answer. Otherwise a single choice moves on to the
  /// next question by itself, after a beat so the pick is seen; "Other" waits for its text.
  private func pick(_ index: Int, answering: Bool = false) {
    guard let question, index >= 0, index <= question.options.count else { return }
    highlighted = index
    Self.pick(index, in: question, picked: &picked, otherPicked: &otherPicked)
    if index == question.options.count {
      focus = otherPicked.contains(question.question) ? .other : .panel
      return
    }
    focus = .panel
    if answering, let answers {
      advance?.cancel()
      return answer(answers)
    }
    guard !question.multiSelect, current < questions.count - 1 else { return }
    advance?.cancel()
    let from = current
    advance = Task {
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled, current == from else { return }
      _ = show(from + 1)
    }
  }

  private func move(_ step: Int) -> KeyPress.Result {
    guard let question else { return .ignored }
    let rows = question.options.count + 1
    highlighted = ((highlighted ?? (step > 0 ? -1 : rows)) + step + rows) % rows
    return .handled
  }

  private func show(_ index: Int) -> KeyPress.Result {
    guard questions.indices.contains(index) else { return .ignored }
    advance?.cancel()
    current = index
    highlighted = nil
    focus = .panel
    return .handled
  }

  private func otherBinding(_ question: UserQuestion) -> Binding<String> {
    Binding(
      get: { other[question.question] ?? "" },
      set: { other[question.question] = $0 })
  }
}

/// One option: a radio button, or a checkbox when the question takes several, with its
/// description under it. Without `pick`, read-only, as the transcript shows an answer.
struct OptionRow: View {
  let label: String
  let description: String?
  let multiSelect: Bool
  let isSelected: Bool
  var isHighlighted = false
  /// Another option was picked: this one is shown faded.
  var isDimmed = false
  var number: Int?
  var pick: (() -> Void)?
  var hover: (Bool) -> Void = { _ in }

  var body: some View {
    if let pick {
      Button(action: pick) { row }
        .buttonStyle(.plain)
        .onHover(perform: hover)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    } else {
      row
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
  }

  private var row: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: glyph)
        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
        if let description {
          Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      if let number, number <= 9 {
        Text("\(number)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(
      isHighlighted ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
      in: RoundedRectangle(cornerRadius: 6)
    )
    .contentShape(RoundedRectangle(cornerRadius: 6))
    .opacity(isDimmed ? 0.45 : 1)
  }

  private var glyph: String {
    switch (multiSelect, isSelected) {
    case (true, true): "checkmark.square.fill"
    case (true, false): "square"
    case (false, true): "largecircle.fill.circle"
    case (false, false): "circle"
    }
  }
}
