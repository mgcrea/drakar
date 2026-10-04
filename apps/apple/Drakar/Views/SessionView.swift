import DrakarKit
import SwiftUI

/// The transcript, what stopped it if anything did, the composer and the footer.
struct SessionView: View {
  @Bindable var item: ProjectSession
  let project: Project
  /// Read only to redraw the footer's account when a pick or the Settings default changes.
  @AppStorage(PreferenceKey.accountForFolder) private var picks = ""
  @AppStorage(PreferenceKey.newSessionAccount) private var settingsAccount = ""

  private var session: ClaudeSession { item.session }
  private var workspace: Workspace { project.workspace }

  var body: some View {
    VStack(spacing: 0) {
      TranscriptView(transcript: session.transcript, anchor: $item.scrollAnchor)
      if let problem {
        ProblemBanner(message: problem, diagnostics: session.diagnostics)
      }
      Divider()
      if session.isReadOnly {
        ReadOnlyBanner(host: host) { project.fork(item) }
      } else {
        ComposerView(
          text: $item.draft, canSend: session.canSend, isRunning: session.transcript.isRunning,
          context: workspace.selection, pinned: workspace.pinned,
          unpin: { selection in workspace.pinned.removeAll { $0 == selection } },
          send: { text, context in
            project.takeOver(item)
            session.send(text, context: context)
            workspace.pinned = []
          },
          stop: session.interrupt,
          sessionFolder: session.folder, projectFolder: project.folder,
          takesFocus: project.focusesComposer)
      }
      let _ = (picks, settingsAccount)
      SessionFooter(
        session: session, windowAccount: AccountStore.shared.windowAccount(for: project.folder))
    }
    .sheet(item: pendingPermission) { pending in
      if pending.request.isChoice {
        ChoiceSheet(pending: pending) { decision in session.answer(pending, decision) }
      } else {
        PermissionSheet(pending: pending) { decision in session.answer(pending, decision) }
      }
    }
    .environment(\.sessionFolder, session.folder)
    .environment(\.openInEditor, OpenInEditorAction(workspace: workspace))
  }

  /// Where the session is open, from the registry, for the banner.
  private var host: String {
    guard let id = item.sessionID,
      let summary = SessionMonitor.shared.all.first(where: { $0.sessionID == id })
    else { return String(localized: "another app") }
    return SessionMonitor.shared.host(of: summary, excluding: project)
  }

  /// The first request waiting; answering it shows the next. Never dismissed except by
  /// answering, because a request left unanswered stalls the turn forever.
  private var pendingPermission: Binding<Transcript.PendingPermission?> {
    Binding(get: { session.transcript.pendingPermissions.first }, set: { _ in })
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
/// transcript would interleave its history.
private struct ReadOnlyBanner: View {
  let host: String
  let fork: () -> Void

  var body: some View {
    HStack {
      Label("Live in \(host). Its transcript follows here.", systemImage: "eye")
        .foregroundStyle(.secondary)
      Spacer()
      Button("Fork a Copy", action: fork)
        .help("Continue a copy under a new id, leaving the original where it is.")
        .accessibilityIdentifier("session.fork")
    }
    .padding(12)
  }
}

/// The CLI's version, in orange outside the range Drakar was tested with: the stream
/// protocol is undocumented, and a newer CLI can change it under the app.
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
  let session: ClaudeSession
  /// The account new sessions in the window start under.
  let windowAccount: ClaudeAccount

  var body: some View {
    HStack(spacing: 12) {
      status
      Spacer()
      if let model = session.transcript.session?.model {
        Text(model)
      }
      if let account = session.effectiveAccount, account.key != windowAccount.key {
        Label(AccountStore.shared.profile(for: account).name, systemImage: "person.crop.circle")
          .help("Runs under the account in \(ContentView.abbreviated(account.directory))")
      }
      if let version = session.transcript.session?.claudeCodeVersion {
        VersionLabel(version: version, executable: session.executable)
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

  @ViewBuilder private var status: some View {
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
