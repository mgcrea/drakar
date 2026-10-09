import DrakarKit
import Foundation

extension URL {
  /// The path as skill rows spell it: no trailing slash.
  nonisolated var skillPath: String { ProjectPath.normalize(path(percentEncoded: false)) }
}

/// How the Skills window writes a path: under the home folder with `~`.
enum SkillText {
  nonisolated static func path(
    _ path: String,
    home: String = FileManager.default.homeDirectoryForCurrentUser.skillPath
  ) -> String {
    let path = ProjectPath.normalize(path)
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
  }

  nonisolated static func path(_ url: URL) -> String { path(url.skillPath) }
}

/// The two places a skill of the person's own lives.
enum SkillPlace: CaseIterable {
  /// The account's and `~/.agents`'s: every project.
  case user
  case project
}

extension SkillOrigin {
  /// The place an own skill lives in; nil for the others.
  var place: SkillPlace? {
    switch self {
    case .user: .user
    case .project: .project
    default: nil
    }
  }
}

extension SkillAgent {
  var kind: AgentKind { self == .claude ? .claude : .codex }
}

/// The folders one account and one project keep skills in: where installs and shares write,
/// and where a delete looks for links.
struct SkillPlaces: Equatable {
  var account: URL
  var home: URL
  var project: URL?

  /// Where an install or a share for `agent` writes in `place`; nil for the project without one.
  func folder(_ place: SkillPlace, for agent: SkillAgent) -> URL? {
    switch (place, agent) {
    case (.user, .claude): account.appending(path: "skills", directoryHint: .isDirectory)
    case (.user, .codex): home.appending(path: ".agents/skills", directoryHint: .isDirectory)
    case (.project, .claude):
      project?.appending(path: ".claude/skills", directoryHint: .isDirectory)
    case (.project, .codex):
      project?.appending(path: ".agents/skills", directoryHint: .isDirectory)
    }
  }

  /// Every folder a skill of the person's own sits in: the four install folders, Codex's
  /// `.codex/skills`, and the project's commands.
  var roots: [URL] {
    var roots = [
      account.appending(path: "skills", directoryHint: .isDirectory),
      home.appending(path: ".agents/skills", directoryHint: .isDirectory),
      home.appending(path: ".codex/skills", directoryHint: .isDirectory),
    ]
    if let project {
      roots += [".claude/skills", ".claude/commands", ".agents/skills", ".codex/skills"].map {
        project.appending(path: $0, directoryHint: .isDirectory)
      }
    }
    return roots
  }

  /// Codex's folders, read for links whose target is gone: Codex lists none of those.
  var codexFolders: [SkillFolder] {
    var folders = [
      SkillFolder(url: home.appending(path: ".agents/skills"), origin: .user),
      SkillFolder(url: home.appending(path: ".codex/skills"), origin: .user),
    ]
    if let project {
      folders += [
        SkillFolder(url: project.appending(path: ".agents/skills"), origin: .project),
        SkillFolder(url: project.appending(path: ".codex/skills"), origin: .project),
      ]
    }
    return folders
  }

  /// Where git installs clone to.
  var sources: URL { home.appending(path: ".agents/skill-sources", directoryHint: .isDirectory) }

  func clone(containing path: String) -> URL? { Self.clone(containing: path, sources: sources) }

  /// The clone `path` lies in, `<sources>/<host>/<owner>/<repo>`; nil outside them.
  static func clone(containing path: String, sources: URL) -> URL? {
    for root in spellings(of: sources) where ProjectPath.contains(root, path) && path != root {
      let parts = path.dropFirst(root.count + 1).split(separator: "/")
      guard parts.count >= 3 else { return nil }
      return URL(
        filePath: root + "/" + parts.prefix(3).joined(separator: "/"), directoryHint: .isDirectory)
    }
    return nil
  }

  /// A folder as written and as resolved, which differ when a link leads to it.
  static func spellings(of folder: URL) -> [String] {
    let written = folder.skillPath
    let real = SkillPath.real(written)
    return written == real ? [written] : [written, real]
  }
}

/// The file operations the actions make, apart so tests can give a trash of their own.
struct SkillFileSystem {
  /// Moves an item to the Trash; tests move it into a folder of theirs.
  var moveToTrash: (URL) throws -> Void = {
    try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
  }

  private var manager: FileManager { .default }

  /// Something is at `url`, a link whose target is gone included.
  func exists(_ url: URL) -> Bool {
    (try? manager.attributesOfItem(atPath: url.skillPath)) != nil
  }

  func isLink(_ url: URL) -> Bool { SkillPath.isLink(url.skillPath) }

  func createFolder(_ url: URL) throws {
    try manager.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func link(_ url: URL, to target: URL) throws {
    try manager.createSymbolicLink(at: url, withDestinationURL: target)
  }

  func copy(_ source: URL, to destination: URL) throws {
    try manager.copyItem(at: source, to: destination)
  }

  func trash(_ url: URL) throws { try moveToTrash(url) }

  /// Removes the link itself, never what it points to; anything else at `url` is refused.
  /// The check comes first because `unlink` would remove a file; `unlink` cannot remove a
  /// folder, so one swapped in after the check stays.
  func removeLink(_ url: URL) throws {
    guard isLink(url) else { throw SkillActionError.notALink(url) }
    guard unlink(url.skillPath) != 0 else { return }
    let code = errno
    switch code {
    case EPERM, EISDIR, ENOTDIR, ENOENT: throw SkillActionError.notALink(url)
    default:
      throw SkillActionError(
        message: String(
          localized:
            "Couldn't remove the link at \(SkillText.path(url)): \(String(cString: strerror(code)))."
        ))
    }
  }

  func children(of folder: URL) -> [URL] {
    ((try? manager.contentsOfDirectory(atPath: folder.skillPath)) ?? []).sorted().map {
      folder.appending(path: $0)
    }
  }

  /// The first `limit` bytes of a file, as text; nil when it cannot be read.
  func read(_ url: URL, limit: Int) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: limit) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}

/// Why an action did nothing, as the window's alert says it.
struct SkillActionError: Error, LocalizedError, Equatable {
  var message: String
  var errorDescription: String? { message }

  static func exists(_ name: String, in folder: URL) -> SkillActionError {
    SkillActionError(
      message: String(
        localized:
          "A skill named \(name) is already in \(SkillText.path(folder)). Nothing was written."))
  }

  static func notALink(_ url: URL) -> SkillActionError {
    SkillActionError(
      message: String(localized: "\(SkillText.path(url)) is not a link, so it was left alone."))
  }
}

/// What a delete will do, step by step, and the sentences the confirmation says it in.
struct DeletePlan: Equatable {
  enum Step: Hashable {
    case removeLink(String)
    case trash(String)
  }

  var steps: [Step] = []
  /// One sentence per step, in the same order.
  var lines: [String] = []

  /// `targetStays` when nothing in the plan trashes the folder the link points to.
  mutating func removeLink(_ link: String, targetStays: Bool) {
    steps.append(.removeLink(link))
    lines.append(
      targetStays
        ? String(
          localized: "Remove the link at \(SkillText.path(link)) (the folder it points to stays).")
        : String(localized: "Remove the link at \(SkillText.path(link))."))
  }

  mutating func trash(_ item: String, saying line: String) {
    steps.append(.trash(item))
    lines.append(line)
  }
}

/// How Install from Folder… puts a skill in place.
enum InstallMethod {
  /// A link per agent to the folder where it is.
  case link
  /// Copied once into the first agent's folder, the other agent linked to the copy.
  case copy
}

/// The Skills window's file operations: share, delete, install. Nothing overwrites: a name
/// already taken at a destination is refused before anything is written.
struct SkillActions {
  var places: SkillPlaces
  var files = SkillFileSystem()

  /// A link, in the other agent's folder of the same place, to the skill's real folder;
  /// returns the link.
  @discardableResult
  func share(_ record: SkillRecord) throws -> URL {
    guard record.canShare, let place = record.origin.place,
      let seen = record.sightings.first(where: { $0.path != nil }), let seenPath = seen.path
    else {
      throw SkillActionError(
        message: String(
          localized: "Only your own skills and the project's can be shared; commands cannot."))
    }
    let other = seen.agent.other
    guard record.sighting(for: other) == nil else {
      throw SkillActionError(
        message: String(localized: "\(other.kind.name) already sees \(record.name)."))
    }
    guard let folder = places.folder(place, for: other) else {
      throw SkillActionError(message: String(localized: "Choose a project to share its skills."))
    }
    let destination = folder.appending(path: URL(filePath: seenPath).lastPathComponent)
    guard !files.exists(destination) else {
      throw SkillActionError.exists(destination.lastPathComponent, in: folder)
    }
    try files.createFolder(folder)
    try files.link(destination, to: URL(filePath: record.realPath))
    return destination
  }

  /// What deleting `record` does: each link to it goes. The real folder (or command file) goes
  /// to the Trash only when the row shows it, not just a link to it, and it lies in one of the
  /// skill folders; a clone goes with its last link. Anything else stays.
  func deletePlan(for record: SkillRecord) throws -> DeletePlan {
    guard record.canDelete else {
      throw SkillActionError(
        message: String(
          localized:
            "\(record.name) is not yours to delete here: plugins, Codex's own skills and unknown ones are managed elsewhere."
        ))
    }
    var found: [String] = []
    var seen = Set<String>()
    let candidates =
      record.sightings.filter(\.isLink).compactMap(\.path).map(ProjectPath.normalize)
      + links(where: { $0 == record.realPath })
    for link in candidates where seen.insert(Self.key(ofLink: link)).inserted {
      found.append(link)
    }
    var trash: (path: String, line: String)?
    if !record.isMissing, files.exists(URL(filePath: record.realPath)) {
      if let clone = places.clone(containing: record.realPath) {
        let spellings = SkillPlaces.spellings(of: clone)
        let others = links { target in spellings.contains { ProjectPath.contains($0, target) } }
          .filter { !seen.contains(Self.key(ofLink: $0)) }
        if others.isEmpty {
          trash = (
            clone.skillPath,
            String(
              localized:
                "Move the clone at \(SkillText.path(clone)) to the Trash: no link in these folders points into it."
            )
          )
        }
      } else if showsRealFolder(record), isInRoots(record.realPath) {
        trash = (
          record.realPath,
          String(localized: "Move \(SkillText.path(record.realPath)) to the Trash.")
        )
      }
    }
    var plan = DeletePlan()
    for link in found { plan.removeLink(link, targetStays: trash == nil && !record.isMissing) }
    if let trash { plan.trash(trash.path, saying: trash.line) }
    guard !plan.steps.isEmpty else {
      throw SkillActionError(
        message: String(
          localized:
            "\(SkillText.path(record.realPath)) stays: Drakar deletes only links to a skill and folders it shows in the skill folders."
        ))
    }
    return plan
  }

  /// Carries out a plan: the links first, then the Trash. Every step is checked against the
  /// disk before any is made, and again right before it; one that no longer matches stops it.
  func delete(_ plan: DeletePlan) throws {
    for step in plan.steps { try check(step) }
    for step in plan.steps {
      try check(step)
      switch step {
      case .removeLink(let path): try files.removeLink(URL(filePath: path))
      case .trash(let path): try files.trash(URL(filePath: path))
      }
    }
  }

  /// Puts each skill folder of `sources` into `place` for `agents`, Claude Code first: a link
  /// per agent, or one copy and links to it. Every destination is checked before anything is
  /// written, and nothing is ever replaced; returns what was made. A step that fails after
  /// others succeeded says what was already made.
  @discardableResult
  func install(
    _ sources: [URL], place: SkillPlace, agents: [SkillAgent], method: InstallMethod
  ) throws -> [URL] {
    let agents = SkillAgent.allCases.filter(agents.contains)
    guard !agents.isEmpty, !sources.isEmpty else {
      throw SkillActionError(
        message: String(localized: "Choose a skill, and Claude Code, Codex or both."))
    }
    let folders = try agents.map { agent in
      guard let folder = places.folder(place, for: agent) else {
        throw SkillActionError(message: String(localized: "Choose a project to install into it."))
      }
      return folder
    }
    var names = Set<String>()
    for source in sources {
      let name = source.lastPathComponent
      guard files.exists(source.appending(path: "SKILL.md")) else {
        throw SkillActionError(
          message: String(
            localized: "\(SkillText.path(source)) has no SKILL.md, so it is not a skill."))
      }
      guard names.insert(name).inserted else {
        throw SkillActionError(
          message: String(localized: "Two of the chosen skills are named \(name)."))
      }
      for folder in folders where files.exists(folder.appending(path: name)) {
        throw SkillActionError.exists(name, in: folder)
      }
    }
    var made: [URL] = []
    do {
      for source in sources {
        let name = source.lastPathComponent
        var target = URL(filePath: SkillPath.real(source.skillPath), directoryHint: .isDirectory)
        for (index, folder) in folders.enumerated() {
          try files.createFolder(folder)
          let destination = folder.appending(path: name)
          if method == .copy, index == 0 {
            try files.copy(target, to: destination)
            target = destination
          } else {
            try files.link(destination, to: target)
          }
          made.append(destination)
        }
      }
    } catch {
      guard !made.isEmpty else { throw error }
      let list = made.map { SkillText.path($0) }.joined(separator: ", ")
      throw SkillActionError(
        message: String(
          localized:
            "The install stopped: \(error.localizedDescription) Already made, and left in place: \(list)."
        ))
    }
    return made
  }

  /// A link to remove is still a link; an item to trash is still there, not a link, and still
  /// resolves to itself: a link put in its place or above it leads elsewhere.
  private func check(_ step: DeletePlan.Step) throws {
    switch step {
    case .removeLink(let path):
      guard files.isLink(URL(filePath: path)) else {
        throw SkillActionError.notALink(URL(filePath: path))
      }
    case .trash(let path):
      let url = URL(filePath: path)
      guard files.exists(url), !files.isLink(url), SkillPath.real(path) == path else {
        throw SkillActionError(
          message: String(
            localized:
              "\(SkillText.path(path)) changed since the delete was planned, so nothing more was done."
          ))
      }
    }
  }

  /// The row shows the real folder (or command file) itself: a sighting of it that is no link.
  private func showsRealFolder(_ record: SkillRecord) -> Bool {
    record.sightings.contains { sighting in
      !sighting.isLink && sighting.path.map(SkillPath.real) == record.realPath
    }
  }

  /// One link however its folder is spelled: the folder resolved, then the link's name.
  private static func key(ofLink path: String) -> String {
    let url = URL(filePath: path)
    return SkillPath.real(url.deletingLastPathComponent().skillPath) + "/" + url.lastPathComponent
  }

  /// The links directly in the roots whose resolved target `matches`.
  private func links(where matches: (String) -> Bool) -> [String] {
    places.roots.flatMap(files.children(of:))
      .filter { files.isLink($0) && matches(resolved($0)) }
      .map(\.skillPath)
  }

  /// A live link's real path; a dead one's target as written.
  private func resolved(_ link: URL) -> String {
    let path = link.skillPath
    return FileManager.default.fileExists(atPath: path)
      ? SkillPath.real(path) : SkillPath.target(ofLink: path) ?? path
  }

  private func isInRoots(_ path: String) -> Bool {
    places.roots.flatMap(SkillPlaces.spellings(of:)).contains {
      ProjectPath.contains($0, path) && $0 != path
    }
  }
}
