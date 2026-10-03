// swift-tools-version: 6.3
import PackageDescription

// AmiralKit deliberately has ZERO dependencies and imports nothing above Foundation.
// `swift test --package-path apps/apple/Packages/AmiralKit` must resolve nothing, run
// offline, and finish in well under a second.
//
// Everything that can be argued about in a unit test lives here, where a test never waits
// on a simulator or on a framework's build health. The UI frameworks stay in the app
// target, which is why a test that needs a device is the exception rather than the rule.
let package = Package(
  name: "AmiralKit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "AmiralKit", targets: ["AmiralKit"])
  ],
  targets: [
    .target(name: "AmiralKit"),
    .testTarget(
      name: "AmiralKitTests", dependencies: ["AmiralKit"],
      // Lines captured from the real CLI; docs/claude-stream-json.md says how.
      resources: [.copy("Fixtures")]),
  ]
)
