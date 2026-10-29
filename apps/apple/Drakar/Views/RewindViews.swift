import DrakarKit
import SwiftUI

/// What a prompt's menu offers, decided from its message uuid and the session. A prompt with
/// none (Codex history) offers nothing; one whose session can't be forked from offers no
/// fork; one whose session Drakar doesn't drive offers no code rewind.
struct RewindOffer: Equatable {
  /// "Fork conversation from here".
  var fork: Bool
  /// "Rewind code to here"; also gates "Fork conversation and rewind code".
  var rewindCode: Bool
  /// False while a turn runs: what is offered shows, disabled. Nothing is queued.
  var isEnabled = true

  var offersAnything: Bool { fork || rewindCode }

  /// `canFork` and `canRewindCode` as they read with no turn running; `duringTurn` disables
  /// them.
  static func of(
    messageID: String?, canFork: Bool, canRewindCode: Bool, duringTurn: Bool = false
  ) -> RewindOffer {
    guard messageID != nil else { return RewindOffer(fork: false, rewindCode: false) }
    return RewindOffer(fork: canFork, rewindCode: canRewindCode, isEnabled: !duringTurn)
  }
}

/// What a prompt's menu asks for; the session view acts on it.
enum RewindAction: Equatable {
  case fork(messageID: String, text: String)
  case rewind(messageID: String)
  case forkAndRewind(messageID: String, text: String)
}

extension EnvironmentValues {
  /// Set by the session: what a prompt with this message uuid offers. Nil outside a session.
  @Entry var rewindOffer: ((String?) -> RewindOffer)? = nil
  /// Set by the session: acts on a prompt menu's pick.
  @Entry var rewindAction: ((RewindAction) -> Void)? = nil
}

extension View {
  /// A prompt bubble's undo arrow, shown on hover, and the same items in its context menu.
  /// Read from the environment here, so the row around it stays `Equatable`.
  func rewindMenu(entryID: String, messageID: String?, text: String) -> some View {
    modifier(RewindMenu(entryID: entryID, messageID: messageID, text: text))
  }
}

private struct RewindMenu: ViewModifier {
  let entryID: String
  let messageID: String?
  let text: String

  @Environment(\.rewindOffer) private var rewindOffer
  @Environment(\.rewindAction) private var rewindAction
  @State private var isHovering = false

  func body(content: Content) -> some View {
    let offer = rewindOffer?(messageID) ?? RewindOffer(fork: false, rewindCode: false)
    if let messageID, let rewindAction, offer.offersAnything {
      HStack(alignment: .bottom, spacing: 6) {
        content
        Menu {
          RewindMenuItems(messageID: messageID, text: text, offer: offer, act: rewindAction)
        } label: {
          Image(systemName: "arrow.uturn.backward")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Fork or rewind from here"))
        .accessibilityLabel(String(localized: "Fork or rewind from here"))
        .accessibilityIdentifier("prompt.rewind.\(entryID)")
        // In the accessibility tree all along, as the copy button is.
        .opacity(isHovering ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .padding(.bottom, 4)
      }
      .onHover { isHovering = $0 }
      .contextMenu {
        RewindMenuItems(messageID: messageID, text: text, offer: offer, act: rewindAction)
      }
    } else {
      content
    }
  }
}

/// The extension's three items, for whatever the offer allows.
private struct RewindMenuItems: View {
  let messageID: String
  let text: String
  let offer: RewindOffer
  let act: (RewindAction) -> Void

  var body: some View {
    if offer.fork {
      Button(String(localized: "Fork conversation from here")) {
        act(.fork(messageID: messageID, text: text))
      }
      .disabled(!offer.isEnabled)
      .accessibilityIdentifier("prompt.rewind.fork")
    }
    if offer.rewindCode {
      Button(String(localized: "Rewind code to here")) {
        act(.rewind(messageID: messageID))
      }
      .disabled(!offer.isEnabled)
      .accessibilityIdentifier("prompt.rewind.code")
      if offer.fork {
        Button(String(localized: "Fork conversation and rewind code")) {
          act(.forkAndRewind(messageID: messageID, text: text))
        }
        .disabled(!offer.isEnabled)
        .accessibilityIdentifier("prompt.rewind.forkAndCode")
      }
    }
  }
}

/// A code rewind's confirmation, from the dry run to the outcome, in the extension's words.
/// Nothing is written before Rewind (or Continue) is pressed on the dry run's list. Once the
/// rewind is sent it may already be writing: the sheet stays until its outcome arrives.
struct RewindSheet: View {
  let rewinds: Rewinds
  /// Fork and rewind's Continue on a dry run that lists no files: the fork, with no rewind.
  let forkWithoutRewind: (String) -> Void

  /// The dry run's files as shown, worked out once per result: `shownPath` reads the disk.
  /// Kept through `.rewinding`, so the list stays up while the rewind runs.
  @State private var shown: (result: RewindResult, paths: [String])?

  private var thenFork: Bool { rewinds.request?.thenFork == true }

  /// The dry run on screen: the one ready, or the one being rewound.
  private var listed: RewindResult? {
    switch rewinds.phase {
    case .ready(let result): result
    case .rewinding: shown?.result
    default: nil
    }
  }

  private func paths(of result: RewindResult) -> [String] {
    if let shown, shown.result == result { return shown.paths }
    return result.filesChanged.map(rewinds.shownPath)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(thenFork ? String(localized: "Fork and rewind") : String(localized: "Rewind code"))
        .font(.headline)
        .accessibilityIdentifier("rewind.title")
      if thenFork, !isFailed {
        Text(RewindCopy.forkNote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("rewind.forkNote")
      }
      content
      buttons
    }
    .padding(20)
    .frame(width: 480, alignment: .leading)
    // Esc and a click outside are Never mind, which waits for a rewind already sent.
    .interactiveDismissDisabled(rewinds.phase == .rewinding)
    .onChange(of: readyResult, initial: true) { _, result in
      guard let result else { return }
      shown = (result, result.filesChanged.map(rewinds.shownPath))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("rewind.sheet")
  }

  private var readyResult: RewindResult? {
    if case .ready(let result) = rewinds.phase { return result }
    return nil
  }

  private var isFailed: Bool {
    if case .failed = rewinds.phase { return true }
    return false
  }

  @ViewBuilder private var content: some View {
    switch rewinds.phase {
    case .checking:
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("rewind.checking")
    case .ready, .rewinding:
      if let result = listed { files(of: result) }
    case .failed(let line):
      VStack(alignment: .leading, spacing: 4) {
        Label(line, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
          .accessibilityIdentifier("rewind.failure")
        if let detail = rewinds.detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("rewind.detail")
        }
      }
    case .done, nil:
      EmptyView()
    }
  }

  @ViewBuilder private func files(of result: RewindResult) -> some View {
    let paths = paths(of: result)
    if paths.isEmpty {
      Text(RewindCopy.nothingToRewind)
        .accessibilityIdentifier("rewind.nothing")
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
            Text(verbatim: path)
              .font(.callout.monospaced())
              .lineLimit(1)
              .truncationMode(.middle)
              .help(path)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 200)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("rewind.files")
      HStack(spacing: 6) {
        Text(verbatim: "+\(result.insertions)").foregroundStyle(.green)
        Text(verbatim: "\u{2212}\(result.deletions)").foregroundStyle(.red)
      }
      .font(.callout.monospacedDigit())
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("rewind.counts")
      Text(RewindCopy.warning)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("rewind.warning")
    }
  }

  @ViewBuilder private var buttons: some View {
    let isRewinding = rewinds.phase == .rewinding
    HStack {
      if isRewinding { ProgressView().controlSize(.small) }
      Spacer()
      Button(String(localized: "Never mind")) { rewinds.cancel() }
        .keyboardShortcut(.cancelAction)
        .disabled(isRewinding)
        .accessibilityIdentifier("rewind.cancel")
      primary
    }
  }

  /// Rewind (Continue for Fork and rewind) on the dry run's list, and while it waits on
  /// either request; none for a failure, or for a plain rewind with nothing to rewind.
  @ViewBuilder private var primary: some View {
    let title = thenFork ? String(localized: "Continue") : String(localized: "Rewind")
    switch rewinds.phase {
    case .checking, .rewinding:
      Button(title) {}
        .disabled(true)
        .accessibilityIdentifier("rewind.confirm")
    case .ready(let result) where !result.filesChanged.isEmpty:
      Button(title) { rewinds.confirm() }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("rewind.confirm")
    case .ready where thenFork:
      Button(title) {
        guard let messageID = rewinds.request?.messageID else { return }
        forkWithoutRewind(messageID)
      }
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("rewind.confirm")
    case .ready, .failed, .done, nil:
      EmptyView()
    }
  }
}
