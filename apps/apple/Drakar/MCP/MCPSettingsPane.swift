import AppKit
import MCPKitLoopback
import MCPKitUI
import SwiftUI

/// Settings › MCP Server: whether an AI agent on this Mac may see Drakar's sessions, steer
/// them and answer their permission prompts. Cadence's pane, without its Pro gate, import
/// folders and recording: the licence never stops the server here, sending work is refused
/// at the call instead. Its sentences about loopback and about what each switch hands over
/// are the only place somebody learns what turning it on means.
struct MCPSettingsPane: View {
  @AppStorage(MCPSettingsKey.enabled) private var isEnabled = false
  @AppStorage(MCPSettingsKey.allowsWrites) private var allowsWrites = false
  @AppStorage(MCPSettingsKey.allowsPermissions) private var allowsPermissions = false
  @AppStorage(MCPSettingsKey.port) private var port = MCPServerController.defaultPort

  @State private var portDraft: Int?
  @State private var snippet: ClientSnippet = .claudeCode
  /// The token as last read, for showing. Read when the connection appears and after
  /// Regenerate, never on every draw: reading it writes the controller's `tokenError`, which
  /// would draw the pane again. Copy and Bastion read it afresh.
  @State private var token = ""
  @State private var tokenRevealed = false
  @State private var copied = false

  private var mcp: MCPServerController { .shared }

  private var isRunning: Bool {
    if case .running = mcp.state { return true }
    return false
  }

  private static let mask = String(repeating: "•", count: 24)

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $isEnabled) {
          Text("Run the MCP server")
          Text(
            "Lets an AI agent on this Mac, such as Claude Code or Codex, see your Drakar sessions, here and on your runner, and read their transcripts. It listens on 127.0.0.1 only: nothing is reachable from another machine."
          )
        }
        if isEnabled {
          MCPStatusLabel(
            status: MCPStatus(
              isAvailable: true, isEnabled: true, state: mcp.state, activity: mcp.activity,
              now: .now),
            activity: mcp.activity)
        }
        if let tokenError = mcp.tokenError {
          Text(tokenError)
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      } header: {
        Text("Server")
      } footer: {
        Text("The server runs while Drakar is open.")
      }

      if isEnabled {
        Section {
          Toggle(isOn: $allowsWrites) {
            Text("Allow writes")
            Text(
              "Off, an agent can only read. On, it can also start sessions, send them messages, interrupt and end them, and answer their questions."
            )
          }
          // Its own switch, not part of Allow writes: that one lets an agent do what the
          // composer does, this one what the permission panel does, which is the session's
          // reach into this Mac.
          Toggle(isOn: $allowsPermissions) {
            Text("Let agents answer permission prompts")
            Text(
              "Lets an agent allow or deny the tool calls your sessions ask permission for. A rule it allows lasts only for that session; it never edits your permission settings or changes a session's mode."
            )
          }
          .disabled(!allowsWrites)
        } header: {
          Text("Access")
        }

        Section {
          LabeledContent("Port") {
            // Typed into a draft, which reaches the preference only when it is a port the
            // server can take; anything else, or nothing, puts the last good one back.
            TextField("Port", value: $portDraft, format: .number.grouping(.never))
              .labelsHidden()
              .frame(width: 90)
              // Moving a live listener would leave clients pointed at a port nobody serves.
              .disabled(isRunning)
              .onAppear { portDraft = port }
              .onChange(of: port) { _, stored in portDraft = stored }
              .onChange(of: portDraft) { _, typed in
                switch MCPServerController.draft(typed, stored: port) {
                case .write(let typed): port = typed
                case .keep: break
                case .revert: portDraft = port
                }
              }
          }
        } header: {
          Text("Endpoint")
        } footer: {
          Text(
            isRunning
              ? "Turn the server off to change the port. Every client set up already names "
                + "the current one."
              : "Drakar listens on 127.0.0.1 on this port, from 1024 to 65535."
          )
          .fixedSize(horizontal: false, vertical: true)
        }

        if case .running(let boundPort) = mcp.state {
          connection(port: boundPort)
        }
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder private func connection(port: Int) -> some View {
    Section {
      LabeledContent("Token") {
        HStack(spacing: 8) {
          Text(tokenRevealed ? token : Self.mask)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
          Button(tokenRevealed ? "Hide" : "Show") { tokenRevealed.toggle() }
            .buttonStyle(.borderless)
          Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(mcp.token, forType: .string)
          }
          .buttonStyle(.borderless)
          Button("Regenerate") {
            mcp.regenerateToken()
            token = mcp.token
          }
          .buttonStyle(.borderless)
        }
      }
      .onAppear { token = mcp.token }
      // The kit's row: Add to Bastion where it is installed, what Bastion is where it is not.
      BastionRow { MCPSetup.bastionLink(port: port, token: mcp.token) }
      Text(
        "From another Mac: `ssh -L \(String(port)):127.0.0.1:\(String(port)) <this Mac>`, then use http://127.0.0.1:\(String(port))/mcp there."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
    } header: {
      Text("Connection")
    } footer: {
      Text(
        "Regenerating stops any agent still using the old token, and Bastion too until Drakar is added to it again."
      )
      .fixedSize(horizontal: false, vertical: true)
    }

    Section {
      Picker("Set up in", selection: $snippet) {
        ForEach(ClientSnippet.setupOrder, id: \.self) { Text($0.setupName).tag($0) }
      }
      // Masked while the token above is, and copied whole either way.
      let shown = snippet.text(
        serverName: MCPSetup.serverName, port: port, token: tokenRevealed ? token : Self.mask)
      // Scrolled rather than wrapped: a wrapped shell command reads as two commands.
      ScrollView(.horizontal) {
        Text(shown)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
      }
      .frame(maxHeight: 120)
      HStack {
        Text(snippet.setupHint)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(copied ? "Copied" : "Copy") {
          snippet.copy(serverName: MCPSetup.serverName, port: port, token: mcp.token)
          copied = true
        }
        .task(id: copied) {
          guard copied else { return }
          try? await Task.sleep(for: .seconds(2))
          copied = false
        }
      }
    } header: {
      Text("Client configuration")
    } footer: {
      Text(
        "Copy takes the real token, masked here or not. It goes into a config file on this Mac. Claude Desktop only starts servers it launches itself, so it cannot reach this one."
      )
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}
