import AppKit
import Observation
import SwiftTerm
import SwiftUI

/// The project window retains the terminal while its pane is hidden.
@MainActor
@Observable
final class ProjectTerminal {
  private(set) var view: LocalProcessTerminalView?
  private(set) var status: String?

  func start(in folder: URL) {
    let view = ShellTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 200))
    view.onExit = { [weak self, weak view] status in
      guard let self, let view, self.view === view else { return }
      self.status = status
    }
    // SwiftTerm keeps its native renderer available when Metal initialization fails.
    try? view.setUseMetal(true)
    status = nil
    self.view = view

    var environment = ProcessInfo.processInfo.environment
    let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
    view.startProcess(
      executable: shell, args: ["-l", "-i"],
      environment: environment.map { "\($0.key)=\($0.value)" },
      currentDirectory: folder.path(percentEncoded: false))
  }

  func stop() {
    let previous = view
    view = nil
    status = nil
    previous?.terminate()
  }
}

struct ProjectTerminalPane: View {
  let terminal: ProjectTerminal
  let folder: URL
  let hide: () -> Void
  @AppStorage(PreferenceKey.terminalFontSize) private var fontSize = TerminalDefaults.fontSize
  @AppStorage(PreferenceKey.terminalScrollback) private var scrollback = TerminalDefaults.scrollback
  @AppStorage(PreferenceKey.terminalBell) private var bell = TerminalDefaults.bell

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("Terminal")
          .font(.caption.weight(.semibold))
        if let status = terminal.status {
          Text(status)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Button("New Shell") { terminal.start(in: folder) }
        }
        Spacer()
        Button(action: hide) {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Hide Terminal")
        .accessibilityLabel("Hide Terminal")
      }
      .padding(.horizontal, 10)
      .frame(height: 28)
      Divider()
      if let view = terminal.view {
        TerminalSurface(view: view)
          .padding(.horizontal, 8)
          .background(Color(nsColor: view.nativeBackgroundColor))
          .onChange(of: fontSize, initial: true) {
            let size = CGFloat(min(max(fontSize, 8), 32))
            if view.font.pointSize != size {
              view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
          }
          .onChange(of: scrollback, initial: true) {
            view.changeScrollback(min(max(scrollback, 0), 50_000))
          }
          .onChange(of: bell, initial: true) {
            view.bellStyle = BellStyle(tagName: bell) ?? .sound
          }
          .id(ObjectIdentifier(view))
      }
    }
    .task {
      if terminal.view == nil { terminal.start(in: folder) }
    }
  }
}

private struct TerminalSurface: NSViewRepresentable {
  let view: LocalProcessTerminalView

  func makeNSView(context: Context) -> LocalProcessTerminalView { view }

  func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
}

private final class ShellTerminalView: LocalProcessTerminalView {
  var onExit: ((String) -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    Task { @MainActor [weak self, weak window] in
      guard let self, let window, self.window === window else { return }
      window.makeFirstResponder(self)
    }
  }

  override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
    super.processTerminated(source, exitCode: exitCode)
    if let exitCode, exitCode != 0 {
      onExit?(String(localized: "Shell exited with status \(exitCode)"))
    } else {
      onExit?(String(localized: "Shell ended"))
    }
  }

  override func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
    super.processFailedToStart(source, error: error)
    onExit?(String(localized: "Couldn’t start the shell"))
  }
}
