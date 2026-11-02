import Foundation
import SystemConfiguration

/// This Mac as a runner session's meta names it (`origin`, `owner`; remote sessions spec §4):
/// the name the person gave it in System Settings › General › Sharing, the one they would
/// recognise on the runner. Read from the dynamic store, which answers at once, where
/// `Host.current()` may wait on name resolution: it is read on the main actor at a spawn.
/// Tests set their own, and put it back after.
enum ThisMac {
  static var name: String = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "this Mac"
}
