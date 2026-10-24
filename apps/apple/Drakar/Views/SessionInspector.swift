import AppKit
import DrakarKit
import SwiftUI

/// The inspector's Session tab: how full the selected session's context is and what fills
/// it, what its newest request cost in tokens, and what it runs on.
///
/// The headline is the sidebar gauge's figure, from the API's own usage, so the two never
/// disagree. The breakdown is Claude Code's `/context`, asked after each turn of a process
/// Drakar runs: its own count, with its own total, and shown as that rather than subtracted
/// from the headline.
struct SessionInspector: View {
  let project: Project

  var body: some View {
    if let item = project.selected {
      SessionDetails(item: item)
    } else {
      ContentUnavailableView(
        "No Session", systemImage: "info.circle",
        description: Text("Select a session to see its context."))
    }
  }
}

private struct SessionDetails: View {
  let item: ProjectSession

  private var session: AgentSession { item.session }
  private var transcript: Transcript { session.transcript }

  private var gauge: ContextGauge? {
    item.gauge(
      accountModel: session.resuming.flatMap { SessionMonitor.shared.accountModel(for: $0.account) }
    )
  }

  /// The newest request's tokens: the live transcript's, else the row's summary of the file.
  private var usage: TokenUsage? {
    transcript.contextUsage ?? (session.hasLoadedHistory ? nil : item.preview?.context?.usage)
  }

  private var modelID: String? {
    session.appliedModel
      ?? ModelName.current(
        initModel: transcript.session?.model,
        messageModel: transcript.contextModelID ?? item.preview?.context?.modelID,
        attachmentModel: item.preview?.modelID)
  }

  var body: some View {
    let reply = session.reportedContext
    Form {
      Section("Context") {
        ContextHeadline(gauge: gauge, modelID: modelID, compactsAt: reply?.autoCompactThreshold)
      }
      Section {
        if let reply {
          ForEach(reply.categories, id: \.name) { category in
            if category.name == "Memory files", !reply.memoryFiles.isEmpty {
              MemoryFilesRow(category: category, files: reply.memoryFiles, limit: reply.maxTokens)
            } else {
              TokenRow(name: category.name, tokens: category.tokens, limit: reply.maxTokens)
            }
          }
          TokenRow(
            name: String(localized: "Free space"),
            tokens: max(reply.maxTokens - reply.totalTokens, 0), limit: reply.maxTokens
          )
          .foregroundStyle(.secondary)
        }
      } header: {
        Text("What Fills It")
      } footer: {
        Text(breakdownNote(reply))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let usage {
        Section("Newest Request") {
          LabeledContent("Input", value: SessionDetailsFormat.tokens(usage.input))
          LabeledContent(
            "Written to cache", value: SessionDetailsFormat.tokens(usage.cacheCreation))
          LabeledContent("Read from cache", value: SessionDetailsFormat.tokens(usage.cacheRead))
          LabeledContent("Output", value: SessionDetailsFormat.tokens(usage.output))
          if session.features.showsPromptCache {
            PromptCacheRow(cache: transcript.promptCache)
          }
        }
        .monospacedDigit()
      }
      Section("Session") {
        details
      }
    }
    .formStyle(.grouped)
    .accessibilityIdentifier("inspector.session")
  }

  @ViewBuilder private var details: some View {
    LabeledContent("Agent") {
      if let version = transcript.session?.agentVersion ?? transcript.writerVersion {
        Text("\(session.agent.name) \(version)")
      } else {
        Text(session.agent.name)
      }
    }
    if let modelID {
      LabeledContent("Model") { Text(ModelName.display(modelID)).help(modelID) }
    }
    if let mode = session.isProcessRunning
      ? session.shownMode : transcript.historyPermissionMode
    {
      LabeledContent("Mode", value: PermissionMode.title(of: mode))
    }
    if let effort = session.shownEffort ?? transcript.historyEffort {
      LabeledContent("Effort", value: EffortLevel.title(of: effort))
    }
    if let account = session.effectiveAccount {
      LabeledContent("Account") {
        Text(AccountStore.shared.profile(for: account).name)
          .help(ContentView.abbreviated(account.directory))
      }
    }
    if let turn = transcript.lastTurn {
      if let cost = turn.costUSD {
        let billing = Billing(apiKeySource: transcript.session?.apiKeySource)
        let amount = cost.formatted(.currency(code: "USD").precision(.fractionLength(4)))
        LabeledContent("Last turn cost") {
          Text(billing == .subscription ? "≈ \(amount)" : amount)
            .monospacedDigit()
            .help(
              billing == .subscription
                ? "API-equivalent estimate from token counts. Your subscription is not billed per token."
                : "Billed to your API key")
        }
      }
      if let ms = turn.durationMS {
        LabeledContent(
          "Last turn took",
          value: Duration.milliseconds(ms).formatted(.units(allowed: [.hours, .minutes, .seconds])))
      }
    }
    if let id = session.sessionID {
      LabeledContent("ID") {
        HStack(spacing: 4) {
          Text(id)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
          Button("Copy ID", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(id, forType: .string)
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help("Copy the session ID")
        }
      }
    }
    if let file = session.resuming?.file {
      LabeledContent("Transcript") {
        Button("Show in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: file)])
        }
        .buttonStyle(.link)
        .help(ContentView.abbreviated(URL(filePath: file)))
      }
    }
  }

  private func breakdownNote(_ reply: ContextUsageReply?) -> String {
    if let reply {
      return String(
        localized:
          "As Claude Code's /context counted it after the last turn: \(SessionDetailsFormat.tokens(reply.totalTokens)) in all. Its count is its own, so it can differ a little from the figure above."
      )
    }
    if session.agent == .codex {
      return String(localized: "Codex does not say what fills its context.")
    }
    if session.isReadOnly {
      return String(
        localized: "Another process runs this session; only Drakar's own sessions report this.")
    }
    return String(localized: "Claude Code reports this after each turn Drakar runs.")
  }
}

/// The model, how much of the window is used, and a bar with the auto-compact point on it.
private struct ContextHeadline: View {
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
    .accessibilityIdentifier("inspector.session.context")
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
private enum SessionDetailsFormat {
  static func tokens(_ count: Int) -> String { count.formatted(.number.notation(.compactName)) }
}

/// The used share over the track, with a tick where auto-compact starts.
private struct ContextBar: View {
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

/// A category: its name, its tokens, and its share of the window.
private struct TokenRow: View {
  let name: String
  let tokens: Int
  let limit: Int

  var body: some View {
    LabeledContent(name) {
      HStack(spacing: 6) {
        Text(SessionDetailsFormat.tokens(tokens))
        Text(Double(tokens) / Double(max(limit, 1)), format: .percent.precision(.fractionLength(1)))
          .foregroundStyle(.secondary)
          .frame(minWidth: 40, alignment: .trailing)
      }
      .monospacedDigit()
    }
  }
}

/// "Memory files", folding out to each file by its path: the part of the prefix someone can
/// go and shorten.
private struct MemoryFilesRow: View {
  let category: ContextUsageReply.Category
  let files: [ContextUsageReply.MemoryFile]
  let limit: Int
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      ForEach(files, id: \.path) { file in
        let url = URL(filePath: file.path)
        LabeledContent {
          Text(SessionDetailsFormat.tokens(file.tokens)).monospacedDigit()
        } label: {
          Text(ContentView.abbreviated(url))
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.head)
        }
        .help([file.type, file.path].compactMap { $0 }.joined(separator: " · "))
        .contextMenu {
          Button("Open") { NSWorkspace.shared.open(url) }
          Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
      }
    } label: {
      TokenRow(name: category.name, tokens: category.tokens, limit: limit)
    }
  }
}

/// Whether the prompt cache is warm, redrawn each minute as the footer's timer is.
private struct PromptCacheRow: View {
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
