import DrakarKit
import Foundation
import Testing

@Suite("Grok CLI model list")
struct GrokModelsTests {
  @Test func parsesAvailableModelsOutput() {
    let output = """
      You are logged in with grok.com.

      Default model: grok-4.7

      Available models:
        * grok-4.7 (default)
        - grok-4.7-build-fast
        - grok-4.6
        - grok-4.5
      """
    let models = GrokModels.list(fromOutput: output)
    #expect(
      models.map(\.value) == ["grok-4.7", "grok-4.7-build-fast", "grok-4.6", "grok-4.5"])
    #expect(models.first?.displayName == "grok-4.7")
    #expect(models.first?.resolvedModel == "grok-4.7")
  }

  @Test func ignoresOutputWithoutAvailableModelsSection() {
    #expect(GrokModels.list(fromOutput: "Not logged in.\n").isEmpty)
    #expect(GrokModels.list(fromOutput: "").isEmpty)
  }
}
