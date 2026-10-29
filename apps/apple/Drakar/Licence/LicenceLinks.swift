import Foundation

/// Armada's `LicenseLinks`, which sits at the top of its `LicensePane.swift`. Its own file
/// here, spelled the way the fleet's conventions name it, because the gate reads it as
/// well as the pane.
enum LicenceLinks {
  /// Where to buy one. The site's own vanity path rather than the Stripe checkout
  /// URL, so the destination can move without shipping a new build — see
  /// `apps/website/public/_redirects`. A Stripe URL compiled into a binary would
  /// be a payment link nobody could ever repoint.
  static let buy = URL(string: "https://drakar.mgcrea.io/buy")!

  /// Whether /buy resolves to a live payment link.
  ///
  /// A button here is a promise that there is something on the other end of it. The
  /// website has no flag of its own (armada's has `SELLING`): today it says "Free while
  /// in beta" and its `_redirects` has no `/buy`, and Phase 4 adds the `/buy` 302 and the
  /// price there when it flips this. The two move together, and this one is the slower
  /// half: the site can be redeployed in a minute, while a build that has shipped carries
  /// whatever it was compiled with until the next release. Every buy button in the app is
  /// gated on it.
  ///
  /// DIVERGES from armada, which only shipped once it was selling: Drakar ships while
  /// the store is closed, and while this is false nothing is gated at all. Flipping it
  /// is the release that opens the store and turns the gate on, so it moves only with
  /// a live payment link behind /buy.
  static let isSelling = false
}
