import DrakarKit
import SwiftUI

struct ComposerShortcut: Codable, Identifiable {
  enum Kind: String, Codable {
    case skill, prompt
  }

  var id = UUID()
  var label = ""
  var isEnabled = true
  var kind: Kind = .prompt
  var skill = ""
  var prompt = ""

  static func read(_ data: Data) -> [Self] {
    (try? JSONDecoder().decode([Self].self, from: data)) ?? []
  }

  var title: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }

  var skillName: String {
    let name = skill.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.hasPrefix("/") ? String(name.dropFirst()) : name
  }
}

struct ComposerShortcutsPane: View {
  @AppStorage(PreferenceKey.composerShortcuts) private var data = Data()
  @AppStorage(PreferenceKey.favoriteComposerShortcut) private var favorite = ""
  private let skills = SkillsManager.shared

  private var shortcuts: [ComposerShortcut] {
    get { ComposerShortcut.read(data) }
    nonmutating set {
      if let encoded = try? JSONEncoder().encode(newValue) { data = encoded }
    }
  }

  private var skillNames: [String] { Set(skills.records.map(\.name)).sorted() }

  var body: some View {
    Form {
      Section {
        Picker("Show in toolbar", selection: $favorite) {
          Text("None").tag("")
          ForEach(shortcuts) { shortcut in
            Text(shortcut.title.isEmpty ? String(localized: "Untitled Shortcut") : shortcut.title)
              .tag(shortcut.id.uuidString)
          }
        }
        Button("Add Shortcut", systemImage: "plus") {
          shortcuts.append(ComposerShortcut())
        }
      } footer: {
        Text(
          "Enabled shortcuts appear next to Attach. Choose one to fill the composer, then press Return to send."
        )
      }

      ForEach(Binding(get: { shortcuts }, set: { shortcuts = $0 })) { $shortcut in
        Section {
          TextField("Label", text: $shortcut.label, prompt: Text("Commit"))
          Toggle("Enabled", isOn: $shortcut.isEnabled)
          Picker("Action", selection: $shortcut.kind) {
            Text("Prompt").tag(ComposerShortcut.Kind.prompt)
            Text("Skill").tag(ComposerShortcut.Kind.skill)
          }
          switch shortcut.kind {
          case .prompt:
            TextField("Prompt", text: $shortcut.prompt, axis: .vertical)
              .lineLimit(2...6)
          case .skill:
            LabeledContent("Skill") {
              TextField("Skill name", text: $shortcut.skill, prompt: Text("commit-task"))
                .labelsHidden()
              if !skillNames.isEmpty {
                Menu("Choose Skill") {
                  ForEach(skillNames, id: \.self) { name in
                    Button(name) { shortcut.skill = name }
                  }
                }
              }
            }
          }
          Button("Remove Shortcut", role: .destructive) {
            let id = shortcut.id
            if favorite == id.uuidString { favorite = "" }
            shortcuts.removeAll { $0.id == id }
          }
        }
      }
    }
    .formStyle(.grouped)
    .onChange(of: shortcuts.contains { $0.kind == .skill }, initial: true) { _, hasSkills in
      if hasSkills { skills.refresh(load: true) }
    }
  }
}
