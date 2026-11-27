import SwiftUI

/// What the transcript shows while an agent works: a provider-specific animated glyph beside a
/// verb that types itself in and changes every few seconds.
struct WorkingIndicator: View {
  /// Which provider's glyph animation, colour and verb list to show.
  var agent: AgentKind = .claude
  /// Said in place of the verbs while it holds, such as "Retrying (2/10)".
  var status: String?
  @State private var verb: String
  /// The line as drawn, mid-way through typing in `verb` over the one before it.
  @State private var shown = String(repeating: " ", count: Self.width)

  init(agent: AgentKind = .claude, status: String? = nil) {
    self.agent = agent
    self.status = status
    _verb = State(initialValue: Self.style(for: agent).verbs.randomElement() ?? "Working")
  }

  var body: some View {
    let style = Self.style(for: agent)
    HStack(spacing: 4) {
      TimelineView(.periodic(from: .now, by: style.frameInterval)) { context in
        Text(style.frame(at: context.date))
          .font(.system(size: 18, design: .monospaced))
          .foregroundStyle(style.foreground)
          .frame(width: 24)
      }
      Text(shown).fontWeight(.medium)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(status ?? "Working")
    .task(id: agent) { await rotateVerbs() }
    .task(id: status ?? verb) { await typeIn((status ?? verb) + "...") }
  }

  /// A new verb after 2s, then 3s, then every 5s.
  private func rotateVerbs() async {
    let style = Self.style(for: agent)
    if !style.verbs.contains(verb) { verb = style.verbs.randomElement() ?? "Working" }
    for change in 0... {
      do { try await Task.sleep(for: .seconds(change < 2 ? [2, 3][change] : 5)) } catch { return }
      guard let nextVerb = style.nextVerb(after: verb) else { return }
      verb = nextVerb
    }
  }

  /// A cursor sweeps the line every 40ms, trailed by two scrambled characters before each one
  /// settles; past the end of the new text it blanks what is left of the old.
  private func typeIn(_ text: String) async {
    let target = Array(
      text.padding(toLength: max(Self.width, text.count), withPad: " ", startingAt: 0))
    var line = Array(shown.padding(toLength: target.count, withPad: " ", startingAt: 0))
    for cursor in 0..<(target.count + 3) {
      for behind in 0...3 where target.indices.contains(cursor - behind) {
        let settled = target[cursor - behind]
        line[cursor - behind] =
          switch (settled, behind) {
          case (" ", _): " "
          case (_, 0): "▌"
          case (_, 3): settled
          default: [".", "_", settled].randomElement()!
          }
      }
      shown = String(line)
      do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
    }
  }

  /// Per-provider spinner frames, cadence, colour and verbs.
  struct Style {
    let frames: [String]
    let frameInterval: TimeInterval
    let foreground: AnyShapeStyle
    let verbs: [String]

    func nextVerb(after currentVerb: String) -> String? {
      verbs.filter { $0 != currentVerb }.randomElement()
    }

    func frame(at date: Date) -> String {
      let step = Int(floor(date.timeIntervalSinceReferenceDate / frameInterval + 1e-9))
      let index = ((step % frames.count) + frames.count) % frames.count
      return frames[index]
    }
  }

  static func style(for agent: AgentKind) -> Style {
    switch agent {
    case .claude:
      // After the Claude Code extension: a starburst pulsing out and back in terracotta.
      Style(
        frames: claudeFrames, frameInterval: 0.12, foreground: AnyShapeStyle(claudeClay),
        verbs: claudeVerbs)
    case .codex:
      // A crisp braille terminal spinner in OpenAI emerald.
      Style(
        frames: codexFrames, frameInterval: 0.08, foreground: AnyShapeStyle(codexEmerald),
        verbs: codexVerbs)
    case .grok:
      Style(frames: codexFrames, frameInterval: 0.08, foreground: AnyShapeStyle(Color.primary), verbs: ["Working"])
    case .agy:
      // A four-point sparkle pulsing in Antigravity's blue-to-violet gradient.
      Style(
        frames: agyFrames, frameInterval: 0.15, foreground: AnyShapeStyle(agyGradient),
        verbs: agyVerbs)
    }
  }

  private static let claudeGlyphs = ["·", "✢", "*", "✶", "✻", "✽"]
  private static let claudeFrames = claudeGlyphs + claudeGlyphs.reversed()
  private static let claudeClay = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

  private static let codexFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  private static let codexEmerald = Color(red: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255)

  private static let agyGlyphs = ["·", "⋆", "✧", "✦"]
  private static let agyFrames = agyGlyphs + agyGlyphs.reversed()
  private static let agyGradient = LinearGradient(
    colors: [
      Color(red: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255),
      Color(red: 0x9B / 255, green: 0x72 / 255, blue: 0xCB / 255),
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing)

  /// Room for the longest verb and its ellipsis, so a shorter one wipes the longer before it.
  private static let width =
    (sharedVerbs + ["Clauding", "Codexing", "Antigraviting"]).map(\.count).max()! + 3

  /// The extension's own list.
  private static let claudeVerbs = [
    "Accomplishing", "Actioning", "Actualizing", "Baking", "Booping", "Brewing", "Calculating",
    "Cerebrating", "Channeling", "Churning", "Clauding", "Coalescing", "Cogitating", "Computing",
    "Combobulating", "Concocting", "Considering", "Contemplating", "Cooking", "Crafting",
    "Creating", "Crunching", "Deciphering", "Deliberating", "Determining", "Discombobulating",
    "Doing", "Effecting", "Elucidating", "Enchanting", "Envisioning", "Finagling",
    "Flibbertigibbeting", "Forging", "Forming", "Frolicking", "Generating", "Germinating",
    "Hatching", "Herding", "Honking", "Ideating", "Imagining", "Incubating", "Inferring",
    "Manifesting", "Marinating", "Meandering", "Moseying", "Mulling", "Mustering", "Musing",
    "Noodling", "Percolating", "Perusing", "Philosophizing", "Pontificating", "Pondering",
    "Processing", "Puttering", "Puzzling", "Reticulating", "Ruminating", "Schlepping",
    "Shimmying", "Simmering", "Smooshing", "Spelunking", "Spinning", "Stewing", "Sussing",
    "Synthesizing", "Thinking", "Tinkering", "Transmuting", "Unfurling", "Unraveling", "Vibing",
    "Wandering", "Whirring", "Wibbling", "Working", "Wrangling",
  ]

  /// Verbs shared by every provider, with each provider's own signature verb layered on top.
  private static let sharedVerbs = claudeVerbs.filter { $0 != "Clauding" }
  private static let codexVerbs = sharedVerbs + ["Codexing"]
  private static let agyVerbs = sharedVerbs + ["Antigraviting"]
}

#Preview {
  VStack(alignment: .leading, spacing: 12) {
    WorkingIndicator(agent: .claude)
    WorkingIndicator(agent: .codex)
    WorkingIndicator(agent: .agy)
  }
  .padding()
}
