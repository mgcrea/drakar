import Foundation

/// Who this copy of Drakar is: its version and build.
///
/// Armada's, copied, keeping `major`, which the licence reads, and `version`, which the
/// Updates pane shows. DIVERGES from armada, which also carries `developmentSuffix`,
/// `shortVersion`, `commit`, `buildLine`, `supportDirectory` and `LoginItem`: nothing in
/// Drakar calls them, and the About pane is the package's. Each comes over with whatever
/// first needs it.
enum AppInfo {
  /// The marketing version and the build, `"1.0.0 (60)"`, for showing a person.
  static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }

  /// The major version a licence key must cover.
  ///
  /// A key is issued against `1.x` and refused by a `2.x` build, which is what
  /// makes a paid major upgrade expressible without an expiry date on the key
  /// itself. Derived from the shipped version rather than hardcoded, so it cannot
  /// disagree with what the About pane says. `nonisolated` because `LicenseKey`
  /// reads it as a default argument from outside the main actor.
  nonisolated static var major: Int {
    let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
    return Int(short.split(separator: ".").first ?? "1") ?? 1
  }
}
