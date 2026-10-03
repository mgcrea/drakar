import AmiralKit
import SwiftUI
import UniformTypeIdentifiers

/// A window: a folder to work in, then a session in it. Each window has its own session,
/// so File › New Window is how a second one starts.
struct ContentView: View {
  @State private var session: ClaudeSession?
  @State private var choosingFolder = false

  var body: some View {
    Group {
      if let session {
        SessionView(session: session)
      } else {
        WelcomeView { choosingFolder = true }
      }
    }
    .frame(minWidth: 520, minHeight: 420)
    .navigationTitle(session?.folder.lastPathComponent ?? "Amiral")
    .navigationSubtitle(
      session.map { Self.abbreviated($0.folder.deletingLastPathComponent()) } ?? ""
    )
    .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
      if case .success(let folder) = result { open(folder) }
    }
    .task { openFromLaunchArguments() }
  }

  /// `~/Projects` rather than `/Users/me/Projects`, as the Finder and the shell write it.
  private static func abbreviated(_ url: URL) -> String {
    let path = url.path(percentEncoded: false)
    let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
  }

  private func open(_ folder: URL, command: ClaudeCommand = ClaudeCommand()) {
    session?.stop()
    let session = ClaudeSession(folder: folder)
    self.session = session
    Task { await session.start(command: command) }
  }

  /// `make run ARGS='-amiral.debugFolder <path> -amiral.debugPrompt <text>'` opens a
  /// session and sends a first prompt with no clicks, which is how the app is checked
  /// end to end without typing into it. `-amiral.debugModel <id>` picks a cheap model for
  /// the check, and `-amiral.debugSettingSources project` keeps the user's own permission
  /// rules and hooks out of one that needs a permission prompt to appear. Values, not
  /// flags: UserDefaults reads a value starting with `-` as the next key and drops it.
  /// Debug builds only: a shipped binary takes no instructions from its launch arguments.
  private func openFromLaunchArguments() {
    #if DEBUG
      let defaults = UserDefaults.standard
      guard session == nil, let path = defaults.string(forKey: "amiral.debugFolder") else { return }
      let command = ClaudeCommand(
        model: defaults.string(forKey: "amiral.debugModel"),
        extraArguments: defaults.string(forKey: "amiral.debugSettingSources").map {
          ["--setting-sources", $0]
        } ?? [])
      open(URL(filePath: path, directoryHint: .isDirectory), command: command)
      guard let prompt = defaults.string(forKey: "amiral.debugPrompt"), let session else { return }
      Task {
        while session.phase == .starting || session.phase == .idle {
          try? await Task.sleep(for: .milliseconds(100))
        }
        session.send(prompt)
      }
    #endif
  }
}

private struct WelcomeView: View {
  let openFolder: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "sailboat")
        .font(.system(size: 44, weight: .light))
        .foregroundStyle(.secondary)
      Text("Amiral")
        .font(.largeTitle.weight(.semibold))
      Text("Open a folder to start a Claude Code session in it.")
        .foregroundStyle(.secondary)
      Button("Open Folder…", action: openFolder)
        .keyboardShortcut("o")
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("welcome.openFolder")
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

#Preview {
  ContentView()
}
