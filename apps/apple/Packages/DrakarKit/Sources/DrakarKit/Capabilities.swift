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
    return commands.compactMap(SkillEntry.init)
  }

  /// The servers an `mcp_status` reply lists; nil when it has no `mcpServers`.
  public static func servers(fromMCPStatus reply: JSONValue?) -> [MCPServerEntry]? {
    guard let servers = reply?["mcpServers"]?.arrayValue else { return nil }
    return servers.compactMap(MCPServerEntry.init)
  }
}
