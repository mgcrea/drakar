import Foundation

/// A skill sent to many sessions, at most `limit` at a time
/// (docs/superpowers/specs/2026-10-12-skill-fanout-design.md §4). Pure: the caller sends the
/// prompts this returns and says when a session is done with its turn.
public struct FanOut<ID: Hashable & Sendable>: Sendable {
  public enum State: Sendable, Equatable, Codable { case waiting, running, finished, cancelled }

  /// In the order they start.
  public let ids: [ID]
  /// How many run at once; nil for all.
  public let limit: Int?
  private var states: [ID: State]

  public init(ids: [ID], limit: Int?) {
    self.ids = ids
    self.limit = limit.flatMap { $0 > 0 ? $0 : nil }
    states = Dictionary(ids.map { ($0, State.waiting) }, uniquingKeysWith: { first, _ in first })
  }

  /// A batch as it stood: `states` for the ids it knows, waiting for the rest.
  public init(ids: [ID], limit: Int?, states: [ID: State]) {
    self.init(ids: ids, limit: limit)
    for id in ids { self.states[id] = states[id] ?? .waiting }
  }

  public func state(of id: ID) -> State? { states[id] }

  public func count(_ state: State) -> Int { states.values.count { $0 == state } }

  /// Nothing waits or runs.
  public var isDone: Bool { count(.waiting) == 0 && count(.running) == 0 }

  /// "4 running · 8 waiting · 3 done", the counts that are not zero.
  public var summary: String {
    [
      (count(.running), String(localized: "running")),
      (count(.waiting), String(localized: "waiting")),
      (count(.finished), String(localized: "done")),
    ]
    .filter { $0.0 > 0 }
    .map { "\($0.0) \($0.1)" }
    .joined(separator: " · ")
  }

  /// The ones to send now: all, or the first `limit`.
  public mutating func start() -> [ID] { next() }

  /// `id` is done with its turn, or stopped. Returns the one to send in its place, if it held
  /// a slot and one waits. Again for the same id, or for an unknown one, nothing.
  public mutating func finished(_ id: ID) -> [ID] {
    guard let state = states[id], state == .running || state == .waiting else { return [] }
    states[id] = .finished
    return state == .running ? next() : []
  }

  /// The waiting ones, which will not be sent now. The running ones go on.
  public mutating func cancel() -> [ID] {
    let waiting = ids.filter { states[$0] == .waiting }
    for id in waiting { states[id] = .cancelled }
    return waiting
  }

  private mutating func next() -> [ID] {
    let free = limit.map { max(0, $0 - count(.running)) } ?? ids.count
    let starting = Array(ids.filter { states[$0] == .waiting }.prefix(free))
    for id in starting { states[id] = .running }
    return starting
  }
}
