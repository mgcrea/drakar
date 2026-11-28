import DrakarKit
import SwiftUI

/// What a closed tool card shows of its result, as the extension shows it without anything
/// to open: a shell call's first lines (more of them for an error), a search's count, the
/// reason the user gave for refusing the call. Nil for the rest, whose result stays inside.
enum ToolResultPreview: Equatable {
  case output(ToolOutput.Preview, isError: Bool)
  case empty
  case summary(String)
  case refused(reason: String)

  static func of(_ call: Transcript.ToolCall, task: AgentTask?) -> ToolResultPreview? {
    guard let result = call.result else { return nil }
    if let refusal = ToolOutput.refusal(in: result) {
      return refusal.reason.map { .refused(reason: $0) }
    }
    // A backgrounded call's result only says where its output goes; its task's own
    // section reads that.
    if task?.isBackgrounded == true || TaskOutput.outputFile(inResult: result.content) != nil {
      return nil
    }
    switch call.kind {
    case .shell:
      return output(of: result)
    case .search:
      if result.isError { return output(of: result) }
      return .summary(
        ToolOutput.searchSummary(of: result.content, isFileList: call.name == "Glob"))
    default:
      return nil
    }
  }

  private static func output(of result: Transcript.ToolResult) -> ToolResultPreview {
    let lines = result.isError ? ToolOutput.errorPreviewLines : ToolOutput.previewLines
    guard let preview = ToolOutput.preview(of: result.content, lines: lines) else {
      return .empty
    }
    return .output(preview, isError: result.isError)
  }
}

/// A `ToolResultPreview` under its card's header. Clicking the output or the count opens
/// the card, where the whole result is.
struct ToolResultPreviewView: View {
  let preview: ToolResultPreview
  let callID: String
  let open: () -> Void

  var body: some View {
    switch preview {
    case .output(let output, let isError):
      Button(action: open) {
        VStack(alignment: .leading, spacing: 0) {
          // One line each, cut rather than wrapped, as a terminal shows them.
          ForEach(
            Array(
              output.text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()), id: \.offset
          ) { _, line in
            Text(verbatim: line.isEmpty ? " " : String(line))
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        .font(.callout.monospaced())
        .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .frame(maxWidth: .infinity, alignment: .leading)
        .mask {
          // More below: the last line fades out, as in the extension.
          LinearGradient(
            stops: [
              .init(color: .black, location: 0),
              .init(color: .black, location: output.isClipped ? 0.6 : 1),
              .init(color: output.isClipped ? .black.opacity(0.15) : .black, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Show the whole output")
      .accessibilityIdentifier("tool.\(callID).output")
    case .empty:
      Text("(no output)")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .accessibilityIdentifier("tool.\(callID).output")
    case .summary(let summary):
      Button(action: open) {
        Text(summary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Show the results")
      .accessibilityIdentifier("tool.\(callID).output")
    case .refused(let reason):
      Text("\(Text("Reason:").bold()) \(reason)")
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .accessibilityIdentifier("tool.\(callID).output")
    }
  }
}
