import Foundation

/// One skill or command found on disk, where it was found.
public struct ScannedSkill: Sendable, Hashable {
  public var name: String
  public var description: String
  public var kind: SkillKind
  public var origin: SkillOrigin
  /// Who reads the folder it was found in.
  public var agent: SkillAgent
  /// Where it was found: the link, when it is one.
  public var path: String
  /// The folder (or command file) with every link resolved; a missing link's target.
  public var realPath: String
  public var isLink: Bool
  /// The target of a link whose target is gone; nil otherwise.
  public var missingTarget: String?
  /// A plugin's skill whose plugin the account's `settings.json` turns off.
  public var isPluginDisabled: Bool

  public init(
    name: String, description: String = "", kind: SkillKind = .skill, origin: SkillOrigin,
    agent: SkillAgent = .claude, path: String, realPath: String, isLink: Bool = false,
    missingTarget: String? = nil, isPluginDisabled: Bool = false
  ) {
    self.name = name
    self.description = description
    self.kind = kind
    self.origin = origin
    self.agent = agent
    self.path = path
    self.realPath = realPath
    self.isLink = isLink
    self.missingTarget = missingTarget
    self.isPluginDisabled = isPluginDisabled
  }
}

/// The places Claude Code reads skills from, read the way it reads them: the account's
/// `skills/`, the project's `.claude/skills/` and `.claude/commands/`, and the skills of the
/// plugins in effect for the project. Claude Code's `initialize` reports names only, so this
/// is where the Skills window learns where a skill lives.
public enum ClaudeSkillScan {
  public struct Result: Sendable, Equatable {
    public var skills: [ScannedSkill]
    /// What could not be read, a sentence each.
    public var problems: [String]

    public init(skills: [ScannedSkill] = [], problems: [String] = []) {
      self.skills = skills
      self.problems = problems
    }
  }

  /// `account` is the account's directory, `project` nil for user-level skills only.
  /// `codexFolders` are read for links whose target is gone, which Codex does not list.
  public static func scan(account: URL, project: URL?, codexFolders: [SkillFolder] = [])
    -> Result
  {
    var result = Result()
    result.skills += skills(in: account.appending(path: "skills"), origin: .user)
    if let project {
      result.skills += skills(in: project.appending(path: ".claude/skills"), origin: .project)
      result.skills += commands(in: project.appending(path: ".claude/commands"))
    }
    plugins(account: account, project: project, into: &result)
    for folder in codexFolders {
      result.skills += skills(in: folder.url, origin: folder.origin, agent: .codex).filter {
        $0.missingTarget != nil
      }
    }
    return result
  }

  /// Each folder of `folder` holding a SKILL.md, and each link in it whose target is gone, in
  /// name order. Hidden entries are skipped.
  static func skills(
    in folder: URL, origin: SkillOrigin, agent: SkillAgent = .claude, prefix: String = "",
    disabled: Bool = false
  ) -> [ScannedSkill] {
    let manager = FileManager.default
    let names = ((try? manager.contentsOfDirectory(atPath: path(folder))) ?? [])
      .filter { !$0.hasPrefix(".") }.sorted()
    return names.compactMap { name in
      let location = path(folder.appending(path: name))
      let isLink = SkillPath.isLink(location)
      if isLink, !manager.fileExists(atPath: location) {
        let target = SkillPath.target(ofLink: location) ?? location
        return ScannedSkill(
          name: prefix + name, origin: origin, agent: agent, path: location, realPath: target,
          isLink: true, missingTarget: target, isPluginDisabled: disabled)
      }
      let file = location + "/SKILL.md"
      guard manager.fileExists(atPath: file) else { return nil }
      let fields = SkillFrontmatter.fields(head(file))
      let named = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? name
      return ScannedSkill(
        name: prefix + named, description: fields["description"] ?? "", origin: origin,
        agent: agent, path: location, realPath: SkillPath.real(location), isLink: isLink,
        isPluginDisabled: disabled)
    }
  }

  /// The project's commands, every `.md` below `folder`, named by their path below it.
  static func commands(in folder: URL) -> [ScannedSkill] {
    let root = path(folder)
    guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
    var found: [ScannedSkill] = []
    for case let relative as String in walker
    where relative.hasSuffix(".md")
      && !relative.split(separator: "/").contains(where: {
        $0.hasPrefix(".")
      })
    {
      let location = root + "/" + relative
      var isFolder: ObjCBool = false
      guard FileManager.default.fileExists(atPath: location, isDirectory: &isFolder),
        !isFolder.boolValue
      else { continue }
      let name = String(relative.dropLast(3)).replacingOccurrences(of: "/", with: ":")
      let fields = SkillFrontmatter.fields(head(location))
      found.append(
        ScannedSkill(
          name: name, description: fields["description"] ?? "", kind: .command,
          origin: .project, path: location, realPath: SkillPath.real(location),
          isLink: SkillPath.isLink(location)))
    }
    return found.sorted { $0.path < $1.path }
  }

  /// The skills of every plugin `installed_plugins.json` (version 2) has in effect, named
  /// `plugin:skill`. A file of another shape is a problem; an entry of another shape is skipped.
  static func plugins(account: URL, project: URL?, into result: inout Result) {
    let file = account.appending(path: "plugins/installed_plugins.json")
    guard let data = FileManager.default.contents(atPath: path(file)) else { return }
    guard let json = try? JSONValue.parse(data), case .object(let plugins)? = json["plugins"]
    else {
      result.problems.append(
        "Couldn't read the plugins Claude Code installed: \(path(file)) is not in a shape Drakar knows."
      )
      return
    }
    let enabled = enabledPlugins(account)
    for id in plugins.keys.sorted() {
      let value = plugins[id] ?? .null
      let installs = value.arrayValue ?? [value]
      guard let installPath = install(in: installs, for: project)?["installPath"]?.stringValue,
        !installPath.isEmpty
      else { continue }
      let name = id.split(separator: "@", maxSplits: 1).first.map(String.init) ?? id
      result.skills += skills(
        in: URL(filePath: installPath, directoryHint: .isDirectory).appending(path: "skills"),
        origin: .plugin(id), prefix: name + ":", disabled: enabled[id] == false)
    }
  }

  /// The install in effect for `project`: a local one of this project, else a project one of
  /// it, else the user's.
  static func install(in installs: [JSONValue], for project: URL?) -> JSONValue? {
    let here = project.map(path)
    func rank(_ install: JSONValue) -> Int? {
      switch install["scope"]?.stringValue {
      case "user": return 2
      case let scope? where scope == "local" || scope == "project":
        guard let here, let at = install["projectPath"]?.stringValue,
          ProjectPath.normalize(at) == here
        else { return nil }
        return scope == "local" ? 0 : 1
      default: return nil
      }
    }
    return installs.compactMap { install in rank(install).map { ($0, install) } }
      .min { $0.0 < $1.0 }?.1
  }

  /// `enabledPlugins` of the account's `settings.json`; a plugin it does not name is on.
  static func enabledPlugins(_ account: URL) -> [String: Bool] {
    guard
      let data = FileManager.default.contents(
        atPath: path(account.appending(path: "settings.json"))),
      let json = try? JSONValue.parse(data), case .object(let flags)? = json["enabledPlugins"]
    else { return [:] }
    return flags.compactMapValues(\.boolValue)
  }

  /// The first 16 KB of a file, where the frontmatter is.
  static func head(_ path: String) -> String {
    guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: 16_384)) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  static func path(_ url: URL) -> String { ProjectPath.normalize(url.path(percentEncoded: false)) }
}
