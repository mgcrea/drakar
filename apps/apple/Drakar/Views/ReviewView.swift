import DrakarKit
import SwiftUI

/// The edits terminal sessions are waiting on, oldest first, each to accept or reject.
struct ReviewView: View {
  let bridge: IDEBridge

  var body: some View {
    Group {
      if bridge.pending.isEmpty {
        ContentUnavailableView(
          "Nothing to review", systemImage: "checkmark.circle",
          description: Text("Edits from Claude Code in a terminal appear here."))
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            ForEach(bridge.pending) { pendingDiff in
              PendingDiffCard(pendingDiff: pendingDiff, bridge: bridge)
            }
          }
          .padding(16)
        }
      }
    }
    .frame(minWidth: 520, minHeight: 320)
  }
}

private struct PendingDiffCard: View {
  let pendingDiff: IDEBridge.PendingDiff
  let bridge: IDEBridge

  private var fileURL: URL { URL(filePath: pendingDiff.diff.newFilePath) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(
            pendingDiff.change.isNewFile
              ? "Create \(fileURL.lastPathComponent)?" : "Change \(fileURL.lastPathComponent)?"
          )
          .font(.headline)
          Text(source)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Reject") { bridge.reject(pendingDiff) }
          .accessibilityIdentifier("review.reject")
        Button("Accept") { bridge.accept(pendingDiff) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(pendingDiff.id == bridge.pending.first?.id ? .defaultAction : nil)
          .accessibilityIdentifier("review.accept")
      }
      FileChangeView(change: pendingDiff.change)
        .environment(\.sessionFolder, fileURL.deletingLastPathComponent())
    }
    .padding(14)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
  }

  private var source: String {
    let folder = ContentView.abbreviated(fileURL.deletingLastPathComponent())
    if let pid = pendingDiff.claudePID {
      // String(pid): interpolating the number would group its digits ("17 591").
      return String(localized: "Claude Code in a terminal (pid \(String(pid))) · \(folder)")
    }
    return String(localized: "Claude Code in a terminal · \(folder)")
  }
}
