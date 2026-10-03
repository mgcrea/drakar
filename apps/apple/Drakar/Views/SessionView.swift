import DrakarKit
import SwiftUI

/// The transcript, what stopped it if anything did, the composer and the footer.
struct SessionView: View {
  let session: ClaudeSession
  let workspace: Workspace

  var body: some View {
    VStack(spacing: 0) {
      TranscriptView(transcript: session.transcript)
      if let problem {
        ProblemBanner(message: problem, diagnostics: session.diagnostics)
      }
      Divider()
      ComposerView(
        canSend: session.canSend, isRunning: session.transcript.isRunning,
        context: workspace.selection, pinned: workspace.pinned,
        unpin: { selection in workspace.pinned.removeAll { $0 == selection } },
        send: { text, context in
          session.send(text, context: context)
          workspace.pinned = []
        },
        stop: session.interrupt)
      SessionFooter(session: session)
    }
    .sheet(item: pendingPermission) { pending in
      PermissionSheet(pending: pending) { decision in session.answer(pending, decision) }
    }
    .environment(\.sessionFolder, session.folder)
    .environment(\.openInEditor, OpenInEditorAction(workspace: workspace))
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
    case .exited: String(localized: "The session has ended.")
    case .idle, .starting, .ready: nil
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

private struct SessionFooter: View {
  let session: ClaudeSession

  var body: some View {
    HStack(spacing: 12) {
      status
      Spacer()
      if let model = session.transcript.session?.model {
        Text(model)
      }
      if let version = session.transcript.session?.claudeCodeVersion {
        Text("Claude Code \(version)")
          .help(session.executable?.path(percentEncoded: false) ?? "")
      }
      if let cost = session.transcript.lastResult?.totalCostUSD {
        Text(cost, format: .currency(code: "USD").precision(.fractionLength(4)))
          .monospacedDigit()
          .help("Cost reported by the last turn")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  @ViewBuilder private var status: some View {
    switch session.phase {
    case .idle, .starting:
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
