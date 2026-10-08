import DrakarKit
import Foundation

/// A `codex app-server` started for one exchange and closed: a session's history, Codex's
/// model list. `initialize` and `initialized`, then each request `next` builds from the
/// previous answer, until it returns nil. Ended after 30 seconds whatever it is doing.
struct CodexOneShot {
  let configuration: AgentProcess.Configuration

  struct Failure: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
  }

  func run(_ next: (JSONValue?) -> (method: String, params: JSONValue)?) async throws
    -> [JSONValue]
  {
    let process = AgentProcess(configuration)
    let events = try process.start()
    let deadline = Task {
      try? await Task.sleep(for: .seconds(30))
      process.terminate()
    }
    defer {
      deadline.cancel()
      process.closeInput()
      process.terminate()
    }
    var calls = CodexRPC.Calls<Int>()
    try process.send(
      calls.make(
        "initialize", CodexSession.initializeParams(version: CodexLaunch.appVersion), for: 0))
    var results: [JSONValue] = []
    var isInitialized = false
    for await event in events {
      guard case .lines(let lines) = event else { continue }
      for line in lines {
        guard case .json(let json) = line, let rpc = CodexRPC.Line(json) else { continue }
        switch rpc {
        case .response(let id, let result):
          guard calls.take(id) != nil else { continue }
          let previous: JSONValue?
          if isInitialized {
            results.append(result)
            previous = result
          } else {
            isInitialized = true
            try process.send(CodexRPC.notification("initialized"))
            previous = nil
          }
          guard let request = next(previous) else { return results }
          try process.send(calls.make(request.method, request.params, for: 0))
        case .failure(let id, let message):
          guard calls.take(id) != nil else { continue }
          throw Failure(message: message)
        case .notification, .request:
          continue
        }
      }
    }
    throw Failure(message: String(localized: "Codex ended before it answered."))
  }
}

/// A Codex session's history, from its thread's stored items (`thread/items/list`, which
/// needs no resume and takes no lock: verified 2026-10-06).
enum CodexHistory {
  static func events(threadID: String, configuration: AgentProcess.Configuration) async throws
    -> [AgentEvent]
  {
    let pages = try await CodexOneShot(configuration: configuration).run { previous in
      var params: [String: JSONValue] = ["threadId": .string(threadID), "limit": .number(200)]
      if let previous {
        guard let cursor = previous["nextCursor"]?.stringValue else { return nil }
        params["cursor"] = .string(cursor)
      }
      return ("thread/items/list", .object(params))
    }
    return CodexTranslator.history(pages.flatMap { $0["data"]?.arrayValue ?? [] })
  }
}
