import AppKit
import DrakarKit
import SwiftUI

/// The inspector's Permissions tab: the selected session's permission rules, Allow over Ask
/// over Deny, with the folders it may work in and the settings files Claude Code skipped.
/// Rules in a settings file the edit command writes can be removed, and Add Rule… writes new
/// ones. The listing is read when the tab shows, when another session is selected while it
/// shows, after an answer that added rules, and on Refresh; never while the tab is hidden,
/// since this view only exists while it shows.
struct PermissionsInspector: View {
  let project: Project
  @State private var model = PermissionRulesModel()

  var body: some View {
    if let item = project.selected {
      PermissionsDetails(item: item, model: model)
    } else {
      ContentUnavailableView(
        "No Session", systemImage: "lock.shield",
        description: Text("Select a session to see its permission rules."))
    }
  }

  /// The tag at the end of a rule's row, and beside a directory: where it came from, in
  /// Drakar's words for the sources it knows and by the CLI's own name for any other.
  static func sourceLabel(_ source: String) -> String {
    switch source {
    case "userSettings": String(localized: "User")
    case "projectSettings": String(localized: "Project")
    case "localSettings": String(localized: "Local")
    case "flagSettings": String(localized: "Flag")
    case "policySettings": String(localized: "Policy")
    case "cliArg": String(localized: "Command line")
    case "command": String(localized: "Slash command")
    case "session": String(localized: "Session")
    case "mcpServerPolicy", "mcpMount": String(localized: "MCP")
    default: source
    }
  }
}

/// What a listing is read for: another session reads it anew; the same one reads it again
/// once its process starts or goes, or after an answer added rules.
private struct RulesReading: Hashable {
  var session: ProjectSession.ID
  var isLive: Bool
  var revision: Int
}

private struct PermissionsDetails: View {
  let item: ProjectSession
  let model: PermissionRulesModel
  @State private var isAdding = false
  /// The session the last read was for: a change of `RulesReading` for the same one reads
  /// again, which `show` alone would not.
  @State private var readFor: ProjectSession.ID?

  private var reading: RulesReading {
    RulesReading(
      session: item.id, isLive: item.session.hasLiveRules, revision: item.session.rulesRevision)
  }

  /// The listing's state while it lists, else nil.
  private var state: PermissionRulesState? {
    if case .listed(let state, _) = model.listing { state } else { nil }
  }

  var body: some View {
    VStack(spacing: 0) {
      if model.listing != .codex {
        header
        Divider()
      }
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .task(id: reading) {
      let isSameSession = readFor == reading.session
      // Taken afresh each time: whether the session's process answers changes with it.
      model.show(PermissionRulesModel.source(for: item))
      if isSameSession { model.refresh() }
      readFor = reading.session
    }
    .sheet(isPresented: $isAdding) { AddRuleSheet(model: model) }
  }

  /// The tab's own row of controls: the window's toolbar holds the tab picker.
  private var header: some View {
    HStack(spacing: 8) {
      Spacer()
      if model.listing == .loading {
        ProgressView().controlSize(.small)
      } else {
        Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .help(String(localized: "Read the rules again"))
          .accessibilityIdentifier("permissions.refresh")
      }
      Button("Add Rule…", systemImage: "plus") { isAdding = true }
        .controlSize(.small)
        .disabled(state == nil || state?.managedOnly == true)
        .help(
          state?.managedOnly == true
            ? String(localized: "Managed settings allow only their own rules.")
            : String(localized: "Add rules to a settings file")
        )
        .accessibilityIdentifier("permissions.add")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  @ViewBuilder private var content: some View {
    switch model.listing {
    case .idle, .loading:
      VStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Asking Claude Code…").font(.caption).foregroundStyle(.secondary)
      }
    case .codex:
      ContentUnavailableView(
        "No Permission Rules", systemImage: "lock.shield",
        description: Text("Codex sessions have no permission rules."))
    case .failed(let reason):
      ContentUnavailableView {
        Label("Couldn't Read the Rules", systemImage: "exclamationmark.triangle")
      } description: {
        Text(reason).textSelection(.enabled)
      } actions: {
        Button("Retry") { model.refresh() }
          .accessibilityIdentifier("permissions.retry")
      }
    case .listed(let state, let live):
      RulesForm(state: state, live: live, model: model)
    }
  }
}

/// The rules by behavior, an empty one left out, then what the last edit had to say, the
/// session's extra folders and the settings files that did not parse.
private struct RulesForm: View {
  let state: PermissionRulesState
  let live: Bool
  let model: PermissionRulesModel

  /// One behavior's rules, in the CLI's order.
  private struct Group: Identifiable {
    var behavior: PermissionBehavior
    var rules: [PermissionRule]
    var id: PermissionBehavior { behavior }
  }

  private var groups: [Group] {
    PermissionBehavior.allCases.compactMap { behavior in
      let rules = state.rules.filter { $0.behavior == behavior }
      return rules.isEmpty ? nil : Group(behavior: behavior, rules: rules)
    }
  }

  var body: some View {
    let groups = groups
    Form {
      if state.managedOnly {
        Section {
          Label("Managed settings allow only their own rules.", systemImage: "lock")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("permissions.managedOnly")
        }
      }
      ForEach(groups) { group in
        Section {
          ForEach(Array(group.rules.enumerated()), id: \.offset) { index, rule in
            RuleRow(
              rule: rule, isRemoving: model.removing.contains(rule),
              canRemove: !state.managedOnly,
              identifier: "\(group.behavior.rawValue).\(index)"
            ) {
              Task { await model.remove(rule) }
            }
          }
        } header: {
          Text(Self.title(group.behavior))
            .accessibilityIdentifier("permissions.section.\(group.behavior.rawValue)")
        } footer: {
          if group.behavior == groups.last?.behavior, !live { notLive }
        }
      }
      if groups.isEmpty {
        Section {
          Text("No permission rules.").foregroundStyle(.secondary)
        } footer: {
          if !live { notLive }
        }
      }
      if let note = model.note {
        Section {
          Text(note)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityIdentifier("permissions.note")
        }
      }
      if !state.directories.isEmpty {
        Section("Directories") {
          ForEach(Array(state.directories.enumerated()), id: \.offset) { _, directory in
            LabeledContent {
              if !directory.source.isEmpty {
                Text(PermissionsInspector.sourceLabel(directory.source))
              }
            } label: {
              Text(ContentView.abbreviated(URL(filePath: directory.path)))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .help(directory.path)
            }
          }
        }
      }
      if !state.errors.isEmpty {
        Section("Settings Errors") {
          ForEach(Array(state.errors.enumerated()), id: \.offset) { _, error in
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .textSelection(.enabled)
          }
        }
      }
    }
    .formStyle(.grouped)
    .accessibilityIdentifier("inspector.permissions")
  }

  private var notLive: some View {
    Text("This session isn't running, so its own approvals aren't listed.")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  static func title(_ behavior: PermissionBehavior) -> String {
    switch behavior {
    case .allow: String(localized: "Allow")
    case .ask: String(localized: "Ask")
    case .deny: String(localized: "Deny")
    }
  }
}

/// A rule: the CLI's reading of it over the rule itself, or the rule alone, and where it
/// came from. Invisible and control characters show escaped; what is removed or copied is
/// the rule verbatim.
private struct RuleRow: View {
  let rule: PermissionRule
  let isRemoving: Bool
  /// False while managed settings allow only their own rules.
  let canRemove: Bool
  /// `<behavior>.<index>`, for the row's and its Remove button's identifiers.
  let identifier: String
  let remove: () -> Void

  private var shownRule: String { PermissionRule.displayed(rule.rule) }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      VStack(alignment: .leading, spacing: 2) {
        if let description = rule.description {
          Text(
            "\(Text(verbatim: description.prefix))\(Text(verbatim: description.emphasis.map(PermissionRule.displayed) ?? "").fontWeight(.semibold))\(Text(verbatim: description.suffix ?? ""))"
          )
          Text(verbatim: shownRule)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        } else {
          Text(verbatim: shownRule)
            .font(.body.monospaced())
        }
      }
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(PermissionsInspector.sourceLabel(rule.source))
        .font(.caption)
        .foregroundStyle(.secondary)
      if isRemoving {
        ProgressView().controlSize(.small)
      } else if rule.isRemovable {
        Button("Remove Rule", systemImage: "minus.circle", action: remove)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .disabled(!canRemove)
          .help(String(localized: "Remove this rule from its settings file"))
          .accessibilityIdentifier("permissions.remove.\(identifier)")
      }
    }
    .opacity(rule.notInEffect ? 0.5 : 1)
    .modifier(
      Tooltip(
        text: rule.notInEffect
          ? String(localized: "Not in effect: managed settings allow only their own rules")
          : nil)
    )
    .contextMenu {
      if rule.isRemovable {
        Button("Remove Rule", action: remove).disabled(!canRemove || isRemoving)
        Divider()
      }
      Button("Copy Rule") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rule.rule, forType: .string)
      }
    }
    // A container, so the Remove button inside keeps its own identifier.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("permissions.rule.\(identifier)")
  }
}

/// Add Rule…: one rule per line, what they do, and the settings file they go in. A refusal
/// keeps the sheet open with what was typed, the CLI's words under the field.
private struct AddRuleSheet: View {
  let model: PermissionRulesModel
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var behavior = PermissionBehavior.allow
  @State private var file = PermissionRuleFile.localSettings
  @State private var refusal: String?
  @State private var isSaving = false

  private var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Add Permission Rules").font(.headline)
      VStack(alignment: .leading, spacing: 4) {
        TextField(
          "Rules", text: $text, prompt: Text(verbatim: "Bash(npm run test:*)"), axis: .vertical
        )
        .lineLimit(3...8)
        .textFieldStyle(.roundedBorder)
        .font(.body.monospaced())
        .accessibilityIdentifier("permissions.sheet.rules")
        Text("One rule per line; ⌥Return starts a new line.")
          .font(.caption)
          .foregroundStyle(.secondary)
        if let refusal {
          Text(refusal)
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("permissions.sheet.error")
        }
      }
      Picker("Behavior", selection: $behavior) {
        Text("Allow").tag(PermissionBehavior.allow)
        Text("Ask").tag(PermissionBehavior.ask)
        Text("Deny").tag(PermissionBehavior.deny)
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("permissions.sheet.behavior")
      Picker("Save in", selection: $file) {
        Text("This project, only you").tag(PermissionRuleFile.localSettings)
        Text("This project, shared").tag(PermissionRuleFile.projectSettings)
        Text("All projects").tag(PermissionRuleFile.userSettings)
      }
      .accessibilityIdentifier("permissions.sheet.file")
      HStack {
        Spacer()
        if isSaving { ProgressView().controlSize(.small) }
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add", action: save)
          .keyboardShortcut(.defaultAction)
          .disabled(isBlank || isSaving)
          .accessibilityIdentifier("permissions.sheet.add")
      }
    }
    .padding(20)
    .frame(width: 440)
  }

  /// Sends the rules; the sheet closes once they are saved and read back, and stays with a
  /// refusal.
  private func save() {
    guard !isBlank, !isSaving else { return }
    isSaving = true
    refusal = nil
    Task {
      let refused = await model.add(text, behavior: behavior, file: file)
      isSaving = false
      if let refused { refusal = refused } else { dismiss() }
    }
  }
}
