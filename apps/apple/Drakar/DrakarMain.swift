import Foundation
// For `App.main`, which runs only past the branch: importing initialises nothing.
import SwiftUI

/// The app binary's entry point. sshd starts the same binary as `Drakar --relay` on a runner
/// (spec §1), so the relay is branched to before anything brings up AppKit, SwiftUI, Sparkle
/// or the licence: a relay never registers with LaunchServices as a second Drakar, nor shows
/// in the Dock. Everything else is the app.
@main
enum DrakarMain {
  static func main() {
    if CommandLine.arguments.contains("--relay") {
      RelayCommand.run(arguments: CommandLine.arguments)
    }
    DrakarApp.main()
  }
}
