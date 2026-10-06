import Foundation
import SupportKitSettings
import Testing

@testable import Drakar

/// The accent colour Settings ▸ Theme stores, and what the app makes of what is stored.
@MainActor
@Suite("Theme")
struct ThemeTests {
  /// A scratch defaults suite as `ClaudeChoice` reads it, never the real one.
  private func withSuite<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
    let name = "drakar.tests.theme.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    return try ClaudeChoice.$testSuite.withValue(name) { try body(defaults) }
  }

  @Test func keepsTheDefaultAccentWhileNothingIsPicked() {
    withSuite { _ in
      #expect(Theme.pickedAccent == nil)
      #expect(Theme.tint == nil)
    }
  }

  @Test func readsThePickedAccentFromItsKey() {
    withSuite { defaults in
      defaults.set("AF52DEFF", forKey: PreferenceKey.accentColor)
      #expect(Theme.pickedAccent == SwatchColor.hex(0xAF52DE))
      #expect(Theme.tint != nil)
    }
  }

  /// A key written by hand, or by a later version, is not a colour: the default stands.
  @Test func ignoresWhatIsNotAColour() {
    withSuite { defaults in
      for text in ["", "blue", "#AF52DE", "AF52", "ZZZZZZ"] {
        defaults.set(text, forKey: PreferenceKey.accentColor)
        #expect(Theme.pickedAccent == nil, "\(text)")
      }
    }
  }

  /// A tint with opacity would wash out every control it colours.
  @Test func picksAreOpaque() {
    withSuite { defaults in
      defaults.set("AF52DE40", forKey: PreferenceKey.accentColor)
      #expect(Theme.pickedAccent?.alpha == 1)
    }
  }

  @Test func offersEachSwatchOnce() {
    let hexes = ([Theme.defaultAccent] + Theme.accentPalette).map(\.hex)
    #expect(Set(hexes).count == hexes.count)
  }

  /// The asset catalog's light accent is the default, so a picked-then-restored colour and an
  /// untouched one look the same.
  @Test func defaultsToTheCatalogsAccent() {
    #expect(Theme.defaultAccent.hex == "007AFFFF")
  }
}
