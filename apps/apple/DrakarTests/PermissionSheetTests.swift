import DrakarKit
import Testing

@testable import Drakar

/// What the permission sheet's buttons say.
@Suite("Permission sheet")
struct PermissionSheetTests {
  private func title(toolName: String) throws -> String {
    let suggestion = try #require(PermissionSuggestion(CodexPolicy.acceptForSession, id: 0))
    let request = PermissionRequest(
      toolName: toolName, input: .object([:]), description: nil, toolUseID: nil, kind: .other)
    return PermissionSheet.title(suggestion, for: request)
  }

  @Test func aCodexFileChangeNamesTheFilesItAllows() throws {
    #expect(try title(toolName: "Edit") == "Allow, and don't ask again for these files")
  }

  @Test func aCodexCommandNamesTheCommandItAllows() throws {
    #expect(try title(toolName: "Shell") == "Allow, and don't ask again for this command")
  }
}
