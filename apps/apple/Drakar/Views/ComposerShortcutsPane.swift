import AppKit
import Carbon.HIToolbox
import DrakarKit
import SwiftUI

struct ComposerShortcut: Codable, Identifiable {
  enum Kind: String, Codable {
    case skill, prompt
  }

  /// Whether running the shortcut arms "closes tab after turn". Shift is the keys held
  /// at that moment, on a click or on the chord. A chord that already includes Shift
  /// counts as held.
  enum CloseAfterTurn: String, Codable, CaseIterable {
    case off
    case always
    case whenShift
    case unlessShift

    /// The Shift cases treat an extra Shift on a chord that does not include it as
    /// part of the same shortcut.
    var followsShift: Bool {
      switch self {
      case .whenShift, .unlessShift: true
      case .off, .always: false
      }
    }

    func closes(whenShiftHeld shiftHeld: Bool) -> Bool {
      switch self {
      case .off: false
      case .always: true
      case .whenShift: shiftHeld
      case .unlessShift: !shiftHeld
      }
    }

    var helpNote: String? {
      switch self {
      case .off: nil
      case .always: String(localized: "closes tab after turn")
      case .whenShift: String(localized: "closes tab after turn when Shift is pressed")
      case .unlessShift: String(localized: "closes tab after turn unless Shift is pressed")
      }
    }
  }

  var id = UUID()
  var label = ""
  var icon = ""
  var isEnabled = true
  var kind: Kind = .prompt
  var skill = ""
  var prompt = ""
  var autoSend = false
  var closeAfterTurn: CloseAfterTurn = .off
  /// The keys that run this shortcut in the session window. None until one is recorded.
  var keyChord: ComposerKeyChord? = nil

  init(
    id: UUID = UUID(), label: String = "", icon: String = "", isEnabled: Bool = true,
    kind: Kind = .prompt, skill: String = "", prompt: String = "", autoSend: Bool = false,
    closeAfterTurn: CloseAfterTurn = .off, keyChord: ComposerKeyChord? = nil
  ) {
    self.id = id
    self.label = label
    self.icon = icon
    self.isEnabled = isEnabled
    self.kind = kind
    self.skill = skill
    self.prompt = prompt
    self.autoSend = autoSend
    self.closeAfterTurn = closeAfterTurn
    self.keyChord = keyChord
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
    // `autoClose` was a bool. True is Always. False, or no key, is Off.
    if let mode = try container.decodeIfPresent(CloseAfterTurn.self, forKey: .closeAfterTurn) {
      closeAfterTurn = mode
    } else {
      let legacy = try decoder.container(keyedBy: BoolCloseKey.self)
      let wasOn = try legacy.decodeIfPresent(Bool.self, forKey: .autoClose) ?? false
      closeAfterTurn = wasOn ? .always : .off
    }
    keyChord = try container.decodeIfPresent(ComposerKeyChord.self, forKey: .keyChord)
  }

  private enum BoolCloseKey: String, CodingKey {
    case autoClose
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
          "Enabled shortcuts appear to the right of the effort level. Choose up to \(ComposerToolbarPins.limit) to show as buttons. Further ones stay in the shortcuts menu. A shortcut with an icon shows only the icon. Record a keyboard shortcut with ⌘, ⌥ or ⌃. It runs in the key session window while the composer is empty. ⌫ clears it. Close after the turn can stay off, always arm, or follow whether Shift is held when the shortcut runs."
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
          Picker("Close conversation after turn", selection: $shortcut.closeAfterTurn) {
            Text("Off").tag(ComposerShortcut.CloseAfterTurn.off)
            Text("Always").tag(ComposerShortcut.CloseAfterTurn.always)
            Text("When Shift is pressed").tag(ComposerShortcut.CloseAfterTurn.whenShift)
            Text("Unless Shift is pressed").tag(ComposerShortcut.CloseAfterTurn.unlessShift)
          }
          .help(
            "Shift is read when the shortcut runs, from a click or its keys. A chord that already includes Shift counts as pressed."
          )
          .accessibilityIdentifier("composerShortcut.closeAfterTurn")
          LabeledContent("Keyboard Shortcut") {
            ComposerShortcutRecorder(
              chord: $shortcut.keyChord,
              others: shortcuts.compactMap { other in
                guard other.id != shortcut.id, let chord = other.keyChord else { return nil }
                return (title: other.displayTitle, chord: chord)
              })
          }
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

/// The keys that run a composer shortcut. A modifier other than Shift is required, except
/// on a function key: a bare letter would be typed into the composer.
struct ComposerKeyChord: Codable, Equatable {
  var key: String
  var command = false
  var option = false
  var control = false
  var shift = false

  /// Why a key was not recorded. A bare Escape cancels and a bare Delete clears, so neither
  /// is an outcome of recording.
  enum Rejection: Error, Equatable {
    case needsModifier
    case unsupported
  }

  /// What the settings row shows, in the menu's order: ⌃ ⌥ ⇧ ⌘, then the key.
  var display: String {
    var text = ""
    if control { text.append("⌃") }
    if option { text.append("⌥") }
    if shift { text.append("⇧") }
    if command { text.append("⌘") }
    text.append(Self.label(for: key))
    return text
  }

  var eventModifiers: SwiftUI.EventModifiers {
    var mask = SwiftUI.EventModifiers()
    if command { mask.insert(.command) }
    if option { mask.insert(.option) }
    if control { mask.insert(.control) }
    if shift { mask.insert(.shift) }
    return mask
  }

  /// The key SwiftUI can put on a menu item. None when the token is not one it can show.
  var keyEquivalent: SwiftUI.KeyEquivalent? {
    switch key {
    case "space": return SwiftUI.KeyEquivalent(" ")
    case "return": return .return
    case "tab": return .tab
    case "delete": return .delete
    case "escape": return .escape
    case "left": return .leftArrow
    case "right": return .rightArrow
    case "up": return .upArrow
    case "down": return .downArrow
    default:
      if let function = Self.functionScalar(for: key) {
        return SwiftUI.KeyEquivalent(Character(function))
      }
      guard let character = key.first, key.count == 1 else { return nil }
      return SwiftUI.KeyEquivalent(character)
    }
  }

  /// The chord those keys make, or why they do not.
  static func record(
    keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?
  ) -> Result<ComposerKeyChord, Rejection> {
    let held = flags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
    let command = held.contains(.command)
    let option = held.contains(.option)
    let control = held.contains(.control)
    let shift = held.contains(.shift)
    let token = token(for: keyCode)
    let function = token.map { functionScalar(for: $0) != nil } ?? false
    guard command || option || control || function else { return .failure(.needsModifier) }
    let key: String
    if let token {
      key = token
    } else if let character = characters?.first(where: { !$0.isWhitespace || $0 == " " }) {
      key = String(character).lowercased()
    } else {
      return .failure(.unsupported)
    }
    return .success(
      ComposerKeyChord(
        key: key, command: command, option: option, control: control, shift: shift))
  }

  /// Whether this event is the chord. Caps Lock is ignored. A special key matches by its
  /// key code; a letter matches the character, so the layout the person types with is the
  /// one that was recorded. `allowingExtraShift` also accepts Shift held on a chord that
  /// does not include it, which is how a close mode can follow Shift.
  func matches(_ event: NSEvent, allowingExtraShift: Bool = false) -> Bool {
    let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(
      .capsLock)
    let shiftHeld = held.contains(.shift)
    let shiftMatches = shiftHeld == shift || (allowingExtraShift && !shift && shiftHeld)
    guard held.contains(.command) == command, held.contains(.option) == option,
      held.contains(.control) == control, shiftMatches
    else { return false }
    if let token = Self.token(for: event.keyCode) { return token == key }
    return event.charactersIgnoringModifiers?.lowercased() == key
  }

  /// An enabled menu item already owns this key. The main menu is checked before a composer
  /// shortcut takes it, so a chord Drakar already uses keeps doing what the menu says.
  static func menuClaims(_ event: NSEvent, menu: NSMenu?) -> Bool {
    guard let menu else { return false }
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
    for item in menu.items {
      if item.isEnabled, !item.keyEquivalent.isEmpty,
        item.keyEquivalent.lowercased() == typed,
        item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
          == flags
      {
        return true
      }
      if menuClaims(event, menu: item.submenu) { return true }
    }
    return false
  }

  private static func label(for key: String) -> String {
    switch key {
    case "space": "Space"
    case "return": "↩"
    case "tab": "⇥"
    case "delete": "⌫"
    case "escape": "⎋"
    case "left": "←"
    case "right": "→"
    case "up": "↑"
    case "down": "↓"
    default: key.uppercased()
    }
  }

  /// F1 is U+F704 and each following function key is the next scalar, which is what a menu
  /// item's key equivalent uses.
  private static func functionScalar(for token: String) -> Unicode.Scalar? {
    guard token.hasPrefix("f"), let number = Int(token.dropFirst()), (1...20).contains(number)
    else { return nil }
    return Unicode.Scalar(UInt32(NSF1FunctionKey + number - 1))
  }

  private static func token(for keyCode: UInt16) -> String? {
    tokens[Int(keyCode)]
  }

  private static let tokens: [Int: String] = {
    var map: [Int: String] = [
      kVK_Space: "space", kVK_Return: "return", kVK_ANSI_KeypadEnter: "return",
      kVK_Tab: "tab", kVK_Delete: "delete", kVK_ForwardDelete: "delete",
      kVK_Escape: "escape",
      kVK_LeftArrow: "left", kVK_RightArrow: "right", kVK_UpArrow: "up", kVK_DownArrow: "down",
    ]
    let functions = [
      kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11,
      kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
    for (index, code) in functions.enumerated() { map[code] = "f\(index + 1)" }
    return map
  }()
}

/// Set while a settings row is recording, so the session window does not run the old chord
/// on the key that is being saved.
enum ComposerShortcutCapture {
  static var isRecording = false
  static var stop: (() -> Void)?
}

/// Records the next chord typed into this window. Escape cancels. Delete with no modifier
/// clears. A chord another shortcut already has is refused.
private struct ComposerShortcutRecorder: View {
  @Binding var chord: ComposerKeyChord?
  var others: [(title: String, chord: ComposerKeyChord)]

  @State private var recording = false
  @State private var monitor: Any?
  @State private var rejection: ComposerKeyChord.Rejection?
  @State private var takenBy: String?

  var body: some View {
    HStack(spacing: 8) {
      if let takenBy {
        Text("Already used by \(takenBy)")
          .font(.caption)
          .foregroundStyle(.orange)
      } else if let rejection {
        Text(rejection == .needsModifier ? "Include ⌘, ⌥ or ⌃" : "That key can't be a shortcut")
          .font(.caption)
          .foregroundStyle(.orange)
      } else if recording {
        Text("Esc cancels, ⌫ clears")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Button {
        if recording { stop() } else { start() }
      } label: {
        Text(recording ? "Type a shortcut…" : (chord?.display ?? "Record Shortcut"))
      }
      .accessibilityIdentifier("composerShortcut.keyboard")
      if chord != nil, !recording {
        Button {
          chord = nil
          takenBy = nil
          rejection = nil
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Remove this shortcut")
        .accessibilityLabel("Remove keyboard shortcut")
      }
    }
    .onDisappear(perform: stop)
  }

  private func start() {
    ComposerShortcutCapture.stop?()
    rejection = nil
    takenBy = nil
    recording = true
    ComposerShortcutCapture.isRecording = true
    ComposerShortcutCapture.stop = { stop() }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      handle(event) ? nil : event
    }
  }

  private func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    guard recording else { return }
    recording = false
    ComposerShortcutCapture.isRecording = false
    ComposerShortcutCapture.stop = nil
  }

  /// Whether the event was taken. Every key is, while recording.
  private func handle(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(
      .capsLock)
    let bare = flags.intersection([.command, .option, .control, .shift]).isEmpty
    if event.keyCode == UInt16(kVK_Escape), bare {
      stop()
      return true
    }
    if event.keyCode == UInt16(kVK_Delete), bare {
      chord = nil
      rejection = nil
      takenBy = nil
      stop()
      return true
    }
    switch ComposerKeyChord.record(
      keyCode: event.keyCode, flags: flags, characters: event.charactersIgnoringModifiers)
    {
    case .failure(let reason):
      rejection = reason
      takenBy = nil
    case .success(let recorded):
      if let owner = others.first(where: { $0.chord == recorded }) {
        takenBy = owner.title
        rejection = nil
        return true
      }
      chord = recorded
      rejection = nil
      takenBy = nil
      stop()
    }
    return true
  }
}
