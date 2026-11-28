import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing

@testable import Drakar

/// A recorded composer chord: which keys count, how they are shown, and that a key the
/// main menu already owns is left to the menu.
@MainActor
@Suite("Composer keyboard shortcuts")
struct ComposerKeyChordTests {

  private func key(
    _ flags: NSEvent.ModifierFlags, code: UInt16, characters: String
  ) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code))
  }

  @Test func aLetterNeedsAModifierOtherThanShift() {
    #expect(
      ComposerKeyChord.record(keyCode: UInt16(kVK_ANSI_K), flags: [], characters: "k")
        == .failure(.needsModifier))
    #expect(
      ComposerKeyChord.record(keyCode: UInt16(kVK_ANSI_K), flags: .shift, characters: "K")
        == .failure(.needsModifier))
  }

  @Test func commandShiftKIsShownInMenuOrder() throws {
    guard
      case .success(let recorded) = ComposerKeyChord.record(
        keyCode: UInt16(kVK_ANSI_K), flags: [.command, .shift], characters: "K")
    else {
      Issue.record("⌘⇧K was not recorded")
      return
    }
    #expect(recorded == ComposerKeyChord(key: "k", command: true, shift: true))
    #expect(recorded.display == "⇧⌘K")
    #expect(recorded.keyEquivalent == SwiftUI.KeyEquivalent("k"))
    #expect(recorded.matches(try key([.command, .shift, .capsLock], code: UInt16(kVK_ANSI_K), characters: "K")))
    #expect(!recorded.matches(try key(.command, code: UInt16(kVK_ANSI_K), characters: "k")))
  }

  /// Shift added to a chord that does not include it is a different chord, unless the
  /// caller is reading Shift as the close-after-turn switch.
  @Test func anExtraShiftMatchesOnlyWhenAsked() throws {
    let chord = ComposerKeyChord(key: "k", command: true)
    let plain = try key(.command, code: UInt16(kVK_ANSI_K), characters: "k")
    let shifted = try key([.command, .shift], code: UInt16(kVK_ANSI_K), characters: "K")
    #expect(chord.matches(plain))
    #expect(!chord.matches(shifted))
    #expect(chord.matches(shifted, allowingExtraShift: true))
    let requiresShift = ComposerKeyChord(key: "k", command: true, shift: true)
    #expect(!requiresShift.matches(plain, allowingExtraShift: true))
  }

  @Test func aFunctionKeyNeedsNoModifier() throws {
    guard
      case .success(let recorded) = ComposerKeyChord.record(
        keyCode: UInt16(kVK_F5), flags: [], characters: "")
    else {
      Issue.record("F5 was not recorded")
      return
    }
    #expect(recorded == ComposerKeyChord(key: "f5"))
    #expect(recorded.display == "F5")
    #expect(recorded.matches(try key([], code: UInt16(kVK_F5), characters: "")))
  }

  @Test func theMenuKeepsAKeyItAlreadyUses() throws {
    let menu = NSMenu()
    let item = NSMenuItem(title: "New Session", action: nil, keyEquivalent: "n")
    item.keyEquivalentModifierMask = .command
    menu.addItem(item)
    let disabled = NSMenuItem(title: "Hidden", action: nil, keyEquivalent: "h")
    disabled.keyEquivalentModifierMask = .command
    disabled.isEnabled = false
    menu.addItem(disabled)

    let claimed = try key(.command, code: UInt16(kVK_ANSI_N), characters: "n")
    #expect(ComposerKeyChord.menuClaims(claimed, menu: menu))
    let free = try key(.command, code: UInt16(kVK_ANSI_K), characters: "k")
    #expect(!ComposerKeyChord.menuClaims(free, menu: menu))
    let hidden = try key(.command, code: UInt16(kVK_ANSI_H), characters: "h")
    #expect(!ComposerKeyChord.menuClaims(hidden, menu: menu))
    #expect(!ComposerKeyChord.menuClaims(claimed, menu: nil))
  }
}
