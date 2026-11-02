import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("The drakar command")
struct CommandLineToolTests {

  private let root: URL

  init() throws {
    let made = FileManager.default.temporaryDirectory
      .appending(path: "drakar-command-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    // `/private/var/…`, as the script's `pwd -P` spells it (`resolvingSymlinksInPath` gives
    // `/var/…` back).
    root = URL(
      filePath: ProjectPath.resolved(made.path(percentEncoded: false)), directoryHint: .isDirectory)
  }

  private func file(_ name: String) throws -> URL {
    let url = root.appending(path: name)
    try Data("#!/bin/sh\n".utf8).write(to: url)
    return url
  }

  /// `~/.local/bin` needs no password, but only helps when the shell looks there.
  @Test func theLinkGoesWhereTheLoginShellLooks() {
    let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
    #expect(
      CommandLineTool.directory(path: "/usr/bin:/Users/me/.local/bin/:/bin", home: home)
        .path(percentEncoded: false) == "/Users/me/.local/bin")
    #expect(
      CommandLineTool.directory(path: "/usr/bin:/bin", home: home)
        .path(percentEncoded: false) == "/usr/local/bin")
    #expect(
      CommandLineTool.directory(path: nil, home: home).path(percentEncoded: false)
        == "/usr/local/bin")
  }

  /// A link left by a Drakar that has since moved, or by a second copy, is taken over.
  @Test func installsALinkAndTakesOverAStaleOne() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let (old, current) = (try file("old.sh"), try file("current.sh"))
    let bin = root.appending(path: "bin", directoryHint: .isDirectory)
    try CommandLineTool.install(script: old, in: bin)
    #expect(CommandLineTool.isInstalled(script: old, in: bin))
    #expect(!CommandLineTool.isInstalled(script: current, in: bin))
    try CommandLineTool.install(script: current, in: bin)
    #expect(CommandLineTool.isInstalled(script: current, in: bin))
  }

  /// A home of the test's own, whose `.local/bin` the login shell's PATH names.
  private func launchHome() -> (home: URL, path: String) {
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    return (home, "/usr/bin:\(home.path(percentEncoded: false)).local/bin:/bin")
  }

  /// No password is needed for `~/.local/bin`, so the first launch links it unasked.
  @Test func theFirstLaunchLinksIntoLocalBin() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try file("drakar.sh")
    let (home, path) = launchHome()
    let outcome = CommandLineTool.linkAtLaunch(
      script: script, path: path, home: home, offeredBefore: false)
    #expect(outcome == .linked)
    #expect(
      CommandLineTool.isInstalled(script: script, in: home.appending(path: ".local/bin")))
  }

  /// `/usr/local/bin` would ask for a password: that stays Settings' button.
  @Test func aLinkThatNeedsAPasswordIsLeftToSettings() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try file("drakar.sh")
    let (home, _) = launchHome()
    let outcome = CommandLineTool.linkAtLaunch(
      script: script, path: "/usr/bin:/bin", home: home, offeredBefore: false)
    #expect(outcome == .leftToSettings)
    #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".local").path))
  }

  /// A Drakar that moved, or was reinstalled elsewhere, leaves a link to its old script:
  /// that one is Drakar's, and is pointed at this copy at every launch.
  @Test func aMovedDrakarsLinkIsRepaired() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try file("drakar.sh")
    let (home, path) = launchHome()
    let bin = home.appending(path: ".local/bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: bin.appending(path: "drakar").path(percentEncoded: false),
      withDestinationPath: "/Volumes/Old/Drakar.app/Contents/Resources/drakar.sh")
    let outcome = CommandLineTool.linkAtLaunch(
      script: script, path: path, home: home, offeredBefore: true)
    #expect(outcome == .linked)
    #expect(CommandLineTool.isInstalled(script: script, in: bin))
  }

  /// A `drakar` that is not Drakar's (a file, or a link to something else) is never touched.
  @Test func someoneElsesDrakarIsLeftAlone() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try file("drakar.sh")
    let (home, path) = launchHome()
    let bin = home.appending(path: ".local/bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let link = bin.appending(path: "drakar").path(percentEncoded: false)
    try FileManager.default.createSymbolicLink(
      atPath: link, withDestinationPath: "/opt/longships/bin/drakar")
    #expect(
      CommandLineTool.linkAtLaunch(script: script, path: path, home: home, offeredBefore: false)
        == .leftAlone)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: link) == "/opt/longships/bin/drakar"
    )
    try FileManager.default.removeItem(atPath: link)
    try Data("mine".utf8).write(to: URL(filePath: link))
    #expect(
      CommandLineTool.linkAtLaunch(script: script, path: path, home: home, offeredBefore: false)
        == .leftAlone)
    #expect(try Data(contentsOf: URL(filePath: link)) == Data("mine".utf8))
  }

  /// Linked once already, and gone since: the person removed it, and it stays removed.
  @Test func aLinkThePersonRemovedIsNotPutBack() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try file("drakar.sh")
    let (home, path) = launchHome()
    let outcome = CommandLineTool.linkAtLaunch(
      script: script, path: path, home: home, offeredBefore: true)
    #expect(outcome == .leftAlone)
    #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".local").path))
  }

  @Test func aLinkInPlaceIsLeftAsItIs() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try file("drakar.sh")
    let (home, path) = launchHome()
    try CommandLineTool.install(script: script, in: home.appending(path: ".local/bin"))
    #expect(
      CommandLineTool.linkAtLaunch(script: script, path: path, home: home, offeredBefore: true)
        == .alreadyLinked)
  }

  @Test func neverReplacesARealFile() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try file("drakar.sh")
    let bin = root.appending(path: "bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let mine = bin.appending(path: "drakar")
    try Data("mine".utf8).write(to: mine)
    #expect(throws: (any Error).self) { try CommandLineTool.install(script: script, in: bin) }
    #expect(try Data(contentsOf: mine) == Data("mine".utf8))
  }

  private func shell(_ command: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-c", command]
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  /// What runs with administrator privileges when `/usr/local/bin` is not writable, run
  /// here without them: the same link, under a folder name the quoting must survive.
  @Test func thePrivilegedCommandLinksAsTheUnprivilegedPathDoes() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let (old, current) = (try file("old.sh"), try file("it's current.sh"))
    let bin = root.appending(path: "Olivier's bin", directoryHint: .isDirectory)
    #expect(try shell(CommandLineTool.privilegedCommand(script: old, in: bin)) == 0)
    #expect(try shell(CommandLineTool.privilegedCommand(script: current, in: bin)) == 0)
    #expect(CommandLineTool.isInstalled(script: current, in: bin))
  }

  /// The AppleScript around it, run without the privileges: its string escaping must hand
  /// the shell the command unchanged.
  @Test func theAppleScriptRunsTheCommandUnchanged() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try file("it's \"quoted\".sh")
    let bin = root.appending(path: "Olivier's bin", directoryHint: .isDirectory)
    let source = CommandLineTool.appleScript(script: script, in: bin)
    #expect(source.hasSuffix(" with administrator privileges"))
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/osascript")
    process.arguments = ["-e", String(source.dropLast(" with administrator privileges".count))]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(CommandLineTool.isInstalled(script: script, in: bin))
  }

  @Test func thePrivilegedCommandNeverReplacesARealFile() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let script = try file("drakar.sh")
    let bin = root.appending(path: "bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let mine = bin.appending(path: "drakar")
    try Data("mine".utf8).write(to: mine)
    #expect(try shell(CommandLineTool.privilegedCommand(script: script, in: bin)) != 0)
    #expect(try Data(contentsOf: mine) == Data("mine".utf8))
  }

  /// Run through its link, the script opens the folder, the current one by default, in the
  /// app it sits in, wherever that app is.
  @Test func theScriptOpensTheFolderInTheAppItSitsIn() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = try #require(CommandLineTool.bundledScript)
    let resources = root.appending(path: "Copy.app/Contents/Resources", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let script = resources.appending(path: "drakar.sh")
    try FileManager.default.copyItem(at: bundled, to: script)
    let bin = root.appending(path: "bin", directoryHint: .isDirectory)
    try CommandLineTool.install(script: script, in: bin)
    let project = root.appending(path: "project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

    func run(_ arguments: [String]) throws -> String {
      let process = Process()
      process.executableURL = bin.appending(path: "drakar")
      process.arguments = arguments
      process.currentDirectoryURL = project
      process.environment = ["PATH": "/usr/bin:/bin", "DRAKAR_OPEN": "/bin/echo"]
      let pipe = Pipe()
      process.standardOutput = pipe
      try process.run()
      process.waitUntilExit()
      return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    let app = root.appending(path: "Copy.app").path(percentEncoded: false)
    let folder = project.path(percentEncoded: false).trimmingSuffix("/")
    let (bare, dot) = (try run([]), try run(["."]))
    #expect(bare == "-a \(app) \(folder)\n")
    #expect(dot == bare)
  }

  /// `cd` follows an exported `CDPATH` and reads a leading `-` as an option: neither may
  /// change which folder opens.
  @Test func theScriptOpensExactlyTheFoldersNamed() throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let bundled = try #require(CommandLineTool.bundledScript)
    let resources = root.appending(path: "Copy.app/Contents/Resources", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let script = resources.appending(path: "drakar.sh")
    try FileManager.default.copyItem(at: bundled, to: script)
    let bin = root.appending(path: "bin", directoryHint: .isDirectory)
    try CommandLineTool.install(script: script, in: bin)
    let here = root.appending(path: "here", directoryHint: .isDirectory)
    let elsewhere = root.appending(path: "elsewhere", directoryHint: .isDirectory)
    for name in ["src", "-x", "two words"] {
      try FileManager.default.createDirectory(
        at: here.appending(path: name), withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(
      at: elsewhere.appending(path: "src"), withIntermediateDirectories: true)

    // Stands in for `open`: one argument per line.
    let open = root.appending(path: "print-arguments")
    try Data("#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done\n".utf8).write(to: open)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)

    let process = Process()
    process.executableURL = bin.appending(path: "drakar")
    process.arguments = ["src", "-x", "two words"]
    process.currentDirectoryURL = here
    process.environment = [
      "PATH": "/usr/bin:/bin", "DRAKAR_OPEN": open.path(percentEncoded: false),
      "CDPATH": elsewhere.path(percentEncoded: false),
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let base = here.path(percentEncoded: false).trimmingSuffix("/")
    #expect(process.terminationStatus == 0)
    #expect(
      output.split(separator: "\n").map(String.init) == [
        "-a", root.appending(path: "Copy.app").path(percentEncoded: false),
        "\(base)/src", "\(base)/-x", "\(base)/two words",
      ])
  }
}

extension String {
  fileprivate func trimmingSuffix(_ suffix: String) -> String {
    hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
  }
}
