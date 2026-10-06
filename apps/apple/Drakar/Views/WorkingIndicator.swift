import SwiftUI

/// What the transcript shows while Claude works, after the extension: a glyph that pulses out
/// to a star and back, beside a verb that types itself in and changes every few seconds.
struct WorkingIndicator: View {
  /// Said in place of the verbs while it holds, such as "Retrying (2/10)".
  var status: String?
  @State private var verb = Self.verbs.randomElement()!
  /// The line as drawn, mid-way through typing in `verb` over the one before it.
  @State private var shown = String(repeating: " ", count: Self.width)

  var body: some View {
    HStack(spacing: 4) {
      TimelineView(.periodic(from: .now, by: Self.frameInterval)) { context in
        Text(Self.frames[Self.frame(at: context.date)])
          .font(.system(size: 18, design: .monospaced))
          .foregroundStyle(Self.clay)
          .frame(width: 24)
      }
      Text(shown).fontWeight(.medium)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(status ?? "Working")
    .task { await rotateVerbs() }
    .task(id: status ?? verb) { await typeIn((status ?? verb) + "...") }
  }

  /// A new verb after 2s, then 3s, then every 5s.
  private func rotateVerbs() async {
    for change in 0... {
      do { try await Task.sleep(for: .seconds(change < 2 ? [2, 3][change] : 5)) } catch { return }
      verb = Self.verbs.filter { $0 != verb }.randomElement()!
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

  private static func frame(at date: Date) -> Int {
    Int(date.timeIntervalSinceReferenceDate / frameInterval) % frames.count
  }

  private static let frameInterval = 0.12
  private static let glyphs = ["·", "✢", "*", "✶", "✻", "✽"]
  private static let frames = glyphs + glyphs.reversed()
  private static let clay = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
  /// Room for the longest verb and its ellipsis, so a shorter one wipes the longer before it.
  private static let width = verbs.map(\.count).max()! + 3

  /// The extension's own list.
  private static let verbs = [
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
}

#Preview {
  WorkingIndicator().padding()
}
