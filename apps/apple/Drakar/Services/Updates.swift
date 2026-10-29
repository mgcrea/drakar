import AppKit
import OSLog
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
/// stays `nil`. Sparkle starts a scheduler the moment its updater starts, so starting it and
/// then declining to check would leave the claim resting on a flag rather than on the
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
  /// Why the updater would not start, the last time it was asked to; nil once it has.
  private(set) var startFailure: String?

  /// Whether automatic checks are on.
  ///
  /// The answer lives in Sparkle's own `UserDefaults` key, `SUEnableAutomaticChecks`, which
  /// the plist default (false) answers for a fresh install. DIVERGES from armada, which reads
  /// it on every access: here it is stored and written through, so that the card on Home and
  /// the Settings pane, both on screen for as long as their windows are, follow one observed
  /// value rather than each keeping the answer it read when it appeared.
  private(set) var automatic: Bool

  /// Whether the consent card has been answered, either way. Stored for the same reason.
  private(set) var hasAnswered: Bool

  /// Whether the updater exists and has started: never before somebody says yes, or presses
  /// Check Now, and never when Sparkle refused to start.
  var isStarted: Bool { controller != nil }

  /// Whether this is a development build, which never builds an updater and never asks.
  ///
  /// DIVERGES from armada. Debug and Release share the bundle id, `SUFeedURL` and
  /// `SUPublicEDKey`, and a Debug build's `CURRENT_PROJECT_VERSION` is 1 where a release's
  /// is the commit count, so an updater in the owner's own `make run` copy would offer to
  /// replace it with the release. A parameter rather than an `#if` at each use, so the tests,
  /// which run in the Debug host, can still build a controller that behaves as a release.
  let isDevelopmentBuild: Bool

  /// What a build that is not passed one is: a Debug build is a development build.
  static var compiledAsDevelopmentBuild: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  /// Whether Home should ask: in a release, until it is answered either way; in a
  /// development build, never, since nothing would come of the answer.
  var showsConsentCard: Bool { !isDevelopmentBuild && !hasAnswered }

  init(
    defaults: UserDefaults = .standard,
    isDevelopmentBuild: Bool = UpdateController.compiledAsDevelopmentBuild
  ) {
    self.defaults = defaults
    self.isDevelopmentBuild = isDevelopmentBuild
    automatic = defaults.bool(forKey: "SUEnableAutomaticChecks")
    hasAnswered = defaults.bool(forKey: Self.choiceMade)
    super.init()
  }

  /// Called from `applicationDidFinishLaunching`. Builds nothing unless the user has
  /// already opted in.
  func startIfConsented() {
    guard automatic else { return }
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
    automatic = on
  }

  /// Record an answer from either place that asks: the card or the pane.
  func answer(automatic on: Bool) {
    setAutomatic(on)
    defaults.set(true, forKey: Self.choiceMade)
    hasAnswered = true
  }

  /// DIVERGES from armada, which builds the controller with `startingUpdater: true`. Sparkle
  /// then reports a refusal to start (a feed or key it finds invalid, as the placeholder
  /// `SUPublicEDKey` is until Phase 2) with an alert of its own, and leaves behind a
  /// controller whose updater never runs: `isStarted` read true, Check Now waited on its
  /// spinner for a callback that never came, and a "yes" brought the alert back at every
  /// launch. Starting it here keeps a refusal to one log line and a sentence in the pane, and
  /// the controller nil, so the next Check Now asks again.
  ///
  /// A development build stops here, before Sparkle is touched: no controller, no failure to
  /// report, whatever was answered.
  private func start() {
    guard !isDevelopmentBuild, controller == nil else { return }
    let candidate = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    do {
      try candidate.updater.start()
    } catch {
      Self.log.error("updater not started: \(error.localizedDescription, privacy: .public)")
      startFailure = error.localizedDescription
      return
    }
    startFailure = nil
    controller = candidate
  }

  private static let log = Logger(subsystem: "io.mgcrea.Drakar", category: "updates")
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
  /// DIVERGES from armada, whose card copies `hasAnswered` into `@State` when it appears:
  /// armada's popover is rebuilt at each opening, but Home stays on screen, and an answer
  /// given in Settings meanwhile must take the card away rather than leave it to overwrite
  /// that answer.
  private var updates: UpdateController { .shared }

  var body: some View {
    if updates.showsConsentCard {
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
    updates.answer(automatic: automatic)
  }
}

/// The update controls.
///
/// Drakar's only connection of its own is this one, so the footer says what the check
/// sends in plain terms. A development build has no check to offer, so it shows its
/// version and says why there is nothing else.
struct UpdatesPane: View {
  private var updates: UpdateController { .shared }

  var body: some View {
    Form {
      Section {
        LabeledContent("Version", value: AppInfo.version)

        if updates.isDevelopmentBuild {
          Text("Updates are off in development builds.")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("settings.updates.development")
        } else {
          checkRow
        }
      }

      if !updates.isDevelopmentBuild {
        automaticSection
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Updates")
  }

  /// The row's whole label is the answer to "am I current", because a row titled the same
  /// thing as the button beside it says nothing twice.
  private var checkRow: some View {
    LabeledContent {
      Button("Check Now…") { updates.checkNow() }
        .disabled(updates.isChecking)
    } label: {
      Text(lastCheck)
    }
  }

  private var automaticSection: some View {
    Section {
      // Answering here is answering the consent card too. Leaving it armed would ask
      // again about a decision already made in this pane. A binding on the controller
      // rather than armada's `@State` copy, so an answer given at the card shows here.
      Toggle(
        isOn: Binding(get: { updates.automatic }, set: { updates.answer(automatic: $0) })
      ) {
        Text("Check for updates automatically")
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

  /// A sentence either way. A row showing nothing before the first check reads as a missing
  /// value rather than as the answer.
  ///
  /// DIVERGES from armada's `.clockRelative`, a screenshot-mode format Drakar does not
  /// have: the plain relative format every other "when" in Drakar uses.
  ///
  /// A refusal to start says so in the same place, since it is why nothing was checked.
  private var lastCheck: String {
    if let failure = updates.startFailure {
      return String(localized: "Couldn't start the update check. \(failure)")
    }
    guard let last = updates.lastCheck else { return String(localized: "Not checked yet") }
    return String(localized: "Last checked \(last.formatted(.relative(presentation: .named)))")
  }
}
