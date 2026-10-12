import AppKit
import DrakarKit
import SwiftUI

/// Run in Each Subfolder: a session per subfolder of a parent, each sent one skill
/// (docs/superpowers/specs/2026-10-12-skill-fanout-design.md §3). Without a skill, it asks for
/// one first.
struct SkillFanOutSheet: View {
  let project: Project
  let request: FanOutRequest
  @State private var draft: FanOutDraft?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Group {
      if let draft {
        FanOutForm(draft: draft, project: project, dismiss: { dismiss() })
      } else {
        FanOutSkillPicker(skills: project.fanOutSkills, cancel: { dismiss() }) { skill in
          draft = makeDraft(skill)
        }
      }
    }
    .frame(width: 520, height: 560)
    .onAppear {
      if draft == nil, let skill = request.skill { draft = makeDraft(skill) }
      if request.skill == nil { project.capabilities.loadIfNeeded() }
    }
  }

  private func makeDraft(_ skill: SkillEntry) -> FanOutDraft {
    FanOutDraft(
      skill: skill, agent: project.skillsAgent, parent: project.folder,
      account: AccountStore.shared.windowAccount(for: project.folder).directory)
  }
}

/// The Session menu's way in: which skill to run.
private struct FanOutSkillPicker: View {
  let skills: [SkillEntry]
  let cancel: () -> Void
  let pick: (SkillEntry) -> Void
  @State private var filter = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Run a Skill in Each Subfolder").font(.headline)
      TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
      List(skills.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) {
        skill in
        Button {
          pick(skill)
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text("/\(skill.name)").font(.body.monospaced())
            if !skill.description.isEmpty {
              Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("fanout.skill.\(skill.name)")
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
  }
}

/// The folders, what each session is sent, and how many run at once.
private struct FanOutForm: View {
  @Bindable var draft: FanOutDraft
  let project: Project
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Run /\(draft.skill.name) in Each Subfolder").font(.headline)
      HStack {
        Text(draft.parent.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Change…", action: chooseParent)
      }
      HStack {
        Toggle("Git repositories only", isOn: $draft.gitOnly)
        Spacer()
        Button("Select All") { draft.tickAll(true) }
        Button("Select None") { draft.tickAll(false) }
      }
      List(draft.shown) { folder in
        Toggle(
          isOn: Binding(get: { draft.isTicked(folder) }, set: { draft.setTicked(folder, $0) })
        ) {
          HStack {
            Text(folder.name)
            if let note = note(folder) {
              Text(note).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .accessibilityIdentifier("fanout.folder.\(folder.name)")
      }
      .overlay {
        if draft.shown.isEmpty {
          Text(draft.gitOnly ? "No git repositories here." : "No subfolders here.")
            .foregroundStyle(.secondary)
        }
      }
      if draft.reachUnchecked {
        Text("Couldn't check which folders have this skill.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Form {
        if draft.skill.takesArguments {
          TextField("Arguments", text: $draft.arguments, prompt: Text(draft.skill.argumentHint))
        }
        Picker("Mode", selection: $draft.mode) {
          Text("Default").tag(PermissionMode?.none)
          ForEach(modes, id: \.self) { mode in Text(mode.title).tag(Optional(mode)) }
        }
        TextField("Run at most", text: $draft.limitText, prompt: Text("Unlimited"))
          .accessibilityIdentifier("fanout.limit")
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: dismiss).keyboardShortcut(.cancelAction)
        Button("Start \(draft.chosen.count) Sessions") {
          draft.start(in: project)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(draft.chosen.isEmpty)
        .accessibilityIdentifier("fanout.start")
      }
    }
    .padding(20)
  }

  private var modes: [PermissionMode] {
    PermissionMode.allCases.filter { $0 != .bypass || ClaudeChoice.allowsBypass }
  }

  private func note(_ folder: Subfolder) -> String? {
    if !draft.reaches(folder) { return String(localized: "Not available here") }
    if !folder.isGitRepository { return String(localized: "Not a git repository") }
    return nil
  }

  private func chooseParent() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.directoryURL = draft.parent
    guard panel.runModal() == .OK, let url = panel.url else { return }
    draft.change(parent: url)
  }
}
