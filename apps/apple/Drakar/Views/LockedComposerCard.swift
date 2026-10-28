import AppKit
import SupportKitSettings
import SwiftUI

/// What stands where the composer would be while Drakar may not send work.
///
/// Armada's `LockedCard`, in the composer's place rather than the panel's: DIVERGES from
/// armada, whose card stands in for a session list its gate emptied, because Drakar's gate
/// refuses only what is sent next and everything else in the window still works. The draft
/// stays in `ProjectSession.draft`; this card never touches it, so a key entered brings the
/// composer back with the text as it was left.
///
/// The trial leads, and only until it has been used, for bastion's reason: somebody
/// reading this has just found the composer gone, and the useful offer is the one that
/// makes it work in the next ten seconds, not the one that opens a checkout. Once the
/// window has closed there is nothing to offer a second time, so the card says what to do
/// instead.
struct LockedComposerCard: View {
  /// A turn still running when the gate closed: Stop stays here, as the composer had it.
  let isRunning: Bool
  let stop: () -> Void
  private var monitor = EntitlementMonitor.shared
  @Environment(\.openSettings) private var openSettings

  init(isRunning: Bool, stop: @escaping () -> Void) {
    self.isRunning = isRunning
    self.stop = stop
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        Trial.hasRun ? "The trial has ended" : "Drakar needs a licence",
        systemImage: "exclamationmark.triangle.fill"
      )
      .foregroundStyle(.orange)
      .font(.headline)

      Text(
        Trial.hasRun
          ? "Sessions keep running and their questions can still be answered. Enter a key to send more, or quit and reopen Drakar for another trial."
          : "A \(Int(Trial.duration / 60))-minute trial runs everything, with your own `claude` and accounts, and no key."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      // A key that is present and refused says why. "No licence key" is the
      // ordinary state and the sentence above already covers it.
      if case .refused(let reason) = monitor.current, LicenseStore.raw != nil {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        if !Trial.hasRun {
          Button("Start a \(Int(Trial.duration / 60))-minute trial") { monitor.startTrial() }
            .buttonStyle(.glassProminent)
          Button("Enter a key…") { openLicence() }
            .buttonStyle(.glass)
        } else {
          Button("Enter a licence key…") { openLicence() }
            .buttonStyle(.glassProminent)
        }
        // Gated exactly as `LicensePane` gates the identical button.
        if monitor.isSelling {
          Button("Buy a licence…") { NSWorkspace.shared.open(LicenceLinks.buy) }
            .buttonStyle(.glass)
        }
        if isRunning {
          Spacer(minLength: 8)
          // DIVERGES from armada, which has no turn to stop: the composer's Stop and its ⌘.
          // go with the composer, and a running turn must stay stoppable (Esc stops it too).
          Button("Stop", systemImage: "stop.fill", action: stop)
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop the turn and what is queued (⌘.)")
            .accessibilityIdentifier("locked.stop")
        }
      }
      .controlSize(.small)
    }
    .frame(maxWidth: 820 - 32, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity)
    .accessibilityIdentifier("composer.locked")
  }

  private func openLicence() {
    Support.settings.select(.licence)
    openSettings()
  }
}
