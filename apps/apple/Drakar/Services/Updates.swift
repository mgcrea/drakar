import AppKit
import Observation
import Sparkle
import SwiftUI

/// The update check: the one connection Drakar makes of its own, and the single named
/// exception to the claim `scripts/audit-network.sh` checks. Everything else that reaches
/// the network is the `claude` or `codex` the person installed.
///
/// Everything here is built around one property: **a Drakar nobody has said yes to has
/// never resolved a name.** That is stronger than "the checkbox is off", and it is why
/// `SPUStandardUpdaterController` is not a stored property built at launch but a `nil` that
/// stays `nil`. Sparkle starts a scheduler the moment it is constructed, so constructing it
/// and then declining to check would leave the claim resting on a flag rather than on the
/// absence of the machinery.
///
/// Armada's controller, copied, less what Drakar does not have: no screenshot guard (there
/// is no capture mode), and no `DockPresence` to keep in step with Sparkle's windows, since
/// Drakar is a regular app whose Dock icon and menus are always there. Like armada, it has
/// no child processes of its own to stop before a relaunch: the sessions' processes are the
/// session host's, and Install and Relaunch quits through `applicationShouldTerminate` and
/// `applicationWillTerminate`, which hand them over (`docs/session-host.md`, "A Sparkle
/// update").
@MainActor
@Observable
final class UpdateController: NSObject {
  static let shared = UpdateController()

  /// Set once the user has answered the consent card, either way.
  static let choiceMade = "updateChoiceMade"

  /// Where the answers are read and written. DIVERGES from armada, which reads
  /// `UserDefaults.standard` throughout: the tests run inside the app, under its bundle id,
  /// so a test controller reading the standard domain would find the owner's own answer.
  @ObservationIgnored private let defaults: UserDefaults

  private var controller: SPUStandardUpdaterController?

  private(set) var isChecking = false
  private(set) var lastCheck: Date?

  /// Whether the updater exists: never before somebody says yes, or presses Check Now.
  var isStarted: Bool { controller != nil }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    super.init()
  }

  /// Whether automatic checks are on.
  ///
  /// The answer lives in Sparkle's own `UserDefaults` key, read through the updater when it
  /// exists and directly when it does not. A second `@AppStorage` mirror would be one more
  /// thing to drift, and the plist default (`SUEnableAutomaticChecks`, false) already
  /// answers for a fresh install.
  var automatic: Bool {
    controller?.updater.automaticallyChecksForUpdates
      ?? defaults.bool(forKey: "SUEnableAutomaticChecks")
  }

  /// Whether the consent card has been answered, either way.
  var hasAnswered: Bool {
    defaults.bool(forKey: Self.choiceMade)
  }

  /// Called from `applicationDidFinishLaunching`. Builds nothing unless the user has
  /// already opted in.
  func startIfConsented() {
    guard defaults.bool(forKey: "SUEnableAutomaticChecks") else { return }
    start()
  }

  /// An explicit Check Now. This is consent in itself (pressing it is asking), so it starts
  /// the updater even when automatic checks are off, and leaves them off.
  func checkNow() {
    start()
    // No updater means no callback will ever clear the spinner.
    guard let controller else { return }
    isChecking = true
    lastCheck = Date()
    controller.updater.checkForUpdates()
  }

  func setAutomatic(_ on: Bool) {
    if on { start() }
    controller?.updater.automaticallyChecksForUpdates = on
    // Written through even when no updater exists, so that a "no" answered at the consent
    // card is durable without constructing one to record it.
    defaults.set(on, forKey: "SUEnableAutomaticChecks")
  }

  /// Record an answer from either place that asks: the card or the pane.
  func answer(automatic on: Bool) {
    setAutomatic(on)
    defaults.set(true, forKey: Self.choiceMade)
  }

  private func start() {
    guard controller == nil else { return }
    controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
  }
}

extension UpdateController: SPUUpdaterDelegate {
  /// Sparkle asks on its own on second launch when `SUEnableAutomaticChecks` is absent. It
  /// is present and false, so this never fires; but the plist is a build input and this is
  /// code, and only one of the two survives somebody deleting a key they did not recognise.
  nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
    false
  }

  /// Never postpone the relaunch. Sparkle calls this the moment somebody clicks Install and
  /// Relaunch, so the only thing a postponement could ever defer is an explicit request:
  /// cupertino found exactly that, and a button that reads as broken.
  nonisolated func updater(
    _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool { false }

  /// Every check ends here, found or not, failed or not. The user-driver callbacks below
  /// only fire when there is something to show, so a check that failed, or was ignored
  /// because one was already running, left Check Now disabled on its spinner until the app
  /// quit.
  nonisolated func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
    error: (any Error)?
  ) {
    Task { @MainActor in UpdateController.shared.isChecking = false }
  }
}

extension UpdateController: SPUStandardUserDriverDelegate {
  /// A scheduled check that finds something waits to be noticed instead of stealing focus.
  /// DIVERGES from armada in its reason only: Drakar is a regular app, but it spends long
  /// stretches behind whatever its agents are editing, and an alert in front of the window
  /// someone *is* looking at is the wrong way to mention a point release.
  nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

  /// DIVERGES from armada, which also updates `DockPresence` here: Drakar's Dock icon does
  /// not follow its windows.
  nonisolated func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    Task { @MainActor in isChecking = false }
  }

  nonisolated func standardUserDriverWillFinishUpdateSession() {
    Task { @MainActor in isChecking = false }
  }
}

/// Asked once, and as a card at the top of Home rather than a dialog.
///
/// The honest default already holds without an answer (nothing constructs an updater, and
/// nothing resolves a name, until somebody opts in), so stopping the app to demand one
/// would be theatre.
///
/// The moment Drakar can open a connection of its own at all, the person running their
/// agents through it is the one who decides.
struct UpdateConsentCard: View {
  @State private var answered = UpdateController.shared.hasAnswered

  var body: some View {
    if !answered {
      VStack(alignment: .leading, spacing: 8) {
        Label("Should Drakar check for updates?", systemImage: "arrow.down.circle")
          .font(.subheadline).bold()
        Text(
          """
          Drakar makes no network connections of its own. Checking for updates is \
          the one exception, and it is off until you say otherwise. It reads one \
          file and sends no identifier with it.
          """
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
          Button("Check automatically") { answer(true) }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
          Button("Keep updates off") { answer(false) }
            .controlSize(.small)
          Text("You can change this in Settings.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.4))
      .accessibilityIdentifier("home.updateConsent")
    }
  }

  private func answer(_ automatic: Bool) {
    UpdateController.shared.answer(automatic: automatic)
    answered = true
  }
}

/// The update controls.
///
/// Drakar's only connection of its own is this one, so the footer says what the check
/// sends in plain terms.
struct UpdatesPane: View {
  @State private var automatic = UpdateController.shared.automatic
  private var updates = UpdateController.shared

  var body: some View {
    Form {
      Section {
        LabeledContent("Version", value: AppInfo.version)

        // The row's whole label is the answer to "am I current", because a row titled the
        // same thing as the button beside it says nothing twice.
        LabeledContent {
          Button("Check Now…") { updates.checkNow() }
            .disabled(updates.isChecking)
        } label: {
          Text(lastCheck)
        }
      }

      Section {
        Toggle(isOn: $automatic) {
          Text("Check for updates automatically")
        }
        .onChange(of: automatic) { _, on in
          // Answering here is answering the consent card too. Leaving it armed would ask
          // again about a decision already made in this pane.
          updates.answer(automatic: on)
        }
      } footer: {
        Text(
          """
          This is the only network connection Drakar makes of its own, and it makes none \
          at all until you turn this on or press Check Now. It reads one file, \
          drakar.mgcrea.io/appcast.xml, and sends no identifier with it: not your \
          licence key, not a machine id.
          """
        )
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Updates")
  }

  /// A sentence either way. A row showing nothing before the first check reads as a missing
  /// value rather than as the answer.
  ///
  /// DIVERGES from armada's `.clockRelative`, a screenshot-mode format Drakar does not
  /// have: the plain relative format every other "when" in Drakar uses.
  private var lastCheck: String {
    guard let last = updates.lastCheck else { return String(localized: "Not checked yet") }
    return String(localized: "Last checked \(last.formatted(.relative(presentation: .named)))")
  }
}
