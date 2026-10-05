import DrakarKit
import Testing

@Suite("A model's name, as the footer writes it")
struct ModelNameTests {

  @Test(arguments: [
    ("claude-opus-5[1m]", "Opus 5 · 1M"),
    ("claude-opus-5-5", "Opus 5.5"),
    ("claude-sonnet-4-5-20250929", "Sonnet 4.5"),
    ("claude-haiku-4-5-20251001", "Haiku 4.5"),
    ("claude-fable-5-1[1m]", "Fable 5.1 · 1M"),
    ("claude-3-5-sonnet-20241022", "Sonnet 3.5"),
    ("claude-opus-4-20250514", "Opus 4"),
  ])
  func names(_ id: String, _ name: String) {
    #expect(ModelName.display(id) == name)
  }

  /// Not a Claude id: shown as it is rather than guessed at.
  @Test func leavesOtherIDsAlone() {
    #expect(ModelName.display("gpt-5") == "gpt-5")
    #expect(ModelName.display("claude-") == "claude-")
  }

  /// The process's own report wins; history has only the newest message's id, which never
  /// carries `[1m]`, so the session's attachment says the window when it is the same model.
  @Test func picksTheSessionsModel() {
    #expect(
      ModelName.current(
        initModel: "claude-opus-5[1m]", messageModel: "claude-sonnet-4-5",
        attachmentModel: nil) == "claude-opus-5[1m]")
    #expect(
      ModelName.current(
        initModel: nil, messageModel: "claude-opus-5", attachmentModel: "claude-opus-5[1m]")
        == "claude-opus-5[1m]")
    // Switched model since the attachment was written: the message is newer.
    #expect(
      ModelName.current(
        initModel: nil, messageModel: "claude-sonnet-4-5", attachmentModel: "claude-opus-5[1m]")
        == "claude-sonnet-4-5")
    #expect(
      ModelName.current(initModel: nil, messageModel: nil, attachmentModel: "claude-opus-5")
        == "claude-opus-5")
    #expect(
      ModelName.current(
        initModel: nil, messageModel: TranscriptTail.syntheticModel, attachmentModel: nil) == nil)
    #expect(ModelName.current(initModel: nil, messageModel: nil, attachmentModel: nil) == nil)
  }
}
