import AppKit
import DrakarKit
import Observation
import SupportKitTestHost
import SwiftUI
import Testing

@testable import Drakar

@Observable
private final class DynamicUsageModel {
  var name = "Work"
  var usage: AccountUsage?
}

@MainActor
@Suite("Toolbar account and usage items")
struct AccountToolbarItemTests {

  private func makeToolbarWindow<T: ToolbarContent>(
    width: CGFloat = 960,
    @ToolbarContentBuilder toolbar: () -> T
  ) -> NSWindow {
    let root = Text("Host")
      .frame(width: width, height: 320)
      .toolbar(content: toolbar)
    let controller = NSHostingController(rootView: root)
    let window = HostedWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 320),
      styleMask: [.titled, .resizable])
    window.toolbarStyle = .unified
    window.contentViewController = controller
    window.layoutIfNeeded()
    return window
  }

  @Test func compactUsageMetersNeverCropWhenUsageArrivesAfterLayout() async throws {
    let model = DynamicUsageModel()
    let window = makeToolbarWindow {
      ToolbarItem(placement: .primaryAction) {
        Button {
        } label: {
          TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 6) {
              AgentIcon(agent: .agy)
              Text(model.name)
              UsageMeters(usage: model.usage, now: context.date, compact: true)
            }
            .fixedSize()
          }
          .fixedSize()
        }
      }
      ToolbarItem(placement: .primaryAction) {
        Button("Terminal", systemImage: "terminal") {}
      }
      ToolbarItem(placement: .primaryAction) {
        Button("Inspector", systemImage: "sidebar.right") {}
      }
    }
    defer { window.contentViewController = nil }

    try await Task.sleep(for: .milliseconds(50))
    window.layoutIfNeeded()

    let initialView = try #require(window.toolbar?.items.first?.view)
    let initialWidth = initialView.frame.width
    #expect(initialWidth >= initialView.fittingSize.width)

    model.name = AgentKind.agy.name
    model.usage = AccountUsage(
      fiveHour: UsageWindow(percent: 75, resetsAt: .now.addingTimeInterval(3600)),
      sevenDay: UsageWindow(percent: 64, resetsAt: .now.addingTimeInterval(86400 * 3)),
      readAt: .now,
      source: .probe)

    try await Task.sleep(for: .milliseconds(50))
    window.layoutIfNeeded()

    let updatedView = try #require(window.toolbar?.items.first?.view)
    #expect(updatedView.fittingSize.width > initialWidth)
    #expect(updatedView.frame.width >= updatedView.fittingSize.width)
  }

  @Test func accountAndRunnerToolbarItemsFitInsideToolbar() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appending(path: "drakar-acct-tb-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let window = makeToolbarWindow {
      ToolbarItem(placement: .primaryAction) {
        AccountToolbarItem(folder: folder)
      }
      ToolbarItem(placement: .primaryAction) {
        RunnerToolbarItem(name: "eva-mini", session: nil)
      }
    }
    defer { window.contentViewController = nil }

    try await Task.sleep(for: .milliseconds(50))
    window.layoutIfNeeded()

    let items = try #require(window.toolbar?.items)
    #expect(items.count == 2)
    for item in items {
      let view = try #require(item.view)
      #expect(view.frame.width >= view.fittingSize.width)
    }
  }
}
