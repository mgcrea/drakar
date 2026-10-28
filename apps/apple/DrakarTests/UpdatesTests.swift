import Foundation
import Testing

@testable import Drakar

/// The update check is off until somebody says yes, and that rests on two things a test can
/// see: no updater exists before consent, and the shipped Info.plist sets the defaults
/// present and false rather than leaving them absent (an absent `SUEnableAutomaticChecks` is
/// what makes Sparkle ask on its own at the second launch).
@Suite("Updates", .serialized) @MainActor struct UpdatesTests {
  @Test func noUpdaterBeforeConsent() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let controller = UpdateController(defaults: defaults)
    controller.startIfConsented()
    #expect(!controller.isStarted)
    #expect(!controller.hasAnswered)
  }

  /// A "no" builds nothing and is remembered.
  @Test func answeringNoStartsNothing() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let controller = UpdateController(defaults: defaults)
    controller.answer(automatic: false)
    #expect(!controller.isStarted)
    #expect(controller.hasAnswered)
    #expect(!controller.automatic)
    #expect(UpdateController(defaults: defaults).hasAnswered)
  }

  /// An updater Sparkle refuses to start leaves no controller behind: no spinner waiting on a
  /// callback that never comes, and the "yes" still recorded. The placeholder key makes the
  /// refusal real in the test host, so this runs only while the bundle carries it; with the
  /// real key it would start Sparkle inside the tests, writing to the app's own defaults.
  @Test(.enabled(if: Bundle.main.infoDictionary?["SUPublicEDKey"] as? String == placeholderKey))
  func anUpdaterThatWillNotStartStaysNil() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let controller = UpdateController(defaults: defaults)
    controller.answer(automatic: true)
    #expect(!controller.isStarted)
    #expect(controller.hasAnswered)
    #expect(controller.automatic)
    #expect(controller.startFailure != nil)
    controller.checkNow()
    #expect(!controller.isStarted)
    #expect(!controller.isChecking)
    #expect(controller.lastCheck == nil)
    let relaunched = UpdateController(defaults: defaults)
    #expect(relaunched.automatic)
    relaunched.startIfConsented()
    #expect(!relaunched.isStarted)
  }

  @Test func infoPlistDefaultsArePresentAndFalse() {
    let info = Bundle.main.infoDictionary!
    #expect(info["SUEnableAutomaticChecks"] as? Bool == false)
    #expect(info["SUAutomaticallyUpdate"] as? Bool == false)
    #expect(info["SUScheduledCheckInterval"] as? Int == 86400)
    #expect(info["SUFeedURL"] as? String == "https://drakar.mgcrea.io/appcast.xml")
  }
}

private let placeholderKey = "PLACEHOLDER-SET-IN-PHASE-2"
