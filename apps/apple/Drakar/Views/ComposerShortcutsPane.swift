import AppKit
import DrakarKit
import SwiftUI

struct ComposerShortcut: Codable, Identifiable {
  enum Kind: String, Codable {
    case skill, prompt
  }

  var id = UUID()
  var label = ""
  var icon = ""
  var isEnabled = true
  var kind: Kind = .prompt
  var skill = ""
  var prompt = ""
  var autoSend = false
  var autoClose = false

  init(
    id: UUID = UUID(), label: String = "", icon: String = "", isEnabled: Bool = true,
    kind: Kind = .prompt, skill: String = "", prompt: String = "", autoSend: Bool = false,
    autoClose: Bool = false
  ) {
    self.id = id
    self.label = label
    self.icon = icon
    self.isEnabled = isEnabled
    self.kind = kind
    self.skill = skill
    self.prompt = prompt
    self.autoSend = autoSend
    self.autoClose = autoClose
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
    icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? ""
    isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .prompt
    skill = try container.decodeIfPresent(String.self, forKey: .skill) ?? ""
    prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    autoSend = try container.decodeIfPresent(Bool.self, forKey: .autoSend) ?? false
    autoClose = try container.decodeIfPresent(Bool.self, forKey: .autoClose) ?? false
  }

  static func read(_ data: Data) -> [Self] {
    (try? JSONDecoder().decode([Self].self, from: data)) ?? []
  }

  var title: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }

  var iconName: String? {
    let name = icon.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    else { return nil }
    return name
  }

  var hasTrigger: Bool { !title.isEmpty || iconName != nil }

  var displayTitle: String {
    if !title.isEmpty { return title }
    if kind == .skill, !skillName.isEmpty { return "/\(skillName)" }
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if kind == .prompt, !trimmedPrompt.isEmpty { return String(trimmedPrompt.prefix(40)) }
    return String(localized: "Untitled Shortcut")
  }

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

  static let presetIcons: [(name: String, symbol: String)] = [
    ("Checkmark", "checkmark.circle"),
    ("Branch", "arrow.triangle.branch"),
    ("Push", "arrow.up.circle"),
    ("Send", "paperplane"),
    ("Build", "hammer"),
    ("Tools", "wrench.and.screwdriver"),
    ("Sparkles", "sparkles"),
    ("Bolt", "bolt"),
    ("Search", "magnifyingglass"),
    ("Debug", "ladybug"),
    ("Document", "doc.text"),
    ("Clean", "trash"),
    ("Run", "play"),
    ("Flag", "flag"),
  ]

  var body: some View {
    Form {
      Section {
        Picker("Show in toolbar", selection: $favorite) {
          Text("None").tag("")
          ForEach(shortcuts) { shortcut in
            if let iconName = shortcut.iconName {
              Label(shortcut.displayTitle, systemImage: iconName)
                .tag(shortcut.id.uuidString)
            } else {
              Text(shortcut.displayTitle)
                .tag(shortcut.id.uuidString)
            }
          }
        }
        Button("Add Shortcut", systemImage: "plus") {
          shortcuts.append(ComposerShortcut())
        }
      } footer: {
        Text(
          "Enabled shortcuts appear next to Attach. Shortcuts with an icon show only the icon in the toolbar."
        )
      }

      ForEach(Binding(get: { shortcuts }, set: { shortcuts = $0 })) { $shortcut in
        Section {
          TextField("Label", text: $shortcut.label, prompt: Text("Commit"))
          LabeledContent("Icon") {
            if let iconName = shortcut.iconName {
              Image(systemName: iconName)
                .foregroundStyle(.secondary)
            }
            TextField("SF Symbol", text: $shortcut.icon, prompt: Text("Optional"))
              .labelsHidden()
            Menu("Choose Icon") {
              Button("None") { shortcut.icon = "" }
              Divider()
              ForEach(Self.presetIcons, id: \.symbol) { preset in
                Button {
                  shortcut.icon = preset.symbol
                } label: {
                  Label(preset.name, systemImage: preset.symbol)
                }
              }
            }
          }
          Toggle("Enabled", isOn: $shortcut.isEnabled)
          Toggle("Send immediately", isOn: $shortcut.autoSend)
          Toggle("Close conversation after turn", isOn: $shortcut.autoClose)
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
