import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Entering a licence key, seeing what happened to it, and — when there is none —
/// finding out what that actually means.
///
/// A Settings pane rather than a window of its own, as in the siblings. A key is
/// 240 characters that arrive by paste or by drop from a mail client, so it needs
/// somewhere with room and somewhere that survives losing focus.
///
/// Armada's pane, copied, with the explanation rewritten for what Drakar's gate actually
/// does. Armada's `LicenseLinks`, at the top of its pane, is `LicenceLinks` here, in a file
/// of its own. With `isSelling` false (only in tests now) nothing is gated, so a refused
/// key is shown as armada shows it, and the Buy button is hidden.
struct LicensePane: View {
  @State private var entry = ""
  @State private var problem: String?
  private var monitor = EntitlementMonitor.shared

  var body: some View {
    Form {
      Section {
        status
      } footer: {
        footer
      }

      Section {
        editor
      } header: {
        Text("Licence key")
      } footer: {
        Text("Paste your key, or drop the .license file anywhere in this window.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Licence")
    .onAppear { entry = LicenseStore.raw ?? "" }
    .onDrop(of: [.fileURL], isTargeted: nil, perform: accept)
  }

  private var status: some View {
    // On a schedule, because one of the three states is a countdown. A pane left
    // open across the end of a trial window has to stop claiming Drakar can send —
    // the monitor will already have refused the next prompt. Fifteen seconds is
    // comfortably inside the minute the label rounds to.
    TimelineView(.periodic(from: .now, by: 15)) { _ in
      // Read once. The badge and the words beside it are two renderings of one
      // answer, and a trial that ended between two reads would have them
      // contradict each other.
      let entitlement = monitor.current

      HStack(alignment: .top, spacing: 14) {
        badge(for: entitlement)

        VStack(alignment: .leading, spacing: 4) {
          switch entitlement {
          case .licensed(let license):
            Text("Licensed to \(license.email)").foregroundStyle(.green)
            Text(
              "Licence \(license.id) · covers \(license.major).x · issued \(day(license.issuedAt))"
            )
            .font(.caption).foregroundStyle(.secondary)
          case .trial:
            Text("Trial · \(Trial.remainingText)").foregroundStyle(.blue)
            trialExplanation
          case .refused(let reason):
            Text("Unlicensed").foregroundStyle(.orange)
            Text(reason)
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            explanation
            trialOffer
          }
        }
      }
    }
    .textSelection(.enabled)
  }

  /// The glyph, alone in a column to the left of everything the state has to say.
  /// Fixed width, because a triangle is narrower than a seal and without it every
  /// sentence in the block would shift sideways the moment a trial ended.
  private func badge(for entitlement: Entitlement) -> some View {
    let (symbol, tint): (String, Color) =
      switch entitlement {
      case .licensed: ("checkmark.seal.fill", .green)
      case .trial: ("clock.fill", .blue)
      case .refused: ("exclamationmark.triangle.fill", .orange)
      }

    return Image(systemName: symbol)
      .font(.system(size: 28))
      .foregroundStyle(tint)
      .frame(width: 32, alignment: .leading)
  }

  /// What a trial is, said where somebody is watching it run. The second line is
  /// the one worth being blunt about: the window really does close.
  private var trialExplanation: some View {
    VStack(alignment: .leading, spacing: 3) {
      row(
        "Every project and session, new sessions, skills, fan-out and the editor bridge. "
          + "This is the app, not a demo.")
      row(
        "When the window closes a running turn finishes and its questions can still be "
          + "answered, but nothing more is sent until a key is entered or Drakar is reopened.")
    }
    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
  }

  /// The offer, or the note that it has already been taken.
  @ViewBuilder private var trialOffer: some View {
    if Trial.hasRun {
      Text("The trial window has closed. Quitting and reopening Drakar starts another one.")
        .fixedSize(horizontal: false, vertical: true)
        .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
    } else {
      VStack(alignment: .leading, spacing: 6) {
        // Reachable only from a button, here and on the locked card. A trial that
        // armed itself at launch would burn in a window nobody was looking at.
        Button("Start a \(Int(Trial.duration / 60))-minute trial") {
          monitor.startTrial()
        }
        .controlSize(.small)
        Text(
          "Full function, no key — enough to see it drive your own `claude` in your own projects."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, 6)
    }
  }

  /// What "unlicensed" costs, in the words somebody needs when the composer they
  /// reached for is not there.
  private var explanation: some View {
    VStack(alignment: .leading, spacing: 3) {
      row(
        "Drakar sends nothing to an agent: no prompt, no skill, no fan-out, and the editor "
          + "bridge is off.")
      row(
        "Nothing is lost. Projects, past sessions, transcripts and drafts stay exactly where "
          + "they are, and reading them stays free.")
      row("A key takes effect at once. Nothing needs restarting.")
    }
    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
  }

  private func row(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text("·")
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 8) {
      // A `TextEditor` rather than a single-line field: the key is 240 characters,
      // and a key pasted out of a mail client can arrive with the line breaks that
      // client wrapped it at. `LicenseKey.check` drops every whitespace character,
      // and a box that shows the whole thing is what lets somebody see they have
      // pasted half of it.
      TextEditor(text: $entry)
        .font(.system(.caption, design: .monospaced))
        .frame(height: 92)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

      if let problem {
        // The reason, not a generic failure. It is produced once in
        // `LicenseKey.check` precisely so the same sentence reaches every surface.
        Text(problem)
          .font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button("Use this key") { apply(entry) }
          .keyboardShortcut(.defaultAction)
          .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Remove") {
          monitor.removeKey()
          entry = ""
          problem = nil
        }
        .disabled(LicenseStore.raw == nil)
        if monitor.isSelling {
          Spacer()
          Button("Buy a licence…") { NSWorkspace.shared.open(LicenceLinks.buy) }
        }
      }
      .controlSize(.small)
    }
  }

  private var footer: some View {
    Text(
      "One key covers every \(AppInfo.major).x release and every Mac you own — it is issued to "
        + "you, not to a machine, and nothing counts your installs. Drakar verifies it on this "
        + "Mac and never asks anyone about it."
    )
    .fixedSize(horizontal: false, vertical: true)
  }

  /// Store it, or say why not. Refusing to persist a bad key is what stops the
  /// field and the status line disagreeing about what is installed.
  private func apply(_ text: String) {
    switch monitor.enterKey(text) {
    case .valid:
      problem = nil
      entry = LicenseStore.raw ?? ""
    case .refused(let reason):
      problem = reason
    }
  }

  /// The largest dropped file this reads. A key is about 240 characters, so a file
  /// anywhere near this size is not one.
  private static let maxDroppedBytes = 64 * 1024

  /// A dropped `.license` file, read into the field and applied.
  ///
  /// **Checked before it is read.** A drop is whatever somebody dragged, so only a
  /// regular file of at most `maxDroppedBytes` is opened, and when several are dropped
  /// at once the one named `.license` wins, since that is the file the purchase email
  /// carries.
  private func accept(_ providers: [NSItemProvider]) -> Bool {
    let files = providers.filter {
      $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }
    guard !files.isEmpty else { return false }
    Task {
      var urls: [URL] = []
      for provider in files {
        if let url = await Self.fileURL(from: provider) { urls.append(url) }
      }
      guard
        let url = urls.first(where: { $0.pathExtension.lowercased() == "license" }) ?? urls.first
      else { return }
      guard let text = Self.keyText(at: url) else {
        problem = "\(url.lastPathComponent) is not a licence key file"
        return
      }
      entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
      apply(entry)
    }
    return true
  }

  private nonisolated static func fileURL(from provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
        continuation.resume(
          returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
      }
    }
  }

  /// The file's text, or nil for anything that cannot be a key file. The size is
  /// checked on disk first and then again on what was read, so a file that grows in
  /// between is refused rather than read whole.
  private static func keyText(at url: URL) -> String? {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true, (values.fileSize ?? 0) <= maxDroppedBytes,
      let handle = try? FileHandle(forReadingFrom: url)
    else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: maxDroppedBytes + 1),
      data.count <= maxDroppedBytes
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// The date half of an ISO timestamp. The clock time is noise on a receipt.
  private func day(_ issuedAt: String) -> String {
    String(issuedAt.prefix(10))
  }
}
