import DrakarKit
import SwiftUI

/// What an install starts from: the skills found in a chosen folder, or a git address still
/// to fetch.
struct InstallRequest: Identifiable {
  enum Source {
    case folder([URL])
    case git
  }

  let id = UUID()
  var source: Source
}

/// Install from Folder… and Install from Git…: which skills, which place, which agents, and
/// for a folder whether to link or copy.
struct InstallSheet: View {
  let request: InstallRequest
  let manager: SkillsManager
  @Environment(\.dismiss) private var dismiss
  @State private var address = ""
  @State private var found: [URL] = []
  @State private var picked: Set<URL> = []
  @State private var place: SkillPlace = .user
  @State private var forClaude = true
  @State private var forCodex = true
  @State private var method: InstallMethod = .link
  @State private var note: String?

  private var isGit: Bool {
    if case .git = request.source { true } else { false }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(isGit ? "Install from Git" : "Install from Folder").font(.headline)
      if isGit {
        HStack {
          TextField(
            "Repository", text: $address,
            prompt: Text("https://github.com/owner/repo or git@host:owner/repo")
          )
          .textFieldStyle(.roundedBorder)
          .onSubmit(fetch)
          .accessibilityIdentifier("skills.git.url")
          if manager.isFetching {
            ProgressView().controlSize(.small)
          } else {
            Button("Fetch", action: fetch)
              .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
              .accessibilityIdentifier("skills.git.fetch")
          }
        }
        if let note {
          Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
      if found.count > 1 || (isGit && !found.isEmpty) {
        Text("Skills").font(.subheadline).foregroundStyle(.secondary)
        ScrollView {
          VStack(alignment: .leading) {
            ForEach(found, id: \.self) { folder in
              Toggle(folder.lastPathComponent, isOn: binding(folder))
                .help(SkillText.path(folder))
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
      } else if let only = found.first {
        Text(SkillText.path(only)).font(.callout.monospaced()).foregroundStyle(.secondary)
      }
      if !found.isEmpty {
        Picker("Place", selection: $place) {
          Text("Yours").tag(SkillPlace.user)
          if manager.project != nil { Text("This project").tag(SkillPlace.project) }
        }
        .pickerStyle(.segmented)
        HStack {
          Text("Agents")
          Toggle("Claude Code", isOn: $forClaude)
          Toggle("Codex", isOn: $forCodex)
        }
        if !isGit {
          Picker("Method", selection: $method) {
            Text("Link to it where it is").tag(InstallMethod.link)
            Text("Copy into the place's folder").tag(InstallMethod.copy)
          }
          .pickerStyle(.radioGroup)
        }
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Install") {
          manager.install(
            found.filter(picked.contains), place: place, agents: agents,
            method: isGit ? .link : method)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(picked.isEmpty || agents.isEmpty)
        .accessibilityIdentifier("skills.install.confirm")
      }
    }
    .padding(20)
    .frame(width: 520)
    .onAppear {
      if case .folder(let folders) = request.source {
        found = folders
        picked = Set(folders)
      }
    }
  }

  private var agents: [SkillAgent] {
    (forClaude ? [.claude] : []) + (forCodex ? [.codex] : [])
  }

  private func binding(_ folder: URL) -> Binding<Bool> {
    Binding(
      get: { picked.contains(folder) },
      set: { if $0 { picked.insert(folder) } else { picked.remove(folder) } })
  }

  private func fetch() {
    note = nil
    Task {
      do {
        let skills = try await manager.fetch(address)
        found = skills
        picked = Set(skills)
        if skills.isEmpty {
          note = String(localized: "The repository has no SKILL.md in its first four levels.")
        }
      } catch {
        note = error.localizedDescription
      }
    }
  }
}

/// A delete waiting for its confirmation.
struct DeleteRequest: Identifiable {
  let id = UUID()
  let record: SkillRecord
  let plan: DeletePlan
}

/// Says exactly what a delete does, sighting by sighting, before it does it.
struct DeleteSheet: View {
  let request: DeleteRequest
  let manager: SkillsManager
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Delete \(request.record.name)?").font(.headline)
      // One line per step, as the plan words them.
      ForEach(Array(request.plan.lines.enumerated()), id: \.offset) { _, line in
        Label(line, systemImage: "arrow.right.circle")
          .fixedSize(horizontal: false, vertical: true)
      }
      // Then what stays, which is no step.
      ForEach(request.plan.notes, id: \.self) { note in
        Label(note, systemImage: "info.circle")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Delete", role: .destructive) {
          manager.delete(request.plan)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("skills.delete.confirm")
      }
    }
    .padding(20)
    .frame(width: 480)
  }
}
