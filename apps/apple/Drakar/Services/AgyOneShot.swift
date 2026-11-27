import DrakarKit
import Foundation

/// An `agy acp` process started for one short exchange and closed: reading a session's
/// history (`session/load`), or probing models and slash commands (`session/new` +
/// `session/close`). Collects both RPC responses and any `session/update` notifications emitted
/// while the requests run. Ended after 30 seconds whatever it is doing.
struct AgyOneShot {
  let configuration: AgentProcess.Configuration
  var timeout: Duration = .seconds(30)

  struct Failure: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
  }

  struct Output {
    var results: [JSONValue]
    /// `params["update"]` from every `session/update` notification received during the run.
    var updates: [JSONValue]
  }

  func run(
    tolerating: Set<String> = [], _ next: (JSONValue?) -> (method: String, params: JSONValue)?
  ) async throws -> Output {
    let process = AgentProcess(configuration)
    let events = try process.start()
    let timeout = self.timeout
    let deadline = Task {
      try? await Task.sleep(for: timeout)
      process.terminate()
    }
    defer {
      deadline.cancel()
      process.closeInput()
      process.terminate()
    }
    var calls = AgyRPC.Calls<String>()
    let (_, initMsg) = calls.make(
      "initialize", AgySession.initializeParams(version: AgyLaunch.appVersion), for: "initialize")
    try process.send(initMsg)
    var results: [JSONValue] = []
    var updates: [JSONValue] = []
    var isInitialized = false
    return try await withTaskCancellationHandler {
      for await event in events {
        guard case .lines(let lines, _) = event else { continue }
        for line in lines {
          guard case .json(let json) = line, let rpc = AgyRPC.Line(json) else { continue }
          switch rpc {
          case .notification(let method, let params):
            if method == "session/update", let update = params["update"] {
              updates.append(update)
            }
            continue
          case .request(let id, let method, _):
            try? process.send(AgyRPC.refusal(id, message: "Drakar does not answer \(method)."))
            continue
          case .response(let id, let answer):
            guard calls.take(id) != nil else { continue }
            let previous: JSONValue?
            if isInitialized {
              results.append(answer)
              previous = answer
            } else {
              isInitialized = true
              previous = nil
            }
            guard let request = next(previous) else {
              return Output(results: results, updates: updates)
            }
            let (_, msg) = calls.make(request.method, request.params, for: request.method)
            try process.send(msg)
          case .failure(let id, _, let message):
            guard let method = calls.take(id) else { continue }
            guard tolerating.contains(method) else { throw Failure(message: message) }
            results.append(.null)
            guard let request = next(.null) else {
              return Output(results: results, updates: updates)
            }
            let (_, msg) = calls.make(request.method, request.params, for: request.method)
            try process.send(msg)
          }
        }
      }
      throw Failure(message: String(localized: "The agent ended before it answered."))
    } onCancel: {
      process.terminate()
    }
  }
}

/// An Antigravity session's history, read via `session/load`, which replays the conversation
/// as `session/update` notifications before responding.
enum AgyHistory {
  static func events(sessionID: String, cwd: String, configuration: AgentProcess.Configuration)
    async throws -> [AgentEvent]
  {
    let output = try await AgyOneShot(configuration: configuration).run { previous in
      if previous == nil {
        return (
          "session/load",
          .object([
            "sessionId": .string(sessionID),
            "cwd": .string(cwd),
            "mcpServers": .array([]),
          ])
        )
      }
      return nil
    }
    return AgyTranslator.history(output.updates)
  }
}

/// Reads Antigravity's available models and slash commands for a folder from a short-lived
/// `agy acp` (`session/new` followed immediately by `session/close`).
enum AgyProbe {
  struct Snapshot {
    var models: [ModelOption]
    var commands: [SkillEntry]?
  }

  static func read(folder: URL, configuration: AgentProcess.Configuration) async throws -> Snapshot
  {
    var openedID: String?
    let output = try await AgyOneShot(configuration: configuration).run(
      tolerating: ["session/close"]
    ) { previous in
      if openedID == nil {
        if let sid = previous?["sessionId"]?.stringValue {
          openedID = sid
          return ("session/close", .object(["sessionId": .string(sid)]))
        }
        return (
          "session/new",
          .object([
            "cwd": .string(ProjectPath.normalize(folder)),
            "mcpServers": .array([]),
          ])
        )
      }
      return nil
    }
    let models = output.results.first.map { AgyModels.snapshot(from: $0).models } ?? []
    let commands = output.updates.reversed().compactMap { AgyInput.commands(from: $0) }.first
    return Snapshot(models: models, commands: commands)
  }
}
