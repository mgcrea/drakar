import Foundation
import Testing

@testable import Drakar

/// The update check is off until somebody says yes, and that rests on two things a test can
/// see: no updater exists before consent, and the shipped Info.plist sets the defaults
/// present and false rather than leaving them absent (an absent `SUEnableAutomaticChecks` is
/// what makes Sparkle ask on its own at the second launch).
///
/// These run in the Debug test host, a development build, so every controller that is meant
/// to behave as a release says so (`isDevelopmentBuild: false`).
@Suite("Updates", .serialized) @MainActor struct UpdatesTests {
  @Test func noUpdaterBeforeConsent() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let controller = UpdateController(defaults: defaults, isDevelopmentBuild: false)
    controller.startIfConsented()
    #expect(!controller.isStarted)
    #expect(!controller.hasAnswered)
  }

  /// A "no" builds nothing and is remembered.
  @Test func answeringNoStartsNothing() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let controller = UpdateController(defaults: defaults, isDevelopmentBuild: false)
    controller.answer(automatic: false)
    #expect(!controller.isStarted)
    #expect(controller.hasAnswered)
    #expect(!controller.automatic)
    #expect(UpdateController(defaults: defaults, isDevelopmentBuild: false).hasAnswered)
  }

  /// An updater Sparkle refuses to start leaves no controller behind: no spinner waiting on a
  /// callback that never comes, and the "yes" still recorded. The placeholder key makes the
  /// refusal real in the test host, so this runs only while the bundle carries it; with the
  /// real key it would start Sparkle inside the tests, writing to the app's own defaults.
  @Test(.enabled(if: Bundle.main.infoDictionary?["SUPublicEDKey"] as? String == placeholderKey))
  func anUpdaterThatWillNotStartStaysNil() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let controller = UpdateController(defaults: defaults, isDevelopmentBuild: false)
    controller.answer(automatic: true)
    #expect(!controller.isStarted)
    #expect(controller.hasAnswered)
    #expect(controller.automatic)
    #expect(controller.startFailure != nil)
    controller.checkNow()
    #expect(!controller.isStarted)
    #expect(!controller.isChecking)
    #expect(controller.lastCheck == nil)
    let relaunched = UpdateController(defaults: defaults, isDevelopmentBuild: false)
    #expect(relaunched.automatic)
    relaunched.startIfConsented()
    #expect(!relaunched.isStarted)
  }

  /// The owner's own `make run` copy shares the release's bundle id, feed and key, and its
  /// build number is 1: an updater there would offer to replace it with the release. A
  /// development build never builds one, whatever it is told, and never asks.
  @Test func aDevelopmentBuildNeverStarts() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let controller = UpdateController(defaults: defaults, isDevelopmentBuild: true)
    #expect(!controller.showsConsentCard)
    controller.answer(automatic: true)
    #expect(!controller.isStarted)
    #expect(controller.startFailure == nil)
    controller.checkNow()
    #expect(!controller.isStarted)
    #expect(!controller.isChecking)
    #expect(controller.lastCheck == nil)
    let relaunched = UpdateController(defaults: defaults, isDevelopmentBuild: true)
    relaunched.startIfConsented()
    #expect(!relaunched.isStarted)
    #expect(!relaunched.showsConsentCard)
  }

  /// The test host is a Debug build, so the default is the development answer; a release
  /// build's default is the other one, which no test here can see.
  @Test func theDefaultIsTheCompiledAnswer() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    #expect(UpdateController(defaults: defaults).isDevelopmentBuild)
  }

  /// A release asks until it is answered, and then never again.
  @Test func aReleaseShowsTheCardUntilAnswered() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let controller = UpdateController(defaults: defaults, isDevelopmentBuild: false)
    #expect(controller.showsConsentCard)
    controller.answer(automatic: false)
    #expect(!controller.showsConsentCard)
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
