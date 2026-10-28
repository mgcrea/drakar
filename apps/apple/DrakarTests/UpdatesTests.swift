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

  @Test func infoPlistDefaultsArePresentAndFalse() {
    let info = Bundle.main.infoDictionary!
    #expect(info["SUEnableAutomaticChecks"] as? Bool == false)
    #expect(info["SUAutomaticallyUpdate"] as? Bool == false)
    #expect(info["SUScheduledCheckInterval"] as? Int == 86400)
    #expect(info["SUFeedURL"] as? String == "https://drakar.mgcrea.io/appcast.xml")
  }
}
