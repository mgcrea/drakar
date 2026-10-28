import CryptoKit
import Foundation
import Testing

@testable import Drakar

/// The licence check, against keys signed here.
///
/// The key compiled into Drakar is the placeholder until Phase 2, which no signature can
/// match, so every case below signs with a keypair made for the test and passes its public
/// half as `publicKey:`. That reaches the refusals only a correctly signed key can reach.
/// Armada's `make unit` does the same; its checks run outside Xcode, Drakar's in the
/// hosted suite.
///
/// What this cannot prove is that Swift agrees with the JavaScript that mints real keys:
/// `mint` below is Swift. `make license-check` is the cross-language check.
@Suite("Licence key") struct LicenseKeyTests {
  let signing = Curve25519.Signing.PrivateKey()
  var trusted: String { Self.base64Url(signing.publicKey.rawRepresentation) }

  /// A key in `scripts/lib/license.mjs`'s format: `drk1.<payload>.<signature>`, the
  /// payload base64url JSON, the signature over the ENCODED payload.
  func mint(
    id: String = "01K8DRAKARTESTKEY000000000",
    email: String = "buyer@example.com",
    major: Int = 1,
    issuedAt: String = "2026-10-28T09:00:00.000Z",
    with key: Curve25519.Signing.PrivateKey? = nil
  ) -> String {
    let claims: [String: Any] = ["id": id, "email": email, "major": major, "issuedAt": issuedAt]
    let json = try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
    let payload = Self.base64Url(json)
    let signature = try! (key ?? signing).signature(for: Data(payload.utf8))
    return "drk1.\(payload).\(Self.base64Url(signature))"
  }

  func check(_ key: String, major: Int = 1, revoked: Set<String> = []) -> LicenseCheck {
    LicenseKey.check(key, major: major, revoked: revoked, publicKey: trusted)
  }

  func refusal(_ result: LicenseCheck) -> String? {
    if case .refused(let reason) = result { return reason }
    return nil
  }

  @Test func acceptsAValidKey() {
    let license = check(mint(id: "01K8VALID00000000000000000", email: "a@b.c")).license
    #expect(license?.id == "01K8VALID00000000000000000")
    #expect(license?.email == "a@b.c")
    #expect(license?.major == 1)
  }

  /// A mail client hard-wraps a key this long, and the breaks come back with the paste.
  @Test func acceptsWrappedKey() {
    let key = mint()
    let lines = stride(from: 0, to: key.count, by: 60).map { start -> String in
      let from = key.index(key.startIndex, offsetBy: start)
      let to = key.index(from, offsetBy: 60, limitedBy: key.endIndex) ?? key.endIndex
      return String(key[from..<to])
    }
    let wrapped = "  " + lines.joined(separator: "\n") + "  "
    #expect(lines.count > 1)
    #expect(check(wrapped).license?.email == "buyer@example.com")
  }

  /// Armada's prefix on a payload and signature that are otherwise good: one app's key
  /// opens no other app.
  @Test func refusesOtherPrefix() {
    let parts = mint().split(separator: ".").map(String.init)
    let result = check("arm1.\(parts[1]).\(parts[2])")
    #expect(refusal(result) == "unknown key format 'arm1'")
  }

  /// Claims re-encoded under the original signature: what forging one looks like.
  @Test func refusesTamperedPayload() {
    let parts = mint(email: "buyer@example.com").split(separator: ".").map(String.init)
    let forged =
      #"{"email":"thief@example.com","id":"01K8DRAKARTESTKEY000000000","#
      + #""issuedAt":"2026-10-28T09:00:00.000Z","major":1}"#
    let result = check("drk1.\(Self.base64Url(Data(forged.utf8))).\(parts[2])")
    #expect(refusal(result) == "signature does not match")
  }

  @Test func refusesRevoked() {
    let id = "01K8REVOKED000000000000000"
    let result = check(mint(id: id), revoked: [id])
    #expect(refusal(result) == "licence \(id) was revoked")
  }

  @Test func refusesOlderMajor() {
    let result = check(mint(major: 1), major: 2)
    #expect(refusal(result) == "key covers 1.x, this build is 2.x")
  }

  /// Leaning on the button cannot stretch the half hour.
  @Test func trialStartIsIdempotent() {
    let first = Trial.start()
    let second = Trial.start()
    #expect(first == second)
    #expect(Trial.isActive)
    #expect(Trial.hasRun)
  }

  /// A key first, always. Through `resolve`, because no key can verify against the
  /// placeholder public key, so a valid stored key cannot exist until Phase 2.
  @Test func entitlementPrefersKeyOverTrial() {
    let result = check(mint())
    #expect(result.license != nil)
    guard case .licensed(let license) = Entitlement.resolve(result, trialActive: true) else {
      Issue.record("an active trial outranked a valid key")
      return
    }
    #expect(license.email == "buyer@example.com")
    #expect(!Entitlement.resolve(.refused("no licence key"), trialActive: false).isEntitled)
    guard case .trial = Entitlement.resolve(.refused("no licence key"), trialActive: true) else {
      Issue.record("an active trial with no key was not a trial")
      return
    }
  }

  /// Phase 2 deletes this test in the commit that lands the real key.
  @Test func publicKeyIsPlaceholderUntilPhase2() {
    #expect(LicenseKey.publicKey == "PLACEHOLDER-SET-IN-PHASE-2")
    // The placeholder decodes to no key, so a genuine signature is refused by name
    // rather than accepted.
    let result = LicenseKey.check(mint(), major: 1, revoked: [])
    #expect(refusal(result) == "this build has no signing key compiled in")
  }

  static func base64Url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
