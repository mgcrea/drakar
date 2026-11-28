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

/// Which shortcuts are their own buttons in the composer toolbar, in the order they were
/// pinned. Stored in `PreferenceKey.favoriteComposerShortcut` as a JSON array of ids, or as
/// one bare id from when only a single shortcut could be pinned.
enum ComposerToolbarPins {
  /// Room for buttons beside the effort level without crowding the model pills.
  static let limit = 4

  static func ids(in stored: String) -> [String] {
    let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let decoded: [String]
    if trimmed.first == "[" {
      guard let data = trimmed.data(using: .utf8),
        let list = try? JSONDecoder().decode([String].self, from: data)
      else { return [] }
      decoded = list
    } else {
      decoded = [trimmed]
    }
    var seen = Set<String>()
    return decoded.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(limit).map { $0 }
  }

  static func stored(_ ids: [String]) -> String {
    var seen = Set<String>()
    let unique = Array(ids.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(limit))
    guard !unique.isEmpty, let data = try? JSONEncoder().encode(unique),
      let text = String(data: data, encoding: .utf8)
    else { return "" }
    return text
  }

  /// `on` pins `id` at the end, until `limit`. Off takes it out. An id already in the list stays
  /// where it is.
  static func setting(_ id: String, on: Bool, among ids: [String]) -> String {
    guard !id.isEmpty else { return stored(ids) }
    var next = ids
    if on {
      guard !next.contains(id), next.count < limit else { return stored(next) }
      next.append(id)
    } else {
      next.removeAll { $0 == id }
    }
    return stored(next)
  }
}

struct ComposerShortcutsPane: View {
  @AppStorage(PreferenceKey.composerShortcuts) private var data = Data()
  @AppStorage(PreferenceKey.favoriteComposerShortcut) private var toolbarPins = ""
  private let skills = SkillsManager.shared

  private var shortcuts: [ComposerShortcut] {
    get { ComposerShortcut.read(data) }
    nonmutating set {
      if let encoded = try? JSONEncoder().encode(newValue) { data = encoded }
    }
  }

  private var skillNames: [String] { Set(skills.records.map(\.name)).sorted() }

  /// Pins that still name a shortcut. A deleted shortcut's id drops out of the count, so it
  /// does not hold a slot.
  private var pinnedIDs: [String] {
    let known = Set(shortcuts.map(\.id.uuidString))
    return ComposerToolbarPins.ids(in: toolbarPins).filter { known.contains($0) }
  }

  private var toolbarSummary: String {
    let titles = pinnedIDs.compactMap { id in
      shortcuts.first { $0.id.uuidString == id }?.displayTitle
    }
    if titles.isEmpty { return String(localized: "None") }
    return titles.joined(separator: ", ")
  }

  private func pinBinding(_ id: String) -> Binding<Bool> {
    Binding(
      get: { pinnedIDs.contains(id) },
      set: { on in
        toolbarPins = ComposerToolbarPins.setting(id, on: on, among: pinnedIDs)
      })
  }

  private func pinToggle(_ shortcut: ComposerShortcut) -> some View {
    let id = shortcut.id.uuidString
    let on = pinnedIDs.contains(id)
    return Toggle(isOn: pinBinding(id)) {
      if let iconName = shortcut.iconName {
        Label(shortcut.displayTitle, systemImage: iconName)
      } else {
        Text(shortcut.displayTitle)
      }
    }
    .disabled(!on && pinnedIDs.count >= ComposerToolbarPins.limit)
  }

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
        LabeledContent("Show in toolbar") {
          Menu {
            Button("None") { toolbarPins = "" }
              .disabled(pinnedIDs.isEmpty)
            if !shortcuts.isEmpty { Divider() }
            ForEach(shortcuts) { shortcut in
              pinToggle(shortcut)
            }
            if pinnedIDs.count >= ComposerToolbarPins.limit {
              Divider()
              Button("Up to \(ComposerToolbarPins.limit) shortcuts") {}
                .disabled(true)
            }
          } label: {
            Text(toolbarSummary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          .fixedSize()
          .disabled(shortcuts.isEmpty)
          .help(toolbarSummary)
          .accessibilityIdentifier("composerShortcut.toolbar")
        }
        Button("Add Shortcut", systemImage: "plus") {
          shortcuts.append(ComposerShortcut())
        }
      } footer: {
        Text(
          "Enabled shortcuts appear next to Attach. Choose up to \(ComposerToolbarPins.limit) to show as buttons. Further ones stay in the shortcuts menu. A shortcut with an icon shows only the icon."
        )
      }

      ForEach(Binding(get: { shortcuts }, set: { shortcuts = $0 })) { $shortcut in
        Section {
          TextField("Label", text: $shortcut.label, prompt: Text("Commit"))
          LabeledContent("Icon") {
            ShortcutIconPicker(icon: $shortcut.icon)
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
            toolbarPins = ComposerToolbarPins.stored(
              ComposerToolbarPins.ids(in: toolbarPins).filter { $0 != id.uuidString })
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

/// The icon well. Clicking it opens the preset symbols; the chosen one is drawn on the well.
private struct ShortcutIconPicker: View {
  @Binding var icon: String
  @State private var isPresented = false

  private var symbol: String? { ComposerShortcut(icon: icon).iconName }

  private var symbolTitle: String {
    guard let symbol else { return String(localized: "None") }
    return ComposerShortcutsPane.presetIcons.first { $0.symbol == symbol }?.name ?? symbol
  }

  var body: some View {
    Button {
      isPresented = true
    } label: {
      Image(systemName: symbol ?? "square.dashed")
        .frame(width: 22, height: 18)
        .foregroundStyle(symbol == nil ? .tertiary : .primary)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .fixedSize()
    .accessibilityIdentifier("composerShortcut.icon")
    .accessibilityLabel("Choose icon")
    .accessibilityValue(symbolTitle)
    .help(symbol == nil ? "Choose an icon" : symbolTitle)
    .popover(isPresented: $isPresented) {
      ShortcutIconGrid(selection: symbol) { picked in
        icon = picked
        isPresented = false
      }
      .padding(10)
    }
  }
}

/// The preset symbols, five across. The first cell clears the icon.
private struct ShortcutIconGrid: View {
  var selection: String?
  var pick: (String) -> Void

  private static let columnCount = 5

  private var cells: [(symbol: String?, title: String)] {
    [(nil, String(localized: "None"))]
      + ComposerShortcutsPane.presetIcons.map { (symbol: $0.symbol, title: $0.name) }
  }

  var body: some View {
    let rows = stride(from: 0, to: cells.count, by: Self.columnCount).map { start in
      Array(cells[start..<min(start + Self.columnCount, cells.count)])
    }
    VStack(alignment: .leading, spacing: 4) {
      ForEach(rows.indices, id: \.self) { index in
        HStack(spacing: 4) {
          ForEach(rows[index].indices, id: \.self) { column in
            cell(rows[index][column])
          }
        }
      }
    }
  }

  private func cell(_ item: (symbol: String?, title: String)) -> some View {
    let chosen = selection == item.symbol
    return Button {
      pick(item.symbol ?? "")
    } label: {
      Image(systemName: item.symbol ?? "square.dashed")
        .frame(width: 28, height: 28)
        .background(
          chosen ? Color.accentColor.opacity(0.18) : Color.clear,
          in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
          if chosen {
            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1)
          }
        }
    }
    .buttonStyle(.borderless)
    .help(item.title)
    .accessibilityLabel(item.title)
  }
}
