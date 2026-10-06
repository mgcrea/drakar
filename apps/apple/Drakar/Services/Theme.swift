import AppKit
import SupportKitSettings
import SwiftUI

/// What Settings ▸ Theme changes: the accent colour, for the places Drakar draws with it
/// (folders, the selected row, prominent buttons, the pane handles) and the controls that
/// take a tint.
///
/// Nothing picked is nothing overridden: the asset catalog's `AccentColor` stands, with its
/// own dark variant, so the default can change without anyone who never picked noticing.
enum Theme {
  /// The catalog's light accent, shown as the default swatch.
  static let defaultAccent = SwatchColor.hex(0x007AFF)

  /// Chosen to sit with the icon's blue and violet, and to hold on both a light and a dark
  /// window. The default comes first in the popover on its own.
  static let accentPalette: [SwatchColor] = [
    .hex(0xAF52DE), .hex(0x5E5CE6), .hex(0x1FA79F), .hex(0x30B05E), .hex(0xFFB000),
    .hex(0xFF9F0A), .hex(0xFF453A), .hex(0xFF2D78), .hex(0x8E8E93),
  ]

  /// The colour stored, opaque; nil while nothing valid is.
  static var pickedAccent: SwatchColor? {
    _ = AttentionDefaults.shared.revision
    return ClaudeChoice.defaults.string(forKey: PreferenceKey.accentColor)
      .flatMap(SwatchColor.init(hex:))
      .map { $0.withAlpha(1) }
  }

  /// For `.tint`: nil keeps what the environment already has.
  static var tint: Color? { pickedAccent?.color }

  /// The accent to draw with where a view names one itself.
  static var accent: Color { tint ?? .accentColor }

  /// The same for AppKit drawing.
  static var nsAccent: NSColor {
    guard let picked = pickedAccent else { return .controlAccentColor }
    return NSColor(srgbRed: picked.red, green: picked.green, blue: picked.blue, alpha: 1)
  }
}

extension View {
  /// Tints this window's controls with the accent Settings picked.
  func themed() -> some View { modifier(ThemedRoot()) }
}

private struct ThemedRoot: ViewModifier {
  func body(content: Content) -> some View {
    content.tint(Theme.tint)
  }
}
