import DrakarKit
import Testing

@testable import Drakar

/// The app target's own suite. What can be argued about in a unit test lives in DrakarKit and
/// is tested there without a host app; what belongs here is whatever only exists once the
/// app is assembled.
@Suite("Drakar app")
struct DrakarAppTests {

  /// DrakarKit is linked and reachable. Thin, but it is the thing a scaffold can actually
  /// get wrong, and it fails loudly if the product dependency is dropped from the target.
  @Test func app_linksDrakarKit() {
    #expect(DrakarKit.appName == "Drakar")
  }
}
