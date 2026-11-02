import Foundation

/// This Mac as a runner session's meta names it (`origin`, `owner`; remote sessions spec §4):
/// the name the person gave it in System Settings › General › Sharing, the one they would
/// recognise on the runner. Tests set their own, and put it back after.
enum ThisMac {
  static var name: String = Host.current().localizedName ?? "this Mac"
}
