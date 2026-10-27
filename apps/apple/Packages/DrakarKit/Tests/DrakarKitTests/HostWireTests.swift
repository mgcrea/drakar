import Foundation
import Testing

@testable import DrakarKit

@Suite struct HostWireTests {
  private let configuration = AgentProcess.Configuration(
    executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: ["-a"], environment: ["K": "V"],
    currentDirectory: URL(fileURLWithPath: "/tmp"))
  private let bytes = Data([0, 10, 0xFF])

  @Test func requestsAndEventsRoundTrip() throws {
    let requests: [HostRequest] = [
      .hello(protocol: 1, appVersion: "2.0"), .list, .spawn(configuration, meta: bytes),
      .attach(id: "a", from: 42), .write(id: "a", bytes: bytes),
      .write(id: "a", bytes: bytes, logged: Data("x".utf8)), .note(id: "a", bytes: bytes),
      .closeInput(id: "a"), .terminate(id: "a"), .terminate(id: "a", forget: true),
      .setMeta(id: "a", meta: bytes),
      .acknowledge(id: "a"),
      .detach(id: "a"),
    ]
    for request in requests {
      let data = try JSONEncoder().encode(request)
      #expect(try JSONDecoder().decode(HostRequest.self, from: data) == request)
    }
    let record = HostRecord(
      offset: 7, kind: .in, time: Date(timeIntervalSince1970: 1_000), attached: true, bytes: bytes)
    let held = HeldProcess(
      id: "a", meta: bytes, running: false, exitStatus: 3, logLength: 9, attachedApp: 123)
    let events: [HostEvent] = [
      .welcome(protocol: 1, hostVersion: "1.0", pid: 5),
      .welcome(protocol: 1, hostVersion: "1.0", pid: 5, minor: 3), .listed([held]), .listed([]),
      .spawned(id: "a"), .record(id: "a", record), .caughtUp(id: "a", offset: 99),
      .stderr(id: "a", text: "oops"), .exited(id: "a", status: -1), .released(id: "a"),
      .refused(reason: "busy"),
    ]
    for event in events {
      let data = try JSONEncoder().encode(event)
      #expect(try JSONDecoder().decode(HostEvent.self, from: data) == event)
    }
  }

  /// An older app's `terminate` has no `forget`, and a plain one is sent as it would send it.
  @Test func aTerminateWithoutForgetIsAnOlderAppsTerminate() throws {
    let older = Data(#"{"terminate":{"id":"a"}}"#.utf8)
    #expect(try JSONDecoder().decode(HostRequest.self, from: older) == .terminate(id: "a"))
    #expect(try JSONEncoder().encode(HostRequest.terminate(id: "a")) == older)
  }

  /// An older app's `write` has no `logged`, and a plain one is sent as it would send it.
  @Test func aWriteWithoutLoggedIsAnOlderAppsWrite() throws {
    let older = Data(#"{"write":{"bytes":"YQo=","id":"a"}}"#.utf8)
    let write = HostRequest.write(id: "a", bytes: Data("a\n".utf8))
    #expect(try JSONDecoder().decode(HostRequest.self, from: older) == write)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(try encoder.encode(write) == older)
  }

  /// An older host's `welcome` has no `minor`: it is minor 2 or lower.
  @Test func aWelcomeWithoutMinorIsAnOlderHosts() throws {
    let older = Data(#"{"welcome":{"hostVersion":"1.0","pid":5,"protocol":1}}"#.utf8)
    #expect(
      try JSONDecoder().decode(HostEvent.self, from: older)
        == .welcome(protocol: 1, hostVersion: "1.0", pid: 5))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let welcome = HostEvent.welcome(protocol: 1, hostVersion: "1.0", pid: 5, minor: 3)
    #expect(
      String(decoding: try encoder.encode(welcome), as: UTF8.self)
        == #"{"welcome":{"hostVersion":"1.0","minor":3,"pid":5,"protocol":1}}"#)
  }

  @Test func socketPathIsUnderTheBundlesFolder() throws {
    let home = URL(fileURLWithPath: "/Users/me")
    let directory = HostWire.directory(bundleID: "io.mgcrea.Drakar", home: home)
    #expect(
      try HostWire.socket(in: directory).path
        == "/Users/me/Library/Application Support/io.mgcrea.Drakar/host/host-v1.sock")
  }

  @Test func aPathTooLongThrows() {
    let directory = URL(fileURLWithPath: "/" + String(repeating: "a", count: 119))
    #expect(throws: HostWire.PathTooLong.self) { try HostWire.socket(in: directory) }
  }
}
