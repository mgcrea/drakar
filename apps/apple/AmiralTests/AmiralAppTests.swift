import AmiralKit
import Testing

@testable import Amiral

/// The app target's own suite. What can be argued about in a unit test lives in AmiralKit and
/// is tested there without a host app; what belongs here is whatever only exists once the
/// app is assembled.
@Suite("Amiral app")
struct AmiralAppTests {

  /// AmiralKit is linked and reachable. Thin, but it is the thing a scaffold can actually
  /// get wrong, and it fails loudly if the product dependency is dropped from the target.
  @Test func app_linksAmiralKit() {
    #expect(AmiralKit.appName == "Amiral")
  }
}
