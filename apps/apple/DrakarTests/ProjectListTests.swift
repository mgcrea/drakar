import DrakarKit
import Foundation
import Testing

@testable import Drakar

@MainActor
@Suite("The tracked projects, app-wide")
struct ProjectListTests {

  private let defaults: UserDefaults

  init() throws {
    let suite = "drakar-project-list-\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
  }

  @Test func aTrackedFolderSurvivesARelaunch() {
    let list = ProjectList(defaults: defaults)
    list.track(URL(filePath: "/w/drakar/", directoryHint: .isDirectory))
    list.hide("/w/other")
    let relaunched = ProjectList(defaults: defaults)
    #expect(relaunched.tracked.paths == ["/w/drakar"])
    #expect(relaunched.tracked.hidden.keys.contains("/w/other"))
  }

  @Test func removingLeavesTheRestAlone() {
    let list = ProjectList(defaults: defaults)
    list.track(URL(filePath: "/w/a", directoryHint: .isDirectory))
    list.track(URL(filePath: "/w/b", directoryHint: .isDirectory))
    list.remove("/w/a")
    #expect(ProjectList(defaults: defaults).tracked.paths == ["/w/b"])
  }
}
