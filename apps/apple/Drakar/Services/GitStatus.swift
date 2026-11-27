import DrakarKit
import Foundation

struct GitStatus {
  struct Change: Identifiable {
    let path: String
    let originalPath: String?
    let code: String
    let isSubmodule: Bool

    init(path: String, originalPath: String?, code: String, isSubmodule: Bool = false) {
      self.path = path
      self.originalPath = originalPath
      self.code = code
      self.isSubmodule = isSubmodule
    }

    var id: String { (code == "??" ? "? " : "  ") + path }
    var existsOnDisk: Bool { code == "DU" || code == "UD" || !code.contains("D") }
    var canOpen: Bool { !isSubmodule && !path.hasSuffix("/") && existsOnDisk }

    var description: String {
      switch code {
      case "??": return String(localized: "Untracked")
      case "DD", "AU", "UD", "UA", "DU", "AA", "UU": return String(localized: "Merge conflict")
      default:
        let staged = Self.label(code.first).map { String(localized: "Staged: \($0)") }
        let unstaged = Self.label(code.last).map { String(localized: "Unstaged: \($0)") }
        return [staged, unstaged].compactMap { $0 }.joined(separator: " · ")
      }
    }

    private static func label(_ code: Character?) -> String? {
      switch code {
      case "A": String(localized: "Added")
      case "C": String(localized: "Copied")
      case "D": String(localized: "Deleted")
      case "M": String(localized: "Modified")
      case "R": String(localized: "Renamed")
      case "T": String(localized: "Type changed")
      default: nil
      }
    }
  }

  enum Result {
    case repository(GitStatus)
    case noRepository
    case unavailable
  }

  let root: URL
  let branch: String?
  let changes: [Change]

  static func read(in folder: URL) async -> Result {
    do {
      let location = try await run(["rev-parse", "--show-toplevel"], in: folder)
      if location.status != 0 {
        let error = String(decoding: location.errors, as: UTF8.self)
        return error.hasPrefix("fatal: not a git repository") ? .noRepository : .unavailable
      }
      // Strip Git's terminator while preserving whitespace and newlines in the folder name.
      let rawRoot = location.output.last == 0x0A ? location.output.dropLast() : location.output[...]
      guard !rawRoot.isEmpty else { return .unavailable }
      let root = URL(
        filePath: String(decoding: rawRoot, as: UTF8.self),
        directoryHint: .isDirectory)
      try Task.checkCancellation()
      let status = try await run(
        ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], in: root)
      guard status.status == 0 else { return .unavailable }
      return .repository(GitStatus(root: root, output: status.output))
    } catch {
      return .unavailable
    }
  }

  private static func run(_ arguments: [String], in folder: URL) async throws
    -> ProcessRunner.Output
  {
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "C"
    return try await ProcessRunner.run(
      URL(filePath: "/usr/bin/git"),
      ["--no-optional-locks", "-c", "core.fsmonitor=false"] + arguments,
      environment: environment, currentDirectory: folder, timeout: .seconds(8))
  }

  init(root: URL, output: Data) {
    self.root = root
    var records = output.split(separator: 0).makeIterator()
    var head: String?
    var commit: String?
    var changes: [Change] = []
    while let bytes = records.next() {
      let record = String(decoding: bytes, as: UTF8.self)
      switch String(decoding: bytes.prefix(2), as: UTF8.self) {
      case "# ":
        if record.hasPrefix("# branch.head ") {
          head = String(record.dropFirst("# branch.head ".count))
        } else if record.hasPrefix("# branch.oid ") {
          commit = String(record.dropFirst("# branch.oid ".count))
        }
      case "? ":
        changes.append(
          Change(
            path: String(decoding: bytes.dropFirst(2), as: UTF8.self), originalPath: nil, code: "??"
          ))
      case "1 ", "2 ", "u ":
        let isRename = record.hasPrefix("2 ")
        let isUnmerged = record.hasPrefix("u ")
        let originalPath =
          isRename ? records.next().map { String(decoding: $0, as: UTF8.self) } : nil
        let fieldCount = isRename ? 9 : isUnmerged ? 10 : 8
        let fields = bytes.split(
          separator: 32, maxSplits: fieldCount, omittingEmptySubsequences: false)
        guard fields.count == fieldCount + 1 else { continue }
        let sub = String(decoding: fields[2], as: UTF8.self)
        let worktreeMode = String(decoding: fields[isUnmerged ? 6 : 5], as: UTF8.self)
        let isSubmodule = sub.hasPrefix("S") || worktreeMode == "160000" || worktreeMode == "040000"
        changes.append(
          Change(
            path: String(decoding: fields[fieldCount], as: UTF8.self), originalPath: originalPath,
            code: String(decoding: fields[1], as: UTF8.self), isSubmodule: isSubmodule))
      default:
        continue
      }
    }
    branch = head == "(detached)" ? commit.map { String($0.prefix(7)) } : head
    self.changes = changes
  }
}
