import AppKit
import DrakarKit
import SwiftUI

extension SkillText {
  /// The Location column: where the first agent sees it, and for a link, where it leads.
  static func location(
    of record: SkillRecord,
    home: String = FileManager.default.homeDirectoryForCurrentUser.skillPath
  ) -> String {
    guard let sighting = record.sightings.first(where: { $0.path != nil }),
      let path = sighting.path
    else { return "" }
    let seen = Self.path(path, home: home)
    return sighting.isLink ? "\(seen) → \(Self.path(record.realPath, home: home))" : seen
  }

  static func origin(_ origin: SkillOrigin) -> String {
    switch origin {
    case .user: String(localized: "Yours")
    case .project: String(localized: "Project")
    case .plugin(let id): id
    case .codexSystem: String(localized: "Codex system")
    case .codexAdmin: String(localized: "Codex admin")
    case .unknown: String(localized: "Unknown")
    }
  }

  /// The Name cell's second line.
  static func caption(of record: SkillRecord) -> String? {
    if record.notLoadedByClaude { return String(localized: "Not loaded by Claude Code") }
    if record.isShadowed { return String(localized: "Shadowed") }
    return nil
  }

  /// The detail's notes.
  static func notes(of record: SkillRecord) -> [String] {
    var notes: [String] = []
    if record.isMissing {
      notes.append(String(localized: "The folder this link points to is gone"))
    }
    if record.notLoadedByClaude {
      notes.append(String(localized: "Not loaded by Claude Code"))
    }
    for sighting in record.sightings where !sighting.isEnabled {
      notes.append(String(localized: "Turned off for \(sighting.agent.kind.name)"))
    }
    if record.isShadowed {
      notes.append(String(localized: "Shadowed: Codex uses a nearer skill of the same name"))
    }
    return notes
  }
}

extension SkillsPlace {
  var title: String {
    switch self {
    case .all: String(localized: "All")
    case .yours: String(localized: "Yours")
    case .project: String(localized: "This project")
    case .plugins: String(localized: "Plugins")
    case .codex: String(localized: "Codex built-in")
    }
  }

  var systemImage: String {
    switch self {
    case .all: "square.stack"
    case .yours: "person"
    case .project: "folder"
    case .plugins: "puzzlepiece.extension"
    case .codex: "shippingbox"
    }
  }
}

/// The Skills window: every skill Claude Code and Codex see for one project or none, where
/// each comes from, and the actions that install, share and delete them.
struct SkillsWindow: View {
  @Bindable var manager: SkillsManager
  @State private var sortOrder = [
    KeyPathComparator(\SkillRecord.name, comparator: .localizedStandard)
  ]
  @State private var install: InstallRequest?
  @State private var deleting: DeleteRequest?
  /// Read only to notice a folder's pick, the Settings default or the shell's account
  /// changing, as the inspector's toggle does: the window's account may be another now.
  @AppStorage(PreferenceKey.accountForFolder) private var picks = ""
  @AppStorage(PreferenceKey.newSessionAccount) private var settingsAccount = ""

  var body: some View {
    let openPaths = manager.openFolders().map(\.skillPath)
    let accountInputs =
      picks + "\n" + settingsAccount + "\n" + AccountStore.shared.shellAccount.key
    columns
      .onAppear { manager.start() }
      .onDisappear { manager.stop() }
      .onChange(of: openPaths) { manager.openProjectsChanged() }
      .onChange(of: accountInputs) { manager.accountMayHaveChanged() }
      .alert("Skills", isPresented: failureShown, presenting: manager.failure) { _ in
        Button("OK", role: .cancel) {}
      } message: { failure in
        Text(failure)
      }
      .sheet(item: $install) { request in InstallSheet(request: request, manager: manager) }
      .sheet(item: $deleting) { request in DeleteSheet(request: request, manager: manager) }
      // The window keeps its size between openings; SwiftUI does not reopen it at launch.
      .background(WindowReader { $0.setFrameAutosaveName("drakar.skills") })
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("skills.window")
  }

  private var columns: some View {
    NavigationSplitView {
      SkillsSidebar(manager: manager)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220)
    } content: {
      SkillsList(manager: manager, sortOrder: $sortOrder)
        .navigationSplitViewColumnWidth(min: 440, ideal: 580)
    } detail: {
      SkillDetail(manager: manager, delete: askToDelete)
    }
    .navigationTitle("Skills")
    .toolbar { toolbar }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItemGroup {
      if manager.isBusy {
        ProgressView().controlSize(.small)
      }
      Button("Install from Folder…", systemImage: "folder.badge.plus") { chooseFolder() }
        .help(String(localized: "Install from Folder…"))
        .disabled(manager.isBusy)
        .accessibilityIdentifier("skills.install.folder")
      Button("Install from Git…", systemImage: "arrow.down.circle") {
        install = InstallRequest(source: .git)
      }
      .help(String(localized: "Install from Git…"))
      .disabled(manager.isFetching || manager.isBusy)
      .accessibilityIdentifier("skills.install.git")
      Button("Refresh", systemImage: "arrow.clockwise") { manager.refresh() }
        .help(String(localized: "Read the skills again"))
        .accessibilityIdentifier("skills.refresh")
    }
  }

  private var failureShown: Binding<Bool> {
    Binding(
      get: { manager.failure != nil },
      set: { if !$0 { manager.failure = nil } })
  }

  private func askToDelete(_ record: SkillRecord) {
    guard let plan = manager.deletePlan(for: record) else { return }
    deleting = DeleteRequest(record: record, plan: plan)
  }

  /// A skill's folder or its SKILL.md, or a folder of skills three levels deep at most.
  private func chooseFolder() {
    let panel = NSOpenPanel()
    let onlySkillFiles = SkillFileFilter()
    panel.delegate = onlySkillFiles
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Choose")
    panel.message = String(
      localized: "Choose a skill's folder or its SKILL.md, or a folder of skills.")
    let answer = panel.runModal()
    withExtendedLifetime(onlySkillFiles) {}
    guard answer == .OK, var folder = panel.url else { return }
    var isFolder: ObjCBool = false
    if !FileManager.default.fileExists(atPath: folder.skillPath, isDirectory: &isFolder)
      || !isFolder.boolValue
    {
      folder.deleteLastPathComponent()
    }
    Task { [folder] in
      let found = await manager.skills(in: folder, depth: 3)
      guard !found.isEmpty else {
        manager.failure = String(
          localized:
            "\(SkillText.path(folder)) has no SKILL.md, nor do its folders three levels down.")
        return
      }
      install = InstallRequest(source: .folder(found))
    }
  }
}

/// Install from Folder…'s panel: folders, and of the files only a SKILL.md.
final class SkillFileFilter: NSObject, NSOpenSavePanelDelegate {
  func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
    url.lastPathComponent == "SKILL.md"
      || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}

private struct SkillsSidebar: View {
  @Bindable var manager: SkillsManager

  var body: some View {
    let folders = manager.openFolders()
    List(selection: placeBinding) {
      ForEach(manager.visiblePlaces) { place in
        HStack {
          Label {
            VStack(alignment: .leading, spacing: 1) {
              Text(place.title)
              if let caption = caption(place) {
                Text(caption)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
            }
          } icon: {
            Image(systemName: place.systemImage)
          }
          Spacer()
          Text(manager.count(place), format: .number)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .tag(place)
        .accessibilityIdentifier("skills.place.\(place.rawValue)")
      }
    }
    // On the list, not the inset: an identifier set after `safeAreaInset` overrides the
    // picker's own.
    .accessibilityIdentifier("skills.sidebar")
    .safeAreaInset(edge: .top) {
      Picker("Project", selection: projectBinding) {
        Text("No Project").tag(String?.none)
        ForEach(folders, id: \.self) { folder in
          Text(folder.lastPathComponent).tag(Optional(folder.skillPath))
        }
      }
      .labelsHidden()
      .help(manager.project.map(SkillText.path) ?? String(localized: "Your skills only"))
      .padding(.horizontal, 10)
      .padding(.top, 8)
      .accessibilityIdentifier("skills.project")
    }
  }

  private var placeBinding: Binding<SkillsPlace?> {
    Binding(get: { manager.place }, set: { if let place = $0 { manager.place = place } })
  }

  private var projectBinding: Binding<String?> {
    Binding(
      get: { manager.project?.skillPath },
      set: { manager.choose(project: $0.map { URL(filePath: $0, directoryHint: .isDirectory) }) })
  }

  private func caption(_ place: SkillsPlace) -> String? {
    switch place {
    case .yours: manager.account.name
    case .project: manager.project?.lastPathComponent
    default: nil
    }
  }
}

private struct SkillsList: View {
  @Bindable var manager: SkillsManager
  @Binding var sortOrder: [KeyPathComparator<SkillRecord>]

  var body: some View {
    let rows = manager.shown.sorted(using: sortOrder)
    VStack(spacing: 0) {
      ForEach(manager.problems, id: \.self) { problem in
        HStack {
          Label(problem, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.callout)
          Spacer()
          Button("Retry") { manager.refresh() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        Divider()
      }
      Table(rows, selection: $manager.selection, sortOrder: $sortOrder) {
        TableColumn("Name", value: \.name) { record in NameCell(record: record) }
        TableColumn("Agents") { record in AgentTags(record: record) }
          .width(min: 110, ideal: 120)
        TableColumn("Origin") { record in
          Text(SkillText.origin(record.origin)).foregroundStyle(.secondary)
        }
        TableColumn("Location") { record in
          let location = SkillText.location(of: record)
          Text(location)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(location)
        }
      }
      .overlay {
        if rows.isEmpty {
          if manager.isLoading {
            ProgressView()
          } else {
            Group {
              if manager.filter.isEmpty { Text("No skills") } else { Text("No match") }
            }
            .foregroundStyle(.secondary)
          }
        }
      }
      .accessibilityIdentifier("skills.table")
      if manager.isLoading || manager.codex.isCodexMissing {
        HStack(spacing: 6) {
          if manager.isLoading {
            ProgressView().controlSize(.small)
            Text("Reading skills…")
          }
          if manager.codex.isCodexMissing { Text("Codex was not found") }
          Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
      }
    }
    .searchable(text: $manager.filter, placement: .toolbar, prompt: "Filter skills")
  }
}

private struct NameCell: View {
  let record: SkillRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 4) {
        Text(record.name).lineLimit(1)
        if record.isLink {
          Image(systemName: "link")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Link")
        }
      }
      if let caption = SkillText.caption(of: record) {
        Text(caption).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

/// A tag per agent that sees the skill, dimmed when it is turned off or shadowed there.
private struct AgentTags: View {
  let record: SkillRecord

  var body: some View {
    HStack(spacing: 4) {
      ForEach(SkillAgent.allCases, id: \.self) { agent in
        if let sighting = record.sighting(for: agent) {
          Text(agent.kind.shortName)
            .font(.caption)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .opacity(sighting.isEnabled && !sighting.isShadowed ? 1 : 0.45)
        }
      }
    }
  }
}

private struct SkillDetail: View {
  @Bindable var manager: SkillsManager
  let delete: (SkillRecord) -> Void
  /// The first 4 KB of the shown skill's file.
  @State private var preview: String?

  var body: some View {
    if let record = manager.selected {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(record.name).font(.title2.bold()).textSelection(.enabled)
          if !record.description.isEmpty {
            Text(record.description).textSelection(.enabled)
          }
          Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
            row(String(localized: "Origin"), SkillText.origin(record.origin))
            ForEach(record.sightings, id: \.self) { sighting in
              row(
                sighting.agent.kind.name,
                sighting.path.map { SkillText.path($0) }
                  ?? String(localized: "Listed, not found on disk"))
            }
            if !record.realPath.isEmpty {
              row(String(localized: "Real path"), SkillText.path(record.realPath))
            }
          }
          ForEach(SkillText.notes(of: record), id: \.self) { note in
            Label(note, systemImage: "info.circle")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          buttons(record)
          if let preview {
            Text(preview)
              .font(.body.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(8)
              .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      // Read once per skill shown, not on every redraw.
      .task(id: record) { preview = manager.preview(of: record) }
      .accessibilityIdentifier("skills.detail")
    } else {
      Text("Select a skill")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("skills.detail")
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
      Text(value).textSelection(.enabled)
    }
  }

  @ViewBuilder private func buttons(_ record: SkillRecord) -> some View {
    HStack {
      Button("Open") { manager.open(record) }
        .disabled(manager.fileToOpen(record) == nil)
        .accessibilityIdentifier("skills.open")
      Button("Reveal in Finder") { manager.reveal(record) }
        .disabled(record.sightings.allSatisfy { $0.path == nil })
        .accessibilityIdentifier("skills.reveal")
      if record.canShare,
        let other = SkillAgent.allCases.first(where: { record.sighting(for: $0) == nil })
      {
        Button("Share with \(other.kind.shortName)") { manager.share(record) }
          .accessibilityIdentifier("skills.share")
      }
      if manager.isFromGit(record) {
        Button("Update") { Task { await manager.update(record) } }
          .disabled(manager.isFetching)
          .accessibilityIdentifier("skills.update")
      }
      if record.canDelete {
        Button("Delete…", role: .destructive) { delete(record) }
          .accessibilityIdentifier("skills.delete")
      }
    }
  }
}
