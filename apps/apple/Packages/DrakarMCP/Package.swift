// swift-tools-version: 6.3
import PackageDescription

// The seam between Drakar and `swift-mcp-kit`, in Cadence's shape: the protocol and the
// listener live in the kit and know nothing about sessions, and everything that names a
// session, a project or a runner lives here.
//
// A package apart rather than a corner of DrakarKit, because DrakarKit keeps ZERO
// dependencies: its suite resolves nothing and runs offline. The kit is a dependency, so it
// comes in here, and DrakarKit stays as it was.
//
// What is deliberately NOT here: the app's session model, the host connection and the
// windows. This package reaches them through `SessionSource`, and the app answers it from
// the same calls its own controls make. That is what lets the tool table, the argument
// parsing and the encoding be tested offline against a fake, with no app and no port.
//
// A remote dependency rather than a `path:`, because a clone on another machine (CI's among
// them) has no checkout of the kit beside it. Up to the next minor: a kit release is picked
// up on purpose.
let package = Package(
  name: "DrakarMCP",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "DrakarMCP", targets: ["DrakarMCP"])
  ],
  dependencies: [
    .package(url: "https://github.com/mgcrea/swift-mcp-kit.git", .upToNextMinor(from: "1.6.1")),
    .package(path: "../DrakarKit"),
  ],
  targets: [
    .target(
      name: "DrakarMCP",
      dependencies: [
        .product(name: "MCPKit", package: "swift-mcp-kit"),
        .product(name: "DrakarKit", package: "DrakarKit"),
      ]),
    .testTarget(
      name: "DrakarMCPTests",
      dependencies: [
        "DrakarMCP",
        .product(name: "MCPKit", package: "swift-mcp-kit"),
        .product(name: "DrakarKit", package: "DrakarKit"),
      ]),
  ]
)
