import AppKit
import DrakarKit
import SwiftUI

/// File › New Session on Runner… (remote sessions spec §4 "Choosing a folder"): a folder on
/// the runner, typed, since this Mac cannot browse it, with the runner's recent folders below;
/// then its runner window, a new session shown there.
@MainActor enum NewRunnerSession {
  /// The panel while it is up, which nothing else holds when no window is there to hold it.
  private static var shown: NSPanel?

  /// The folder `typed` names on the runner, or nil when it names none. `~` is the runner's
  /// home (`home`, from its facts), never this Mac's; nothing is looked for on this Mac's disk,
  /// and a folder the runner does not have fails its session's spawn there.
  static func path(from typed: String, home: String?) -> String? {
    let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    var path = typed
    if typed == "~" || typed.hasPrefix("~/") {
      guard let home else { return nil }
      path = home + typed.dropFirst()
    }
    guard path.hasPrefix("/") else { return nil }
    return ProjectPath.normalize(path)
  }

  /// Asks for the folder, as a sheet of the window in front, or a panel of its own when there
  /// is none. Nothing with no runner set up.
  static func ask() {
    guard shown == nil, let host = SessionHost.runner, let runner = host.runnerID else { return }
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    let parent = NSApp.keyWindow
    func dismiss() {
      if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.close() }
      shown = nil
    }
    let sheet = NewRunnerSessionSheet(
      host: host,
      open: { folder in
        dismiss()
        start(in: folder, on: runner)
      }, cancel: dismiss)
    panel.contentViewController = NSHostingController(rootView: sheet.themed())
    shown = panel
    if let parent {
      parent.beginSheet(panel)
    } else {
      panel.center()
      panel.makeKeyAndOrderFront(nil)
    }
  }

  /// `folder`'s runner window, a new session shown in it: the open one comes forward, or a
  /// new one opens and shows it once it has taken back what the runner holds for it.
  static func start(in folder: String, on runner: String) {
    let route = WindowRoute.runnerProject(runner: runner, folder: folder)
    if let project = OpenSessions.shared.project(for: route) {
      project.showNewSession()
      project.workspace.window?.makeKeyAndOrderFront(nil)
      return
    }
    OpenSessions.shared.requestNewSession(in: route)
    WindowTabs.open(route, asTab: NSApp.keyWindow != nil)
  }
}

/// The sheet: the path field, the recent folders under it, Open and Cancel.
struct NewRunnerSessionSheet: View {
  let host: SessionHost
  let open: (String) -> Void
  let cancel: () -> Void

  @State private var typed = ""
  @State private var recent: [String] = []

  private var name: String { host.runnerName ?? String(localized: "the runner") }
  private var path: String? { NewRunnerSession.path(from: typed, home: host.facts?.home) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New Session on \(name)").font(.headline)
      VStack(alignment: .leading, spacing: 4) {
        TextField(
          "Folder", text: $typed,
          prompt: Text(host.facts == nil ? "/Users/you/project" : "~/project")
        )
        .textFieldStyle(.roundedBorder)
        .onSubmit(submit)
        .accessibilityIdentifier("runnerSession.path")
        Text("A folder on \(name), not on this Mac.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if !recent.isEmpty {
        Text("Recent Folders").font(.subheadline.weight(.medium))
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(recent, id: \.self) { folder in
              Button {
                typed = folder
              } label: {
                HStack(spacing: 8) {
                  Image(systemName: "folder").foregroundStyle(.secondary)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(URL(filePath: folder).lastPathComponent)
                    Text(folder)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                      .truncationMode(.middle)
                  }
                  Spacer()
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .simultaneousGesture(TapGesture(count: 2).onEnded { open(folder) })
              .accessibilityIdentifier("runnerSession.recent.\(folder)")
            }
          }
        }
        .frame(maxHeight: 180)
      }
      HStack {
        Spacer()
        Button("Cancel", action: cancel)
          .keyboardShortcut(.cancelAction)
        Button("Open", action: submit)
          .keyboardShortcut(.defaultAction)
          .disabled(path == nil)
      }
    }
    .padding(20)
    .frame(width: 440)
    .task { recent = RunnerSection.recentFolders(of: await host.held()) }
  }

  private func submit() {
    if let path { open(path) }
  }
}
