import Foundation

/// One item of a `TodoWrite` list.
public struct Todo: Sendable, Equatable {
  public enum Status: String, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
  }

  public var content: String
  /// How the item reads while it is being done: "Checking b.txt" for "check b.txt".
  public var activeForm: String?
  public var status: Status

  public init(content: String, activeForm: String?, status: Status) {
    self.content = content
    self.activeForm = activeForm
    self.status = status
  }
}

/// `TodoWrite`: every call carries the whole list, so the newest one is the session's.
public enum TodoList {
  public static let toolName = "TodoWrite"

  /// The items of a call's input; one without content or a known status is left out.
  public static func todos(_ input: JSONValue) -> [Todo] {
    (input["todos"]?.arrayValue ?? []).compactMap { item in
      guard let content = item["content"]?.stringValue,
        let status = item["status"]?.stringValue.flatMap(Todo.Status.init)
      else { return nil }
      return Todo(content: content, activeForm: item["activeForm"]?.stringValue, status: status)
    }
  }

  /// The item being done now.
  public static func current(_ todos: [Todo]) -> Todo? {
    todos.first { $0.status == .inProgress }
  }

  /// "1/2": done of all.
  public static func progress(_ todos: [Todo]) -> String {
    "\(todos.count { $0.status == .completed })/\(todos.count)"
  }
}
