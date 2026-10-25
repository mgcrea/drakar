/// What the app as a whole is doing, for what a session does differently when it is the
/// app that goes away rather than the session's window.
enum AppLifecycle {
  /// Set once the app is quitting: a session at work is left to the session host.
  @MainActor static var isTerminating = false
}
