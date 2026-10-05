import Foundation

/// A skill or command the project's `claude` offers: one entry of the `initialize` reply's
/// `commands` (docs/claude-stream-json.md, "Skills and MCP status").
public struct SkillEntry: Sendable, Hashable, Identifiable {
  public var name: String
  public var description: String
  /// What the skill takes after its name; empty when it takes nothing.
  public var argumentHint: String

  public init(name: String, description: String = "", argumentHint: String = "") {
    self.name = name
    self.description = description
    self.argumentHint = argumentHint
  }

  public var id: String { name }

  /// A click sends a skill that takes nothing at once, and puts one that does in the
  /// composer.
  public var takesArguments: Bool {
    !argumentHint.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// An entry of `commands`; nil for one without a name, or for the CLI's own (`builtin`),
  /// which covers the skills it bundles too.
  init?(_ json: JSONValue) {
    guard let name = json["name"]?.stringValue, !name.isEmpty,
      json["builtin"]?.boolValue != true
    else { return nil }
    self.init(
      name: name, description: json["description"]?.stringValue ?? "",
      argumentHint: json["argumentHint"]?.stringValue ?? "")
  }
}

/// A server's state, in the CLI's words.
public enum MCPServerStatus: Sendable, Hashable {
  case connected
  case needsAuth
  case failed
  case pending
  /// A status this version of Drakar does not know, as the CLI wrote it.
  case other(String)

  public init(_ raw: String) {
    switch raw {
    case "connected": self = .connected
    case "needs-auth": self = .needsAuth
    case "failed": self = .failed
    case "pending": self = .pending
    default: self = .other(raw)
    }
  }
}

public struct MCPTool: Sendable, Hashable {
  public var name: String
  public var isReadOnly: Bool
  public var isDestructive: Bool

  public init(name: String, isReadOnly: Bool, isDestructive: Bool) {
    self.name = name
    self.isReadOnly = isReadOnly
    self.isDestructive = isDestructive
  }
}

/// One server of the `mcp_status` reply. Its `config` is never read: it carries the
/// server's headers, env values and URLs, tokens among them, in clear.
public struct MCPServerEntry: Sendable, Hashable, Identifiable {
  public var name: String
  public var status: MCPServerStatus
  /// Where it is configured, in the CLI's words: `user`, `project`, `local`, `plugin`,
  /// `claudeai`.
  public var source: String?
  public var version: String?
  public var tools: [MCPTool]
  /// Why it failed, for a failed server.
  public var error: String?

  public init(
    name: String, status: MCPServerStatus, source: String? = nil, version: String? = nil,
    tools: [MCPTool] = [], error: String? = nil
  ) {
    self.name = name
    self.status = status
    self.source = source
    self.version = version
    self.tools = tools
    self.error = error
  }

  public var id: String { name }

  init?(_ json: JSONValue) {
    guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
    self.init(
      name: name, status: MCPServerStatus(json["status"]?.stringValue ?? ""),
      source: json["source"]?.stringValue,
      version: json["serverInfo"]?["version"]?.stringValue,
      tools: (json["tools"]?.arrayValue ?? []).compactMap { tool in
        guard let name = tool["name"]?.stringValue else { return nil }
        return MCPTool(
          name: name, isReadOnly: tool["annotations"]?["readOnly"]?.boolValue == true,
          isDestructive: tool["annotations"]?["destructive"]?.boolValue == true)
      },
      error: json["error"]?.stringValue)
  }
}

/// What a project's `claude` would load: its skills and its MCP servers, each nil until a
/// reply listed it.
public struct ProjectCapabilities: Sendable, Equatable {
  public var skills: [SkillEntry]?
  public var mcpServers: [MCPServerEntry]?

  public init(skills: [SkillEntry]? = nil, mcpServers: [MCPServerEntry]? = nil) {
    self.skills = skills
    self.mcpServers = mcpServers
  }

  /// The skills an `initialize` reply lists, the CLI's own left out; nil when it has no
  /// `commands` at all, which is not the same as an empty list.
  public static func skills(fromInitialize reply: JSONValue?) -> [SkillEntry]? {
    guard let commands = reply?["commands"]?.arrayValue else { return nil }
    return sorted(commands.compactMap(SkillEntry.init))
  }

  /// The servers an `mcp_status` reply lists; nil when it has no `mcpServers`.
  public static func servers(fromMCPStatus reply: JSONValue?) -> [MCPServerEntry]? {
    guard let servers = reply?["mcpServers"]?.arrayValue else { return nil }
    return sorted(servers.compactMap(MCPServerEntry.init))
  }
}

/// A plugin's skills and servers are namespaced: `superpowers:brainstorming`,
/// `plugin:stripe:stripe`. Rows show the namespace quieter than the name.
public enum CapabilityName {
  /// Everything before the last colon; nil without one, or when nothing follows it.
  public static func namespace(of name: String) -> String? {
    guard let colon = name.lastIndex(of: ":"), name.index(after: colon) != name.endIndex
    else { return nil }
    return String(name[..<colon])
  }

  /// What follows the last colon, or the whole name.
  public static func shortName(of name: String) -> String {
    guard namespace(of: name) != nil, let colon = name.lastIndex(of: ":") else { return name }
    return String(name[name.index(after: colon)...])
  }

  /// Case- and accent-insensitive, the query trimmed; a blank query matches everything.
  static func matches(_ query: String, in fields: [String]) -> Bool {
    let query = query.trimmingCharacters(in: .whitespaces)
    return query.isEmpty || fields.contains { $0.localizedStandardContains(query) }
  }
}

extension SkillEntry {
  public var namespace: String? { CapabilityName.namespace(of: name) }
  public var shortName: String { CapabilityName.shortName(of: name) }

  /// The description without the `(superpowers) ` the CLI puts ahead of a plugin's.
  public var displayDescription: String {
    guard let namespace, description.hasPrefix("(\(namespace)) ") else { return description }
    return String(description.dropFirst(namespace.count + 3))
  }

  public func matches(_ query: String) -> Bool {
    CapabilityName.matches(query, in: [name, description])
  }
}

extension MCPServerEntry {
  public var namespace: String? { CapabilityName.namespace(of: name) }
  public var shortName: String { CapabilityName.shortName(of: name) }

  /// Failed, or waiting for the person to sign in.
  public var isProblem: Bool { status == .failed || status == .needsAuth }

  public func matches(_ query: String) -> Bool {
    CapabilityName.matches(query, in: [name])
  }
}

extension MCPServerStatus {
  /// Failed first, then needing auth, then the rest.
  var rank: Int {
    switch self {
    case .failed: 0
    case .needsAuth: 1
    case .connected, .pending, .other: 2
    }
  }
}

extension ProjectCapabilities {
  /// Alphabetical by the name without its namespace, so `superpowers:brainstorming` sorts
  /// under b; the whole name breaks a tie.
  public static func sorted(_ skills: [SkillEntry]) -> [SkillEntry] {
    skills.sorted { a, b in
      switch a.shortName.localizedStandardCompare(b.shortName) {
      case .orderedAscending: true
      case .orderedDescending: false
      case .orderedSame: a.name < b.name
      }
    }
  }

  /// What needs the person first, alphabetical within each.
  public static func sorted(_ servers: [MCPServerEntry]) -> [MCPServerEntry] {
    servers.sorted { a, b in
      if a.status.rank != b.status.rank { return a.status.rank < b.status.rank }
      return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
  }
}

/// What a new reading of a project's lists brings that the person should see: skills that
/// were not there, and servers that went wrong.
public struct CapabilityChanges: Sendable, Equatable {
  public var addedSkills: [String]
  /// New and failed or needing auth, or connected before and not now.
  public var worsenedServers: [String]

  public init(addedSkills: [String] = [], worsenedServers: [String] = []) {
    self.addedSkills = addedSkills
    self.worsenedServers = worsenedServers
  }

  public var isEmpty: Bool { addedSkills.isEmpty && worsenedServers.isEmpty }

  /// A list read for the first time (`old` nil, or that list nil in it) marks nothing. A
  /// removed row and a status that got better mark nothing either.
  public static func diff(from old: ProjectCapabilities?, to new: ProjectCapabilities)
    -> CapabilityChanges
  {
    var changes = CapabilityChanges()
    if let before = old?.skills, let after = new.skills {
      let known = Set(before.map(\.name))
      changes.addedSkills = after.map(\.name).filter { !known.contains($0) }
    }
    if let before = old?.mcpServers, let after = new.mcpServers {
      let previous = Dictionary(
        before.map { ($0.name, $0.status) }, uniquingKeysWith: { first, _ in first })
      changes.worsenedServers = after.filter { server in
        guard let was = previous[server.name] else { return server.isProblem }
        return was == .connected && server.status != .connected
      }.map(\.name)
    }
    return changes
  }
}

/// The probe's two answers as they arrive, told apart by the request ids it sent.
public struct CapabilityReplies: Sendable, Equatable {
  public let initializeID: String
  public let statusID: String
  public private(set) var capabilities = ProjectCapabilities()
  public private(set) var hasInitialize = false
  public private(set) var hasStatus = false
  /// The CLI's error, when it answered a request with one.
  public private(set) var initializeError: String?
  public private(set) var statusError: String?

  public init(initializeID: String, statusID: String) {
    self.initializeID = initializeID
    self.statusID = statusID
  }

  public var isComplete: Bool { hasInitialize && hasStatus }

  public mutating func take(_ response: ControlResponse) {
    switch response.requestID {
    case initializeID:
      hasInitialize = true
      if response.isSuccess {
        capabilities.skills = ProjectCapabilities.skills(fromInitialize: response.response)
      } else {
        initializeError = response.error
      }
    case statusID:
      hasStatus = true
      if response.isSuccess {
        capabilities.mcpServers = ProjectCapabilities.servers(fromMCPStatus: response.response)
      } else {
        statusError = response.error
      }
    default:
      break
    }
  }
}
