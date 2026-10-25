import Foundation
import Security

/// Who may connect (spec §2): Drakar itself, signed by the host's own team. Not any program
/// the team signed: a tool of ours without the hardened runtime could be made to load a
/// stranger's code. `HostServer` checks the uid first.
enum PeerSignature {
  /// From the host's own signature, never constants, so a build signed by another team
  /// trusts that team's Drakar and nothing else. Nil when the host is unsigned or not named
  /// as the app's helper: it then lets nobody in. Unchecked: a `SecRequirement` is immutable
  /// once made.
  nonisolated(unsafe) private static let requirement: SecRequirement? = {
    guard let (app, team) = ownSigning else { return nil }
    var requirement: SecRequirement?
    let text =
      "anchor apple generic and identifier \"\(app)\" and certificate leaf[subject.OU] = \"\(team)\""
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
    else { return nil }
    return requirement
  }()

  /// The app's identifier and the team. The host is signed as the app's identifier plus
  /// `.DrakarHost` (its `PRODUCT_BUNDLE_IDENTIFIER`), so the app's is read off its own.
  private static var ownSigning: (app: String, team: String)? {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var information: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
      SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        == errSecSuccess,
      let information = information as? [String: Any],
      let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
      let identifier = information[kSecCodeInfoIdentifier as String] as? String,
      identifier.hasSuffix(helperSuffix)
    else { return nil }
    return (String(identifier.dropLast(helperSuffix.count)), team)
  }

  private static let helperSuffix = ".DrakarHost"

  /// The peer as the kernel recorded it when it connected (its audit token, which a pid
  /// reused since cannot fake), checked against the team requirement.
  static func sameTeam(fd: Int32) -> Bool {
    guard let requirement else { return false }
    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
    let attributes = [kSecGuestAttributeAudit: withUnsafeBytes(of: &token) { Data($0) }]
    var guest: SecCode?
    guard
      SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &guest)
        == errSecSuccess, let guest
    else { return false }
    return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
  }
}
