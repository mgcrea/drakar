import AppKit
import DrakarKit
import SwiftUI

/// The window's right-hand column: what the project's `claude` would load, its skills over
/// its MCP servers, both filtered by one field. The split and the folding are kept per
/// window, as the sidebar's are.
struct InspectorView: View {
  let project: Project
  @SceneStorage("drakar.skillsFraction") private var fraction = 0.6
  @SceneStorage("drakar.skillsCollapsed") private var skillsCollapsed = false
  @SceneStorage("drakar.mcpCollapsed") private var serversCollapsed = false
  @State private var filter = ""

  var body: some View {
    VStack(spacing: 0) {
      TextField("Filter", text: $filter, prompt: Text("Filter skills and servers"))
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .accessibilityIdentifier("inspector.filter")
      Divider()
      VerticalSplit(
        fraction: $fraction, collapsesTop: skillsCollapsed, collapsesBottom: serversCollapsed
      ) {
        SkillsPane(project: project, filter: filter, isCollapsed: $skillsCollapsed)
      } bottom: {
        ServersPane(project: project, filter: filter, isCollapsed: $serversCollapsed)
      }
    }
  }
}

private struct SkillsPane: View {
  let project: Project
  let filter: String
  @Binding var isCollapsed: Bool
  /// The last skill a click ran, so a double-click runs it once.
  @State private var lastRun: SkillClick?

  private var capabilities: Capabilities { project.capabilities }

  var body: some View {
    let all = capabilities.lists.skills
    let shown = (all ?? []).filter { $0.matches(filter) }
    VStack(spacing: 0) {
      PaneHeader(
        title: String(localized: "Skills"), systemImage: "sparkles", isCollapsed: $isCollapsed,
        help: isCollapsed ? String(localized: "Show skills") : String(localized: "Hide skills"),
        identifier: "inspector.skills.header"
      ) {
        if let all { CountLabel(count: all.count) }
        RefreshButton(
          capabilities: capabilities, problem: all == nil ? nil : capabilities.skillsProblem,
          identifier: "inspector.skills.refresh")
      }
      if !isCollapsed {
        if all == nil {
          PaneStatus(capabilities: capabilities, problem: capabilities.skillsProblem)
        } else {
          List {
            ForEach(shown) { skill in
              SkillRow(skill: skill, isMarked: project.capabilityMarks.skills.contains(skill.name))
                .pressableRow { clicked(skill) }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { clicked(skill) }
                .accessibilityIdentifier("inspector.skill.\(skill.name)")
                .contextMenu { menu(for: skill) }
            }
          }
          .listStyle(.sidebar)
          .overlay {
            if shown.isEmpty {
              Text(filter.isEmpty ? "No skills" : "No match")
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier("inspector.skills")
        }
      }
    }
  }

  /// A click runs the skill in a new session, but not again as the second click of a
  /// double-click: that would make two sessions and send it in both.
  private func clicked(_ skill: SkillEntry) {
    let click = SkillClick(name: skill.name, time: ProcessInfo.processInfo.systemUptime)
    guard click.runs(after: lastRun, within: NSEvent.doubleClickInterval) else { return }
    lastRun = click
    project.run(skill, in: .newSession)
  }

  @ViewBuilder private func menu(for skill: SkillEntry) -> some View {
    Button("Run in Current Session") { project.run(skill, in: .current) }
      .disabled(!project.canRun(in: .current))
    Button("Run in New Session") { project.run(skill, in: .newSession) }
    Divider()
    Button("Copy Name") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(skill.name, forType: .string)
    }
  }
}

/// A click on a skill row, by the skill's name and the system uptime it came at.
struct SkillClick: Equatable {
  let name: String
  let time: TimeInterval

  /// Whether this click runs its skill after `last`, the click that last did: not the same
  /// skill again within `interval` (the double-click interval). Another skill always runs.
  func runs(after last: SkillClick?, within interval: TimeInterval) -> Bool {
    guard let last, last.name == name else { return true }
    return time - last.time >= interval
  }
}

/// A skill: its name, the namespace quieter, and one line of what it does.
private struct SkillRow: View {
  let skill: SkillEntry
  let isMarked: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        Text(
          "\(Text(skill.namespace.map { "\($0):" } ?? "").foregroundStyle(.secondary))\(skill.shortName)"
        )
        .lineLimit(1)
        if isMarked { NewDot() }
      }
      if !skill.displayDescription.isEmpty {
        Text(skill.displayDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    // The whole row takes the click, as a session row does, not only its text.
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(Tooltip(text: help))
    .accessibilityElement(children: .combine)
  }

  /// The description, then the name with what it takes; nil when there is neither.
  private var help: String? {
    let parts = [
      skill.description,
      skill.takesArguments ? "/\(skill.name) \(skill.argumentHint)" : "",
    ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
  }
}

/// `.help` only when there is something to say: an empty one still attaches a tooltip.
private struct Tooltip: ViewModifier {
  let text: String?

  func body(content: Content) -> some View {
    if let text { content.help(text) } else { content }
  }
}

private struct ServersPane: View {
  let project: Project
  let filter: String
  @Binding var isCollapsed: Bool

  private var capabilities: Capabilities { project.capabilities }

  var body: some View {
    let all = capabilities.lists.mcpServers
    let shown = (all ?? []).filter { $0.matches(filter) }
    VStack(spacing: 0) {
      PaneHeader(
        title: String(localized: "MCP Servers"), systemImage: "server.rack",
        isCollapsed: $isCollapsed,
        help: isCollapsed
          ? String(localized: "Show MCP servers") : String(localized: "Hide MCP servers"),
        identifier: "inspector.servers.header"
      ) {
        if let all { CountLabel(count: all.count) }
        RefreshButton(
          capabilities: capabilities, problem: all == nil ? nil : capabilities.serversProblem,
          identifier: "inspector.servers.refresh")
      }
      if !isCollapsed {
        if all == nil {
          PaneStatus(capabilities: capabilities, problem: capabilities.serversProblem)
        } else {
          List {
            ForEach(shown) { server in
              ServerRow(
                server: server, isMarked: project.capabilityMarks.servers.contains(server.name)
              ) { project.unmarkServer(server.name) }
              .accessibilityIdentifier("inspector.server.\(server.name)")
            }
          }
          .listStyle(.sidebar)
          .overlay {
            if shown.isEmpty {
              Text(filter.isEmpty ? "No MCP servers" : "No match")
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier("inspector.servers")
        }
      }
    }
  }
}

/// A server: its status, its name, where it is configured and what it offers, or why it
/// failed. Its tools fold out.
private struct ServerRow: View {
  let server: MCPServerEntry
  let isMarked: Bool
  let opened: () -> Void
  @State private var isExpanded = false

  var body: some View {
    if server.tools.isEmpty {
      label
    } else {
      DisclosureGroup(isExpanded: $isExpanded) {
        ForEach(server.tools, id: \.name) { tool in
          HStack(spacing: 4) {
            Text(tool.name).font(.caption.monospaced()).lineLimit(1)
            Spacer(minLength: 4)
            if tool.isDestructive {
              Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help("Destructive")
            } else if tool.isReadOnly {
              Image(systemName: "eye")
                .foregroundStyle(.secondary)
                .help("Read-only")
            }
          }
        }
      } label: {
        label
      }
      .onChange(of: isExpanded) { _, expanded in if expanded { opened() } }
    }
  }

  private var label: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Circle()
        .fill(tint)
        .frame(width: 7, height: 7)
        .help(server.status.label)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(
            "\(Text(server.namespace.map { "\($0):" } ?? "").foregroundStyle(.secondary))\(server.shortName)"
          )
          .lineLimit(1)
          if isMarked { NewDot() }
        }
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .help(server.error ?? server.status.label)
    .accessibilityElement(children: .combine)
    .accessibilityValue(server.status.label)
  }

  private var tint: Color {
    switch server.status {
    case .connected: .green
    case .needsAuth: .blue
    case .failed: .red
    case .pending, .other: .secondary
    }
  }

  /// "User · 11 tools", "Plugin · Needs authentication", or the failure.
  private var detail: String {
    if server.status == .failed, let error = server.error { return error }
    var parts = [MCPSourceLabel.text(server.source)].compactMap { $0 }
    if server.status == .connected {
      parts.append(
        server.tools.count == 1
          ? String(localized: "1 tool") : String(localized: "\(server.tools.count) tools"))
    } else {
      parts.append(server.status.label)
    }
    return parts.joined(separator: " · ")
  }
}

private struct CountLabel: View {
  let count: Int

  var body: some View {
    Text(count, format: .number)
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
  }
}

/// The blue dot of an unread session row, on a row that is new or went wrong.
private struct NewDot: View {
  var body: some View {
    Circle().fill(.blue).frame(width: 5, height: 5).accessibilityLabel("New")
  }
}

/// Reads the lists again; a spinner while a probe runs, a warning while the lists shown are
/// older than a reload that failed.
private struct RefreshButton: View {
  let capabilities: Capabilities
  let problem: String?
  let identifier: String

  var body: some View {
    if capabilities.isLoading {
      ProgressView().controlSize(.small)
    } else {
      Button(
        "Refresh", systemImage: problem == nil ? "arrow.clockwise" : "exclamationmark.triangle"
      ) { capabilities.refresh() }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
      .help(problem ?? String(localized: "Read the lists again"))
      .accessibilityIdentifier(identifier)
    }
  }
}

/// A pane with no list yet: asking, or why it could not, with Retry.
private struct PaneStatus: View {
  let capabilities: Capabilities
  let problem: String?

  var body: some View {
    VStack(spacing: 8) {
      if let problem, !capabilities.isLoading {
        Label(problem, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .font(.callout)
        if !capabilities.diagnostics.isEmpty {
          DisclosureGroup("Details") {
            Text(capabilities.diagnostics.suffix(600))
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
        Button("Retry") { capabilities.refresh() }
      } else {
        ProgressView().controlSize(.small)
        Text("Asking Claude Code…").font(.caption).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(12)
  }
}

/// Shows or hides the inspector. While it is hidden and its lists changed, a dot says so
/// and the tooltip says what. It also follows the window's account, the one view always on
/// screen in a project window that sees it change.
struct InspectorToggle: View {
  let project: Project
  @Binding var isShown: Bool
  /// Read only to notice a pick or the Settings default changing; the shell's account is
  /// watched too, which is `~/.claude` until the login shell has been read at launch.
  @AppStorage(PreferenceKey.accountForFolder) private var picks = ""
  @AppStorage(PreferenceKey.newSessionAccount) private var settingsAccount = ""

  var body: some View {
    let marks = project.capabilityMarks
    let showsDot = !isShown && !marks.isEmpty
    Toggle(isOn: $isShown) {
      Label("Inspector", systemImage: "sidebar.right")
    }
    .toggleStyle(.button)
    .overlay(alignment: .topTrailing) {
      if showsDot {
        Circle().fill(.blue).frame(width: 6, height: 6).offset(x: 2, y: -1)
          .accessibilityHidden(true)
      }
    }
    .help(help(marks, showsDot: showsDot))
    .accessibilityValue(
      showsDot ? marks.summary(servers: project.capabilities.lists.mcpServers ?? []) : ""
    )
    .accessibilityIdentifier("window.inspector")
    .onChange(
      of: picks + "\n" + settingsAccount + "\n" + AccountStore.shared.shellAccount.key,
      initial: true
    ) {
      project.accountMayHaveChanged()
    }
  }

  private func help(_ marks: CapabilityMarks, showsDot: Bool) -> String {
    let action =
      isShown
      ? String(localized: "Hide skills and MCP servers (⌥⌘0)")
      : String(localized: "Show skills and MCP servers (⌥⌘0)")
    guard showsDot else { return action }
    return marks.summary(servers: project.capabilities.lists.mcpServers ?? []) + "\n" + action
  }
}
