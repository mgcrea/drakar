import DrakarKit
import SwiftUI

/// The session's permission mode and model, on the composer's toolbar as the extension has
/// them: the model on the left, the mode on the right beside Send. A pick applies to a running
/// session at once, else at its start, and the folder remembers it
/// (docs/superpowers/specs/2026-10-06-mode-and-model-pills-design.md).
struct SessionPills {
  let session: ClaudeSession
  let folder: URL
  /// The account the session runs, or will start, under: whose models the menu lists.
  let account: ClaudeAccount

  private var catalog: ModelCatalog { .shared }

  /// The model, and why the last change was refused if it was.
  var model: some View {
    let models = catalog.models(for: account)
    return HStack(spacing: 6) {
      modelMenu(models)
      if let note = session.pillNote {
        Text(note).font(.caption).foregroundStyle(.red).lineLimit(1).help(note)
      }
    }
    .onAppear { catalog.load(folder: folder, account: account) }
  }

  var mode: some View { modeMenu(catalog.models(for: account)) }

  private func modeMenu(_ models: [ModelOption]?) -> some View {
    let shown = session.shownMode
    let mode = PermissionMode(rawValue: shown)
    return Menu {
      ForEach(Self.offeredModes(session, models: models), id: \.self) { option in
        Button {
          session.setMode(option)
        } label: {
          Label(option.title, systemImage: option.rawValue == shown ? "checkmark" : option.symbol)
        }
      }
    } label: {
      Label(PermissionMode.title(of: shown), systemImage: mode?.symbol ?? "questionmark.circle")
        .pill(filled: false)
    }
    .pillMenu()
    .help("Permission mode. ⇧Tab moves to the next.")
    .accessibilityIdentifier("composer.mode")
  }

  private func modelMenu(_ models: [ModelOption]?) -> some View {
    let current = Self.option(for: session, in: models)
    return Menu {
      if let models {
        ForEach(models) { option in
          Button {
            session.setModel(option.value)
          } label: {
            if option.value == current?.value {
              Label(option.displayName, systemImage: "checkmark")
            } else {
              Text(option.displayName)
            }
            Text(option.description)
          }
        }
      } else {
        Text(loadingText)
      }
    } label: {
      Label(Self.modelLabel(for: session, in: models), systemImage: "cpu")
        .pill(filled: true)
    }
    .pillMenu()
    .help("Model")
    .accessibilityIdentifier("composer.model")
  }

  private var loadingText: String {
    let probe = CapabilityStore.shared.capabilities(for: folder, account: account)
    if probe.isLoading || !probe.hasLoaded { return String(localized: "Loading models…") }
    return probe.skillsProblem ?? String(localized: "This Claude Code version didn't list models.")
  }

  /// Ask, Edit and Plan always; Auto for a model that says it takes it; Bypass while allowed.
  static func offeredModes(_ session: ClaudeSession, models: [ModelOption]?) -> [PermissionMode] {
    PermissionMode.allCases.filter { mode in
      switch mode {
      case .auto: option(for: session, in: models)?.supportsAutoMode == true
      case .bypass: session.offersBypass
      default: true
      }
    }
  }

  /// The list's entry for the session's model: its pick, else the running model, else
  /// `default`.
  static func option(for session: ClaudeSession, in models: [ModelOption]?) -> ModelOption? {
    guard let models else { return nil }
    if let pick = session.pickedModel { return models.first { $0.value == pick } }
    if let running = session.transcript.session?.model {
      let base = running.replacingOccurrences(of: "[1m]", with: "")
      if let match = models.first(where: { $0.resolvedModel == base && $0.value != "default" }) {
        return match
      }
    }
    return models.first { $0.value == "default" }
  }

  /// The model's own name ("Opus 5.5"), never "Default (recommended)".
  static func modelLabel(for session: ClaudeSession, in models: [ModelOption]?) -> String {
    // Claude Code's default is whatever `settings.json` makes it: name what runs.
    let pick = session.pickedModel
    if pick == nil || pick == "default", let running = session.transcript.session?.model {
      return ModelName.display(running)
    }
    if let option = option(for: session, in: models) {
      return ModelName.display(option.resolvedModel ?? option.value)
    }
    if let pick = session.pickedModel, pick != "default" { return ModelName.display(pick) }
    if let running = session.transcript.session?.model { return ModelName.display(running) }
    return String(localized: "Default")
  }

  /// ⇧Tab: the next offered mode.
  static func cycle(_ session: ClaudeSession, account: ClaudeAccount) {
    let offered = offeredModes(session, models: ModelCatalog.shared.models(for: account))
    let current = PermissionMode(rawValue: session.shownMode) ?? .ask
    session.setMode(PermissionMode.next(after: current, among: offered))
  }
}

extension View {
  /// A composer pill's menu: its label drawn as is, with no indicator, as the extension's.
  fileprivate func pillMenu() -> some View {
    self
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
  }

  /// A composer pill's label: a capsule behind the model, only under the pointer for the mode.
  fileprivate func pill(filled: Bool) -> some View {
    modifier(PillChrome(filled: filled))
  }
}

private struct PillChrome: ViewModifier {
  let filled: Bool
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .font(.callout)
      .foregroundStyle(isHovered ? .primary : .secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        Color.secondary.opacity(isHovered ? 0.2 : filled ? 0.12 : 0), in: Capsule()
      )
      .contentShape(Capsule())
      .onHover { isHovered = $0 }
      .animation(.easeOut(duration: 0.12), value: isHovered)
  }
}
