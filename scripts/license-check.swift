import Foundation

/// Runs minted licence keys through the real verifier.
///
/// `scripts/lib/license.test.mjs` is JavaScript checking JavaScript: it proves
/// the issuer is self-consistent and proves nothing about the program that has
/// to accept its output. The disagreement that would actually cost money lives
/// between the two languages — base64url padding, or a signature taken over the
/// parsed claims on one side and the encoded payload on the other — and it is
/// invisible until a paying customer pastes a key that Node called valid.
///
/// So this compiles `License.swift` itself, unmodified, and feeds it cases from
/// `scripts/license-check.mjs` on stdin. A standalone `swiftc` binary rather than a
/// case in DrakarTests: those sign their own keys in Swift, which proves Swift agrees
/// with itself, and they need Xcode and the hosted app to run.
///
/// Run with `make license-check`.

/// Stands in for AppInfo.swift, which `License.swift` reaches only through the
/// `major:` default — and which reads the version out of an app bundle this binary
/// does not have. Every case below passes its major explicitly, so this is never the
/// value under test. `Revocations.swift` is compiled for real instead of stubbed:
/// it is four lines and no dependencies, so there is nothing to gain by faking it.
enum AppInfo {
  static let major = 1
}

@main
struct LicenseRoundTrip {
  struct Case: Decodable {
    let label: String
    let key: String
    let major: Int
    let expect: Bool
    /// Substring the refusal has to contain, when one is expected. Checked
    /// because "refused" is not the assertion that matters — a key refused for
    /// the wrong reason is a support reply that sends someone the wrong way.
    let reason: String?
  }

  static func main() {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let cases = try? JSONDecoder().decode([Case].self, from: input), !cases.isEmpty else {
      print("no cases on stdin — run this through `make license-check`")
      exit(2)
    }

    var failures = 0
    func pass(_ label: String) { print("  \u{1B}[32mok\u{1B}[0m   \(label)") }
    func fail(_ label: String, _ detail: String) {
      print("  \u{1B}[31mFAIL\u{1B}[0m \(label)")
      print("         \(detail)")
      failures += 1
    }

    // DIVERGES from armada: LICENSE_PUBLIC_KEY stands in for the compiled key while that
    // is the placeholder, which nothing verifies against. license-check.mjs refuses it
    // once a real key is compiled in, before this runs.
    let publicKey =
      ProcessInfo.processInfo.environment["LICENSE_PUBLIC_KEY"] ?? LicenseKey.publicKey

    for item in cases {
      switch LicenseKey.check(item.key, major: item.major, revoked: [], publicKey: publicKey) {
      case .valid(let license):
        if item.expect {
          pass("\(item.label) — \(license.email), \(license.major).x")
        } else {
          fail(item.label, "accepted a key that should have been refused")
        }
      case .refused(let reason):
        if item.expect {
          fail(item.label, "refused a genuine key: \(reason)")
        } else if let expected = item.reason, !reason.contains(expected) {
          fail(item.label, "refused for '\(reason)', expected '\(expected)'")
        } else {
          pass("\(item.label) — \(reason)")
        }
      }
    }

    print("")
    print(failures == 0 ? "  \(cases.count) checks, all passing" : "  \(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
  }
}
