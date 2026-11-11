#if !DEBUG
  import AppKit

  /// `make bench` builds this target in Release, where SupportKitTestHost compiles no
  /// `HostedWindow` (it is Debug-only, as a Release app is never a test host). This plain
  /// window stands in so the suites that use one still compile there; only the benchmark
  /// runs in that build, and it draws on screen on purpose.
  final class HostedWindow: NSWindow {
    init(contentRect: CGRect, styleMask: NSWindow.StyleMask = [.titled]) {
      super.init(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
      isReleasedWhenClosed = false
    }
  }
#endif
