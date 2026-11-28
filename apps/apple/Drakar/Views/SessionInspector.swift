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
      SessionDetails(item: item, commands: project.slashCommands(for: item.session))
        // Whether the agent has the command run before compacting.
        .task(id: ObjectIdentifier(item.session)) { project.loadSlashCommands(for: item.session) }
    } else {
      ContentUnavailableView(
        "No Session", systemImage: "info.circle",
        description: Text("Select a session to see its context."))
    }
  }
}

private struct SessionDetails: View {
  let item: ProjectSession
  /// The agent's slash commands, as last listed.
  let commands: [SkillEntry]
  @AppStorage(PreferenceKey.compactionFirst) private var compactionFirst = ""

  private var session: AgentSession { item.session }

  /// The command run before compacting, when this agent has it.
  private var compactionFirstCommand: String? {
    CompactionFirst.command(setting: compactionFirst, agent: session.agent, commands: commands)
  }

  /// Only what `status` carries: the tab is not redrawn as text streams in.
  private var transcript: Transcript.Status { session.status }

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
          .accessibilityIdentifier("inspector.session.context")
        if !session.isReadOnly {
          Button(CompactionFirst.title(first: compactionFirstCommand)) {
            session.compact(runsFirst: compactionFirstCommand != nil)
          }
          .disabled(!session.canCompact)
          .accessibilityIdentifier("inspector.compact")
        }
      }
      Section {
        if let reply {
          ForEach(reply.categories, id: \.name) { category in
            if category.name == "Memory files", !reply.memoryFiles.isEmpty {
              MemoryFilesRow(
                category: category, files: reply.memoryFiles, limit: reply.maxTokens,
                opensFiles: !session.isOnRunner)
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
    if let runner = session.runnerName {
      // The runner's, by its directory there: no profile of this Mac's at the same path.
      LabeledContent("Runs on", value: runner)
      if let account = session.account {
        LabeledContent("Account") {
          Text(account.directory.path(percentEncoded: false))
            .lineLimit(1)
            .truncationMode(.head)
            .textSelection(.enabled)
        }
      }
    } else if let account = session.effectiveAccount {
      LabeledContent("Account") {
        Text(AccountStore.shared.profile(for: account).name)
          .help(ContentView.abbreviated(account.directory))
      }
    }
    if let cost = transcript.costUSD {
      LabeledContent("Cost") {
        CostText(cost, apiKeySource: transcript.session?.apiKeySource, fractionDigits: 4)
      }
    }
    if let turn = transcript.lastTurn {
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
    if let file = session.resuming?.file, !session.isOnRunner {
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
    if session.agent == .agy || session.agent == .grok {
      return String(localized: "\(session.agent.name) does not say what fills its context.")
    }
    if session.isReadOnly {
      return String(
        localized: "Another process runs this session; only Drakar's own sessions report this.")
    }
    return String(localized: "Claude Code reports this after each turn Drakar runs.")
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
  /// False for a runner session's, whose files are there: their paths show as text.
  var opensFiles = true
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
          if opensFiles {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          }
        }
      }
    } label: {
      TokenRow(name: category.name, tokens: category.tokens, limit: limit)
    }
  }
}
