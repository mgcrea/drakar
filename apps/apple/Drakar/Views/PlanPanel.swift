import DrakarKit
import SwiftUI

/// `ExitPlanMode`, answered in place of the composer as the extension answers it: the plan,
/// then its three choices. Run it with edits accepted, run it approving each edit, or keep
/// planning, with what to change or without, which ends the turn. 1, 2 and 3 pick a choice;
/// Return in the field sends the feedback; Esc keeps planning.
struct PlanPanel: View {
  let plan: String
  /// The model takes auto mode, so the first choice runs the plan in it rather than in
  /// acceptEdits, as the extension offers it.
  let offersAutoMode: Bool
  let approve: (_ editsManually: Bool) -> Void
  let keepPlanning: (_ feedback: String) -> Void

  @State private var feedback = ""
  @FocusState private var focus: Focus?

  private enum Focus: Hashable { case panel, feedback }

  private var hasFeedback: Bool {
    !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Claude's plan", systemImage: "list.bullet.clipboard")
        .font(.headline)
      ScrollView {
        MarkdownView(text: plan)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 320)
      .fixedSize(horizontal: false, vertical: true)
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
      .accessibilityIdentifier("plan.text")
      Text("Accept this plan?").font(.callout.weight(.semibold))
      VStack(alignment: .leading, spacing: 6) {
        choice(
          1,
          offersAutoMode
            ? String(localized: "Yes, and use auto mode")
            : String(localized: "Yes, and auto-accept edits"),
          id: "plan.approve", prominent: !hasFeedback
        ) { approve(false) }
        choice(2, String(localized: "Yes, and approve edits manually"), id: "plan.approveManually") {
          approve(true)
        }
        HStack(spacing: 8) {
          choice(
            3,
            hasFeedback
              ? String(localized: "Send feedback and keep planning")
              : String(localized: "No, keep planning"),
            id: "plan.keepPlanning", prominent: hasFeedback
          ) { keepPlanning(feedback) }
          TextField("Tell Claude what to change", text: $feedback, axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .focused($focus, equals: .feedback)
            // Empty, Return would end the turn by accident; that takes 3 or the button.
            .onSubmit { if hasFeedback { keepPlanning(feedback) } }
            .accessibilityIdentifier("plan.feedback")
        }
      }
      Text("1, 2 or 3 to choose · Esc to keep planning")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(12)
    .focusable()
    .focusEffectDisabled()
    .focused($focus, equals: .panel)
    .onAppear { focus = .panel }
    .onKeyPress(characters: .decimalDigits, phases: .down) { press in
      guard focus != .feedback else { return .ignored }
      switch press.characters {
      case "1": approve(false)
      case "2": approve(true)
      case "3": keepPlanning(feedback)
      default: return .ignored
      }
      return .handled
    }
    .onKeyPress(.escape) {
      // In the field, Esc backs out of the note, never sends it.
      if focus == .feedback {
        feedback = ""
        focus = .panel
      } else {
        keepPlanning("")
      }
      return .handled
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Claude has a plan for you to review")
    .accessibilityIdentifier("plan.panel")
  }

  private func choice(
    _ number: Int, _ title: String, id: String, prominent: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text("\(number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        Text(title)
      }
    }
    .buttonStyle(.bordered)
    .tint(prominent ? .accentColor : nil)
    .accessibilityIdentifier(id)
  }
}

#Preview {
  PlanPanel(
    plan: "# Add hello.txt\n\n## Steps\n1. Check it is not there.\n2. Write it.",
    offersAutoMode: false, approve: { _ in }, keepPlanning: { _ in }
  )
  .frame(width: 560)
}
