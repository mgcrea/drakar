import DrakarKit
import SwiftUI

/// The transcript, what stopped it if anything did, the composer and the footer.
struct SessionView: View {
  @Bindable var item: ProjectSession
  let project: Project
  /// Read only to redraw the footer's account when a pick or the Settings default changes.
  @AppStorage(PreferenceKey.accountForFolder) private var picks = ""
  @AppStorage(PreferenceKey.newSessionAccount) private var settingsAccount = ""

  /// How far above the bottom bar the transcript starts fading out.
  private static let fade: CGFloat = 24

  private var session: ClaudeSession { item.session }
  private var workspace: Workspace { project.workspace }

  /// The account the session runs, or will start, under.
  private var account: ClaudeAccount {
    session.effectiveAccount ?? AccountStore.shared.windowAccount(for: project.folder)
  }

  var body: some View {
    TranscriptView(transcript: session.transcript, anchor: $item.scrollAnchor)
      // Below the transcript's end, not after it: the history scrolls on under the composer
      // to the window's edge, and the scroll view keeps room for it as it grows. An inset and
      // not a `safeAreaBar`, whose scroll edge effect on the Mac is a band across the pane,
      // whatever its style, that put the card back in a tray.
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 0) {
          if let problem {
            Docked { ProblemBanner(message: problem, diagnostics: session.diagnostics) }
          }
          if session.isReadOnly {
            Docked {
              ReadOnlyBanner(
                host: host, fork: { project.fork(item) },
                moveHere: elsewhereSummary.flatMap { summary in
                  summary.live == nil
                    ? nil
                    : (Project.canMoveHere(summary), { MoveHere.confirm(summary, into: project) })
                })
            }
          } else if let choice = pendingChoice {
            Docked {
              QuestionPanel(
                questions: UserQuestion.list(choice.request.input),
                answer: { answers in
                  session.answer(
                    choice,
                    .allow(
                      updatedInput: UserQuestion.answering(choice.request.input, with: answers)))
                },
                skip: { session.answer(choice, .deny(message: UserQuestion.declinedMessage)) }
              )
              .id(choice.id)
            }
          } else if let earlier = session.earlierQuestion {
            Docked {
              QuestionPanel(
                questions: UserQuestion.list(earlier.input),
                answer: { answers in
                  project.takeOver(item)
                  session.answerEarlierQuestion(answers)
                },
                skip: session.dismissEarlierQuestion
              )
              .id(earlier.id)
            }
          } else {
            ComposerView(
              text: $item.draft, canSend: session.canSend,
              isRunning: session.transcript.isRunning,
              context: workspace.selection, pinned: workspace.pinned,
              unpin: { selection in workspace.pinned.removeAll { $0 == selection } },
              send: { text, context in
                project.takeOver(item)
                session.send(text, context: context)
                workspace.pinned = []
              },
              stop: session.interrupt,
              sessionFolder: session.folder, projectFolder: project.folder,
              takesFocus: project.focusesComposer,
              hint: item.composerHint, focusRequest: item.focusRequest,
              focused: { workspace.focusedPane = .composer },
              pills: SessionPills(session: session, folder: project.folder, account: account),
              cycleMode: { SessionPills.cycle(session, account: account) })
          }
          let _ = (picks, settingsAccount)
          SessionFooter(
            item: item, windowAccount: AccountStore.shared.windowAccount(for: project.folder),
            elsewhere: session.isReadOnly ? elsewhere : nil)
        }
        // What scrolls under fades out above the card, and is gone by the footer's line.
        .background {
          Rectangle()
            .fill(.background)
            .mask(
              LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.45)],
                startPoint: .top, endPoint: .bottom)
            )
            .padding(.top, -Self.fade)
            .allowsHitTesting(false)
        }
      }
      .sheet(item: pendingPermission) { pending in
        PermissionSheet(pending: pending) { decision in session.answer(pending, decision) }
      }
      .environment(\.sessionFolder, session.folder)
      .environment(\.openInEditor, OpenInEditorAction(workspace: workspace))
  }

  private var elsewhereSummary: SessionSummary? {
    guard let id = item.sessionID else { return nil }
    return SessionMonitor.shared.all.first { $0.sessionID == id }
  }

  /// Where the session is open, from the registry, for the banner.
  private var host: String { elsewhere.host }

  /// The process that has the session open, from its own record, and where it runs.
  private var elsewhere: (status: ElsewhereStatus, host: String) {
    guard let summary = elsewhereSummary else { return (.open, String(localized: "another app")) }
    return (
      ElsewhereStatus(summary.live), SessionMonitor.shared.host(of: summary, excluding: project)
    )
  }

  /// The first request waiting for a permission; answering it shows the next. Never
  /// dismissed except by answering, because a request left unanswered stalls the turn
  /// forever. A question is answered in `QuestionPanel` instead, below the transcript.
  private var pendingPermission: Binding<Transcript.PendingPermission?> {
    Binding(
      get: { session.transcript.pendingPermissions.first { !$0.request.isChoice } },
      set: { _ in })
  }

  /// The first `AskUserQuestion` waiting, answered in place of the composer.
  private var pendingChoice: Transcript.PendingPermission? {
    session.transcript.pendingPermissions.first { $0.request.isChoice }
  }

  private var problem: String? {
    switch session.phase {
    case .failed(let message): message
    case .exited(let status) where status != 0:
      String(localized: "Claude Code exited with status \(status).")
    case .idle, .starting, .ready, .exited: nil
    }
  }
}

/// A panel in the composer's place, or above it, that stays a band across the pane as before
/// the composer floated: a question's options and a banner's text read on the window's
/// background, not on the transcript scrolling under it.
private struct Docked<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      Divider()
      content.background(.background)
    }
  }
}

private struct ProblemBanner: View {
  let message: String
  let diagnostics: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      if !diagnostics.isEmpty {
        Text(diagnostics.suffix(600))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(6)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.orange.opacity(0.08))
  }
}

/// In place of the composer while another process has the session open: two writers on one
/// transcript would interleave its history. Another app's session can move here between
/// turns (`moveHere`: whether it can now, and the move).
private struct ReadOnlyBanner: View {
  let host: String
  let fork: () -> Void
  let moveHere: (enabled: Bool, move: () -> Void)?

  var body: some View {
    HStack {
      Label("Live in \(host). Its transcript follows here.", systemImage: "eye")
        .foregroundStyle(.secondary)
      Spacer()
      Button("Fork a Copy", action: fork)
        .help("Continue a copy under a new id, leaving the original where it is.")
        .accessibilityIdentifier("session.fork")
      if let moveHere {
        Button("Move Here…", action: moveHere.move)
          .disabled(!moveHere.enabled)
          .help(
            moveHere.enabled
              ? "End it in \(host) and go on with it in this window."
              : "It can move here once its turn in \(host) ends."
          )
          .accessibilityIdentifier("session.moveHere")
      }
    }
    .padding(12)
  }
}

/// The CLI's version, in orange outside the range Drakar was tested with: the stream
/// protocol is undocumented, and a newer CLI can change it under the app.
/// A session another process runs, as its footer says it: from that process's own record in
/// the account's `sessions` folder.
enum ElsewhereStatus: Equatable {
  case working
  case ready
  /// On a permission prompt or a question: `waitingFor` says which.
  case waiting(String?)
  /// No record, or a status this Drakar does not know.
  case open

  init(_ live: LiveSession?) {
    self =
      switch live?.status {
      case "busy": .working
      case "idle": .ready
      case "waiting": .waiting(live?.waitingFor)
      default: .open
      }
  }

  func text(in host: String) -> String {
    switch self {
    case .working: String(localized: "Working in \(host)")
    case .ready: String(localized: "Ready in \(host)")
    case .waiting: String(localized: "Waiting in \(host)")
    case .open: String(localized: "Open in \(host)")
    }
  }
}

private struct VersionLabel: View {
  let version: String
  let executable: URL?

  var body: some View {
    let path = executable.map { ContentView.abbreviated($0) } ?? ""
    let tested = ClaudeVersion.tested
    let range = "\(tested.lowerBound.description) to \(tested.upperBound.description)"
    switch ClaudeVersion(version)?.drift {
    case nil:
      Text("Claude Code \(version)").help(path)
    case .older?:
      Label("Claude Code \(version)", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .help(
          "Older than the versions Drakar was tested with (\(range)): it may not understand everything Drakar sends. Pick another in Settings. \(path)"
        )
    case .newer?:
      Label("Claude Code \(version)", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .help(
          "Newer than the versions Drakar was tested with (\(range)): some of what it says may not show. \(path)"
        )
    }
  }
}

private struct SessionFooter: View {
  let item: ProjectSession
  /// The account new sessions in the window start under.
  let windowAccount: ClaudeAccount
  /// Set for a session another process runs: its state comes from there.
  let elsewhere: (status: ElsewhereStatus, host: String)?

  private var session: ClaudeSession { item.session }

  /// Known before the process starts: the newest message's model, or the one the sidebar row
  /// read from the file.
  private var modelID: String? {
    ModelName.current(
      initModel: session.transcript.session?.model,
      messageModel: session.transcript.contextModelID ?? item.preview?.context?.modelID,
      attachmentModel: item.preview?.modelID)
  }

  var body: some View {
    HStack(spacing: 12) {
      status
      Spacer()
      if elsewhere != nil {
        if let mode = session.transcript.historyPermissionMode {
          Text(PermissionMode.title(of: mode))
        }
        if let modelID {
          Text(ModelName.display(modelID)).help(modelID)
        }
      }
      account
      if let version = session.transcript.session?.claudeCodeVersion {
        VersionLabel(version: version, executable: session.executable)
      } else if let version = session.transcript.writerVersion {
        // Not Drakar's process: how its version compares to Drakar's is not this session's.
        Text("Claude Code \(version)").help("The version that last wrote this session")
      }
      if let cost = session.transcript.lastResult?.totalCostUSD {
        let billing = Billing(apiKeySource: session.transcript.session?.apiKeySource)
        let amount = cost.formatted(.currency(code: "USD").precision(.fractionLength(4)))
        Text(billing == .subscription ? "≈ \(amount)" : amount)
          .monospacedDigit()
          .help(
            billing == .subscription
              ? "API-equivalent estimate from token counts. Your subscription is not billed per token."
              : "Billed to your API key")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  /// The session's account, or for one not started yet the account it will start under;
  /// marked as its sidebar row is when it is not the window's.
  @ViewBuilder private var account: some View {
    let account = session.effectiveAccount ?? windowAccount
    let profile = AccountStore.shared.profile(for: account)
    let label = Label(
      profile.plan.map { "\(profile.name) (\($0))" } ?? profile.name,
      systemImage: "person.crop.circle")
    let help =
      session.effectiveAccount == nil
      ? String(
        localized: "Starts under the account in \(ContentView.abbreviated(account.directory))")
      : String(localized: "Runs under the account in \(ContentView.abbreviated(account.directory))")
    if account.key == windowAccount.key {
      label.help(help)
    } else {
      label
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(.quaternary))
        .help(help + " " + String(localized: "New sessions in this window start under another."))
    }
  }

  @ViewBuilder private var status: some View {
    if let (status, host) = elsewhere {
      let text = status.text(in: host)
      switch status {
      case .working: Label(text, systemImage: "circle.fill").foregroundStyle(.blue)
      case .ready: Label(text, systemImage: "circle.fill").foregroundStyle(.green)
      case .waiting(let what):
        Label(text, systemImage: "circle.fill").foregroundStyle(.orange)
          .help(what.map { String(localized: "Waiting for: \($0)") } ?? "")
      case .open: Label(text, systemImage: "circle")
      }
    } else {
      ownStatus
    }
  }

  @ViewBuilder private var ownStatus: some View {
    switch session.phase {
    case .idle:
      Label("Not started", systemImage: "circle.dotted")
    case .starting:
      Label("Starting…", systemImage: "circle.dotted")
    case .ready where session.transcript.isRunning:
      Label("Working", systemImage: "circle.fill").foregroundStyle(.blue)
    case .ready:
      Label("Ready", systemImage: "circle.fill").foregroundStyle(.green)
    case .failed, .exited:
      Label("Stopped", systemImage: "circle")
    }
  }
}
