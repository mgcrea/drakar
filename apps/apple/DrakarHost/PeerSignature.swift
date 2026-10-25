import Foundation
import Security

/// Who may connect (spec §2): a program signed by the host's own team. `HostServer` checks
/// the uid first.
enum PeerSignature {
  /// From the host's own signature, never a constant, so a build signed by another team
  /// trusts that team's apps and nobody else's. Nil when the host is unsigned: it then lets
  /// nobody in. Unchecked: a `SecRequirement` is immutable once made.
  nonisolated(unsafe) private static let requirement: SecRequirement? = {
    guard let team = ownTeam else { return nil }
    var requirement: SecRequirement?
    let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
    else { return nil }
    return requirement
  }()

  private static var ownTeam: String? {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var information: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
      SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        == errSecSuccess
    else { return nil }
    return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
  }

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
