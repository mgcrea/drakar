import DrakarKit
import SwiftUI

// What the inspector's Session tab and the composer's context popover both show of a
// session's context, so that the two never tell it differently.

/// The command Settings runs before compacting, when the session's agent has it. Settings
/// names a Claude Code command; another agent runs it only when it lists one of that name,
/// and would otherwise get it as words for its model. Words that are no command go to any.
nonisolated enum CompactionFirst {
  static func command(setting: String, agent: AgentKind, commands: [SkillEntry]) -> String? {
    guard let first = CompactionRun(first: setting, idle: false).first else { return nil }
    if agent == .claude { return first }
    guard first.hasPrefix("/") else { return first }
    let name = first.dropFirst().prefix { !$0.isWhitespace }
    return commands.contains { $0.name == name } ? first : nil
  }

  /// What the Compact button says: the command run first, when there is one.
  static func title(first: String?) -> String {
    first.map { String(localized: "Run \($0), then Compact") } ?? String(localized: "Compact")
  }
}

/// The model, how much of the window is used, and a bar with the auto-compact point on it.
struct ContextHeadline: View {
  let gauge: ContextGauge?
  let modelID: String?
  let compactsAt: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let modelID {
        Text(ModelName.display(modelID))
          .foregroundStyle(.secondary)
          .help(modelID)
      }
      if let gauge {
        let used = SessionDetailsFormat.tokens(gauge.used)
        let limit = SessionDetailsFormat.tokens(gauge.window.limit)
        HStack(alignment: .firstTextBaseline) {
          Text("\(used) of \(limit)")
            .monospacedDigit()
            .contentTransition(.numericText())
          Spacer()
          Text(gauge.fraction, format: .percent.precision(.fractionLength(0)))
            .monospacedDigit()
            .foregroundStyle(gauge.level == .normal ? Color.secondary : tint(gauge.level))
        }
        ContextBar(fraction: gauge.fraction, tint: tint(gauge.level), mark: mark(gauge))
        if let compactsAt {
          Text("Compacts itself at \(SessionDetailsFormat.tokens(compactsAt))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        Text("No turns yet").foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
    .help(gauge?.window.source.explanation ?? "")
    .accessibilityElement(children: .combine)
  }

  private func mark(_ gauge: ContextGauge) -> Double? {
    compactsAt.map { Double($0) / Double(max(gauge.window.limit, 1)) }.flatMap {
      $0 < 1 ? $0 : nil
    }
  }

  private func tint(_ level: ContextGauge.Level) -> Color {
    switch level {
    case .normal: .accentColor
    case .high: .orange
    case .critical: .red
    }
  }
}

/// `61.5K`, as the sidebar gauge's tooltip writes a count.
enum SessionDetailsFormat {
  static func tokens(_ count: Int) -> String { count.formatted(.number.notation(.compactName)) }
}

/// The used share over the track, with a tick where auto-compact starts.
struct ContextBar: View {
  let fraction: Double
  let tint: Color
  let mark: Double?

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      Capsule()
        .fill(.quaternary)
        .overlay(alignment: .leading) {
          Capsule().fill(tint).frame(width: width * fraction)
        }
        .overlay(alignment: .leading) {
          if let mark {
            Rectangle()
              .fill(.secondary)
              .frame(width: 1.5, height: 10)
              .offset(x: width * mark)
              .help("Auto-compact starts here")
          }
        }
    }
    .frame(height: 6)
    .padding(.vertical, 2)
    .accessibilityHidden(true)
  }
}

/// Whether the prompt cache is warm, redrawn each minute as the footer's timer is.
struct PromptCacheRow: View {
  let cache: PromptCache

  var body: some View {
    TimelineView(.periodic(from: cache.anchor ?? .now, by: 60)) { context in
      let state = cache.state(at: context.date)
      LabeledContent("Prompt cache") {
        Text(Self.value(state, ttl: cache.ttl))
          .foregroundStyle(state == .unknown ? .tertiary : .secondary)
      }
      .help(state.help ?? "")
    }
  }

  private static func value(_ state: PromptCache.State, ttl: PromptCache.TTL?) -> String {
    switch state {
    case .unknown: String(localized: "Unknown")
    case .warm(let minutes):
      ttl == .oneHour
        ? String(localized: "Warm, \(minutes)m left of 1h")
        : String(localized: "Warm, \(minutes)m left of 5m")
    case .expired(let idle, _): String(localized: "Expired, idle \(PromptCache.idle(idle))")
    case .compacted: String(localized: "Cold since compaction")
    }
  }
}

/// What the composer's context popover needs of its window: the agent's commands as last
/// listed, a way to read them afresh, and the inspector's Session tab.
struct ContextPopoverActions {
  var commands: () -> [SkillEntry]
  var loadCommands: () -> Void
  var showDetails: () -> Void
}

/// The composer's cache timer and context ring as one pill, opening the popover on a click.
/// Without `actions` (a session another process runs, which Drakar cannot compact) they are
/// the labels alone.
struct ContextPill: View {
  let session: AgentSession
  let gauge: ContextGauge?
  var actions: ContextPopoverActions?
  @State private var isPresented = false

  var body: some View {
    if let actions {
      Button {
        isPresented.toggle()
      } label: {
        labels
      }
      .buttonStyle(PillButtonStyle(horizontalPadding: 6))
      .popover(isPresented: $isPresented) {
        ContextPopover(
          session: session, gauge: gauge, actions: actions, dismiss: { isPresented = false })
      }
      .accessibilityIdentifier("composer.context")
    } else {
      labels.font(.callout).foregroundStyle(.secondary)
    }
  }

  private var labels: some View {
    HStack(spacing: 6) {
      if let cache = SessionPills.promptCache(of: session) {
        PromptCacheLabel(cache: cache)
      }
      if let gauge {
        ContextUsageLabel(gauge: gauge, compactsAt: session.reportedContext?.autoCompactThreshold)
      }
    }
  }
}

/// How full the context is, whether the cache is warm, and Compact, without opening the
/// inspector; Show Details opens it for the breakdown.
struct ContextPopover: View {
  let session: AgentSession
  let gauge: ContextGauge?
  let actions: ContextPopoverActions
  let dismiss: () -> Void
  @AppStorage(PreferenceKey.compactionFirst) private var compactionFirst = ""

  private var modelID: String? {
    session.appliedModel
      ?? ModelName.current(
        initModel: session.status.session?.model, messageModel: session.status.contextModelID,
        attachmentModel: nil)
  }

  var body: some View {
    let first = CompactionFirst.command(
      setting: compactionFirst, agent: session.agent, commands: actions.commands())
    VStack(alignment: .leading, spacing: 10) {
      ContextHeadline(
        gauge: gauge, modelID: modelID,
        compactsAt: session.reportedContext?.autoCompactThreshold)
      if session.features.showsPromptCache {
        PromptCacheRow(cache: session.status.promptCache)
      }
      HStack {
        Button("Show Details") {
          actions.showDetails()
          dismiss()
        }
        .buttonStyle(.link)
        .accessibilityIdentifier("contextPopover.details")
        Spacer()
        if !session.isReadOnly {
          Button(CompactionFirst.title(first: first)) {
            session.compact(runsFirst: first != nil)
            dismiss()
          }
          .disabled(!session.canCompact)
          .help(session.canCompact ? "" : String(localized: "Compacts between turns"))
          .accessibilityIdentifier("contextPopover.compact")
        }
      }
    }
    .padding(14)
    .frame(width: 290)
    .onAppear(perform: actions.loadCommands)
  }
}
