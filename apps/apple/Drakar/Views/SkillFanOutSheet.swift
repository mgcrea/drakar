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
      if request.skill == nil { project.loadFanOutSkills() }
    }
  }

  private func makeDraft(_ skill: SkillEntry) -> FanOutDraft {
    FanOutDraft(
      skill: skill, agent: project.skillsAgent, parent: project.folder,
      account: AccountStore.shared.windowAccount(for: project.folder),
      source: project.folder)
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
      .overlay {
        if skills.isEmpty { Text("No skills yet.").foregroundStyle(.secondary) }
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
        // Shown for every skill: one that declares no hint can still take text after its name.
        TextField(
          "Arguments", text: $draft.arguments,
          prompt: Text(draft.skill.takesArguments ? draft.skill.argumentHint : "Optional")
        )
        .accessibilityIdentifier("fanout.arguments")
        if draft.agent == .claude, accounts.count > 1 {
          Picker("Account", selection: accountKey) {
            ForEach(accounts, id: \.key) { account in
              Text(AccountStore.shared.profile(for: account).name).tag(account.key)
            }
          }
          .accessibilityIdentifier("fanout.account")
        }
        Picker("Mode", selection: $draft.mode) {
          Text("Default").tag(PermissionMode?.none)
          ForEach(draft.offeredModes, id: \.self) { mode in
            Text(mode.title).tag(Optional(mode))
          }
        }
        TextField("Run at most", text: $draft.limitText, prompt: Text("Unlimited"))
          .accessibilityIdentifier("fanout.limit")
      }
      HStack {
        // Disabled rather than refused on the click: a refused start would close the sheet
        // and lose the arguments typed into it.
        if !EntitlementMonitor.allowsWorkNow {
          Text("Starting sessions needs a licence or a trial.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel", role: .cancel, action: dismiss).keyboardShortcut(.cancelAction)
        Button("Start \(draft.chosen.count) Sessions") {
          draft.start(in: project)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(draft.chosen.isEmpty || !EntitlementMonitor.allowsWorkNow)
        .accessibilityIdentifier("fanout.start")
      }
    }
    .padding(20)
  }

  /// Every account, the window's first among them when discovery missed it.
  private var accounts: [ClaudeAccount] {
    let store = AccountStore.shared
    let all = store.accounts.isEmpty ? [store.shellAccount] : store.accounts
    return all.contains { $0.key == draft.account.key } ? all : [draft.account] + all
  }

  /// By key: the same directory with and without its trailing slash is one account.
  private var accountKey: Binding<String> {
    Binding(
      get: { draft.account.key },
      set: { key in
        if let account = accounts.first(where: { $0.key == key }) { draft.account = account }
      })
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
