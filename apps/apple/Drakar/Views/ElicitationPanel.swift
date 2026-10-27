import AppKit
import DrakarKit
import SwiftUI

/// The MCP server's question waiting on the person, answered under the card of the tool call
/// it interrupted. Equal by call, request, focus request and how many wait, as `AskedQuestion`
/// is: an equal value is never handed on, so the request belongs in the comparison, or a
/// second question in the same call would keep the first one's panel and answer for it; and
/// the count, or "1 of 2" would stay up once the other was answered.
struct AskedElicitation: Equatable {
  let callID: String
  let requestID: String
  /// Bumped by the session to give the panel the keys: see `ElicitationPanel.focusRequest`.
  let focusRequest: Int
  /// How many questions wait, this one among them.
  let count: Int
  let panel: () -> ElicitationPanel

  static func == (a: Self, b: Self) -> Bool {
    a.callID == b.callID && a.requestID == b.requestID && a.focusRequest == b.focusRequest
      && a.count == b.count
  }

  /// The call whose card answers `elicitation`: its server's newest call still running, when
  /// the transcript draws it among its own entries. Nil for a call inside a subagent's card,
  /// which may be folded away, and for no call at all: the composer's place answers it then.
  static func anchor(for elicitation: Elicitation, in transcript: Transcript) -> String? {
    guard let id = transcript.elicitationAnchor(for: elicitation.serverName),
      transcript.entries.last(where: { $0.id == id })?.parentToolUseID == nil
    else { return nil }
    return id
  }
}

extension EnvironmentValues {
  /// Set by the session; nil while no server's question waits, or while it waits in the
  /// composer's place.
  @Entry var askedElicitation: AskedElicitation?
}

/// An MCP tool call's card, with the panel answering its server's question under it while
/// one waits.
struct MCPCallView: View {
  let call: Transcript.ToolCall
  @Environment(\.askedElicitation) private var asked

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ToolCallView(call: call)
      if let asked, asked.callID == call.id {
        // Not folded into the call's card: folded away, the question would stall the turn
        // unseen.
        asked.panel()
          .id(asked.requestID)
          .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.tint.opacity(0.6)))
      }
    }
  }
}

/// An MCP server's question, in its call's card or in place of the composer: the server and
/// what it asks, then its form, its link, or word that Drakar can't show it.
///
/// Submit sends the form once every field holds; Open in Browser accepts and then opens the
/// link, on a click or ⌘↩ and never by itself; Decline, or Esc, tells the server no. What is
/// typed lives in the panel's state until Submit, and nothing here writes it anywhere. The
/// caller gives each request its own panel (`.id`), so a second question starts empty.
struct ElicitationPanel: View {
  let elicitation: Elicitation
  /// "1 of 3" when more than one waits.
  let position: (index: Int, count: Int)?
  let answer: (ElicitationAnswer) -> Void
  /// The panel takes the keys each time this changes: its first text field, else itself.
  /// Never on appearing, in its card or in the composer's place: a transcript row that changed
  /// the focus on appearing laid the transcript out again without end (d19c1fa).
  var focusRequest: Int?
  /// In the composer's place, whose band does not scroll: the fields scroll themselves there,
  /// so a long form keeps its buttons in view. In a transcript card they grow with the form,
  /// as `QuestionPanel`'s options do: a row that sized a scroll view of its own laid the
  /// transcript out again without end.
  var isDocked = false

  @State private var inputs: [String: ElicitationInput]
  /// The fields changed so far: only they say what is wrong with them.
  @State private var edited: Set<String> = []
  @FocusState private var focus: Focus?

  private enum Focus: Hashable {
    case panel
    case field(String)
  }

  init(
    elicitation: Elicitation, position: (index: Int, count: Int)?,
    answer: @escaping (ElicitationAnswer) -> Void, focusRequest: Int? = nil, isDocked: Bool = false
  ) {
    self.elicitation = elicitation
    self.position = position
    self.answer = answer
    self.focusRequest = focusRequest
    self.isDocked = isDocked
    if case .form(let form) = elicitation.content {
      _inputs = State(initialValue: form.initialInputs)
    } else {
      _inputs = State(initialValue: [:])
    }
  }

  /// "1 of 3", or nil while it waits alone.
  static func positionText(_ position: (index: Int, count: Int)?) -> String? {
    guard let position, position.count > 1 else { return nil }
    return String(localized: "\(position.index) of \(position.count)")
  }

  /// The server as the card names it.
  static func serverText(_ elicitation: Elicitation) -> String {
    elicitation.serverLabel.isEmpty ? String(localized: "An MCP server") : elicitation.serverLabel
  }

  /// The link's host, shown big so where it leads is read before it is opened.
  static func hostText(_ url: URL) -> String {
    url.host(percentEncoded: false) ?? url.absoluteString
  }

  /// The problems shown: those of the fields changed so far.
  static func shownProblems(_ problems: [String: String], edited: Set<String>) -> [String: String] {
    problems.filter { edited.contains($0.key) }
  }

  /// The first field typed in, which takes the keys.
  static func firstTypedField(_ content: Elicitation.Content) -> String? {
    guard case .form(let form) = content else { return nil }
    return form.fields.first { field in
      switch field.kind {
      case .text, .number: true
      case .flag, .choice, .choices: false
      }
    }?.key
  }

  /// `input` with `value` picked or not, for a field that takes several.
  static func picking(_ value: String, _ isOn: Bool, in input: ElicitationInput?)
    -> ElicitationInput
  {
    var picks: Set<String> = []
    if case .picks(let current) = input { picks = current }
    if isOn { picks.insert(value) } else { picks.remove(value) }
    return .picks(picks)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      switch elicitation.content {
      case .form(let form):
        if isDocked {
          ScrollView { fields(form).frame(maxWidth: .infinity, alignment: .leading) }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          fields(form)
        }
      case .url(let url):
        link(url)
      case .unsupported:
        Text("Drakar can't show this form.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      footer
    }
    .padding(12)
    .focusable()
    .focusEffectDisabled()
    .focused($focus, equals: .panel)
    // Here and not only on Decline's shortcut: the panel's own Esc comes before the session's,
    // which would interrupt the turn instead.
    .onKeyPress(.escape) {
      answer(.decline)
      return .handled
    }
    .onChange(of: focusRequest) {
      focus = Self.firstTypedField(elicitation.content).map(Focus.field) ?? .panel
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(Self.serverText(elicitation)) is asking you a question")
    .accessibilityIdentifier("elicitation.panel")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: "questionmark.bubble").foregroundStyle(.tint)
        Text(Self.serverText(elicitation))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        if let text = Self.positionText(position) {
          Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("elicitation.position")
        }
      }
      if !elicitation.message.isEmpty {
        Text(elicitation.message)
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      if let description = elicitation.description {
        Text(description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
  }

  // MARK: - A form

  private func fields(_ form: ElicitationForm) -> some View {
    let problems = Self.shownProblems(form.problems(in: inputs), edited: edited)
    return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
      ForEach(form.fields) { field in
        GridRow {
          if case .flag = field.kind {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
          } else {
            Text(field.title)
              .multilineTextAlignment(.trailing)
              .frame(maxWidth: 200, alignment: .trailing)
              .fixedSize(horizontal: false, vertical: true)
              .gridColumnAlignment(.trailing)
          }
          VStack(alignment: .leading, spacing: 3) {
            control(field)
            if let description = field.description, !description.isEmpty {
              Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = problems[field.key] {
              Text(problem)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("elicitation.problem.\(field.key)")
            }
          }
        }
      }
    }
    .frame(maxWidth: 640, alignment: .leading)
  }

  @ViewBuilder private func control(_ field: ElicitationField) -> some View {
    let placeholder =
      field.isRequired ? String(localized: "Required") : String(localized: "Optional")
    switch field.kind {
    case .text, .number:
      Group {
        if field.isSecret {
          SecureField(placeholder, text: text(field.key))
        } else {
          TextField(placeholder, text: text(field.key))
        }
      }
      .textFieldStyle(.roundedBorder)
      .focused($focus, equals: .field(field.key))
      .accessibilityLabel(field.title)
      .accessibilityIdentifier("elicitation.field.\(field.key)")
    case .flag:
      Toggle(field.title, isOn: flag(field.key))
        .accessibilityIdentifier("elicitation.field.\(field.key)")
    case .choice(let options):
      Picker(field.title, selection: choice(field.key)) {
        Text(field.isRequired ? String(localized: "Choose…") : String(localized: "None"))
          .tag(String?.none)
        ForEach(options, id: \.value) { option in
          Text(option.title).tag(String?.some(option.value))
        }
      }
      .labelsHidden()
      .fixedSize()
      .accessibilityIdentifier("elicitation.field.\(field.key)")
    case .choices(let options, _, _):
      VStack(alignment: .leading, spacing: 4) {
        ForEach(options, id: \.value) { option in
          Toggle(option.title, isOn: pick(option.value, in: field.key))
            .accessibilityIdentifier("elicitation.field.\(field.key).\(option.value)")
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(field.title)
      .accessibilityIdentifier("elicitation.field.\(field.key)")
    }
  }

  private func text(_ key: String) -> Binding<String> {
    Binding(
      get: {
        if case .text(let text) = inputs[key] { return text }
        return ""
      },
      set: {
        inputs[key] = .text($0)
        edited.insert(key)
      })
  }

  /// An optional flag left alone stays out of the inputs, so it is not sent.
  private func flag(_ key: String) -> Binding<Bool> {
    Binding(
      get: { inputs[key] == .flag(true) },
      set: {
        inputs[key] = .flag($0)
        edited.insert(key)
      })
  }

  private func choice(_ key: String) -> Binding<String?> {
    Binding(
      get: {
        if case .picks(let picks) = inputs[key] { return picks.first }
        return nil
      },
      set: {
        inputs[key] = $0.map { .picks([$0]) }
        edited.insert(key)
      })
  }

  private func pick(_ value: String, in key: String) -> Binding<Bool> {
    Binding(
      get: {
        if case .picks(let picks) = inputs[key] { return picks.contains(value) }
        return false
      },
      set: {
        inputs[key] = Self.picking(value, $0, in: inputs[key])
        edited.insert(key)
      })
  }

  // MARK: - A link

  private func link(_ url: URL) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(Self.hostText(url))
        .font(.title3.weight(.semibold))
        .accessibilityIdentifier("elicitation.host")
      Text(url.absoluteString)
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .accessibilityIdentifier("elicitation.url")
    }
  }

  // MARK: - The answer

  private var footer: some View {
    HStack {
      Text(hint).font(.caption).foregroundStyle(.tertiary)
      Spacer()
      Button("Decline") { answer(.decline) }
        .keyboardShortcut(.cancelAction)
        .help("Tell the server you won't answer")
        .accessibilityIdentifier("elicitation.decline")
      switch elicitation.content {
      case .form(let form):
        let content = form.content(from: inputs)
        Button("Submit") {
          if let content { answer(.accept(content)) }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(content == nil)
        .accessibilityIdentifier("elicitation.submit")
      case .url(let url):
        Button("Open in Browser") {
          answer(.accept(nil))
          NSWorkspace.shared.open(url)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .help(url.absoluteString)
        .accessibilityIdentifier("elicitation.open")
      case .unsupported:
        EmptyView()
      }
    }
  }

  private var hint: String {
    switch elicitation.content {
    case .form: String(localized: "⌘↩ to submit, Esc to decline")
    case .url: String(localized: "⌘↩ to open, Esc to decline")
    case .unsupported: String(localized: "Esc to decline")
    }
  }
}
