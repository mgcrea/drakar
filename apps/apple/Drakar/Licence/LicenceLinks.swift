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
  /// website's `SELLING` (apps/website/src/config.ts) mirrors it, and its `_redirects`
  /// sends `/buy` to the live payment link. The two move together, and this one is the
  /// slower half: the site can be redeployed in a minute, while a build that has shipped
  /// carries whatever it was compiled with until the next release. Every buy button in
  /// the app is gated on it, and so is the licence gate itself: while it is false nothing
  /// is gated at all.
  ///
  /// True from 1.1.0, the release that opened the store. DIVERGES from armada, which only
  /// shipped once it was selling: Drakar 1.0.0 shipped free while the store was closed.
  static let isSelling = true
}
