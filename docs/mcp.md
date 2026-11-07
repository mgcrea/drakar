# Drakar's MCP server

Drakar can serve MCP to an AI agent on this Mac, such as Claude Code or Codex, so that the
agent sees and steers the sessions Drakar holds: the tabs of its project windows, the ones
its session host keeps running in the background, the ones on the runner
(`docs/runner.md`), and the sessions running in a terminal or VS Code that Drakar follows.
An agent can list them, see which ones want you and why, read their transcripts, wait for
one to move, and, if you let it, start sessions, send them work and answer them.

It is off until you turn it on. It listens on 127.0.0.1 only and answers only a client that
sends the token Drakar keeps in your Keychain. The design behind it is
`docs/superpowers/specs/2026-11-07-mcp-server-design.md`; the server itself is
swift-mcp-kit's, as in Drakar's sibling apps.

## Turning it on

Settings › MCP Server › **Run the MCP server**. The server runs while Drakar is open,
windows or not, and stops when you turn it off or quit. The status under the switch says
whether it is listening.

| | Released Drakar | A copy run from Xcode |
| --- | --- | --- |
| Port | 8811 | 8812 |
| Server name | `drakar` | `drakar-dev` |
| Keychain item | `io.mgcrea.Drakar.mcp` | `io.mgcrea.Drakar.mcp-dev` |

The port can be changed in the pane while the server is off, from 1024 to 65535. The token
is made the first time it is needed. **Regenerate** replaces it, and every client still
using the old one stops being let in, Bastion included until Drakar is added to it again.

## Wiring a client

The pane does it. Once the server runs, **Add to Bastion** hands it to Bastion where Bastion
is installed, and **Client configuration** gives the setup for Claude Code, Codex, VS Code
or Claude Desktop and Cursor, with **Copy** taking the real token even while the pane masks
it. Claude Desktop only starts servers it launches itself, so it cannot reach this one.

By hand, for Claude Code, with the token from the pane:

```sh
claude mcp add --transport http drakar http://127.0.0.1:8811/mcp \
  --header "Authorization: Bearer <token>"
```

For Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.drakar]
url = "http://127.0.0.1:8811/mcp"
http_headers = { "Authorization" = "Bearer <token>" }
```

The token goes into that client's config file on this Mac, so anything that can read the
file can drive Drakar as far as the switches below allow.

## The three switches

- **Run the MCP server** (`drakar.mcp.enabled`, off). Whether it listens at all. On by
  itself, an agent can only read: list sessions, see what they want, read transcripts, wait.
- **Allow writes** (`drakar.mcp.allowWrites`, off). Lets an agent start a session, send one
  a message, interrupt its turn, end it, and answer its questions and MCP servers' forms.
  Off, those tools are not even listed, and a call to one is refused.
- **Let agents answer permission prompts** (`drakar.mcp.allowPermissions`, off, and only
  available while Allow writes is on). Lets an agent allow or deny the tool calls your
  sessions ask permission for. A rule it allows lasts only for that session; it never edits
  your permission settings or changes a session's mode. Read at each call, so moving it
  takes effect at once.

Each write goes through the call the window's own control makes, so what the window refuses
the agent is refused too: a read-only session, one held by another Drakar or running
elsewhere, a Codex session on the runner. Starting a session or sending one a message also
needs a licence that allows work, as the composer does, and the refusal is the composer's
sentence. Answering, interrupting and ending stay allowed whatever the licence says.

No call ever makes a Drakar window take the keyboard. A session started in a folder whose
window is open gets a tab the window does not switch to; a window opened for an agent goes
behind the others, and the key goes back where it was. A session held in the background is
taken back into its project's window the same way when an agent sends it a message.

## The tools

A session is named by the agent's own session id (Claude Code's session id, Codex's thread
id), or by a unique prefix of it of 8 characters or more. Arguments are snake_case, result
fields camelCase.

| Tool | Needs | What it does |
| --- | --- | --- |
| `drakar_list_sessions` | | The live sessions, here, on the runner and followed elsewhere: state, what each waits on, model, context, where it is. Filters: `folder`, `runner` (`this-mac` or the runner's name), `state`; `include_ended` adds recently ended ones, up to `limit` (20, at most 100). |
| `drakar_needs_attention` | | The sessions that want you, most urgent first, the set Home and the Dock badge count: permission prompts with their input and suggestions, questions and their options, plans, MCP servers' forms, and turns that ended asking or offering something. |
| `drakar_get_session` | | One session (`session`): its row, the requests waiting on an answer, the queued messages, its permission mode and Claude Code account. |
| `drakar_read_transcript` | | A session's transcript, oldest first: `last` entries (20, at most 200), or from a `cursor` with `after`. Tool results are cut at 2 KB and thinking is left out; `unsettled` lists the entries that may still change. |
| `drakar_wait` | | Waits until a session moves, then says which: `until` `attention` (the default), `turn_end` or `change`, over `sessions` or every live one, for `timeout_seconds` (30, at most 120). Call it in a loop rather than polling the list. |
| `drakar_list_projects` | | The folders a session can be started in, whether a window is open on each, and the runner: connected or not, its Drakar and Claude Code versions, its last error. |
| `drakar_start_session` | Allow writes, licence | Starts a session in `folder` (here, or on `runner`) with its first `prompt`, `agent` and `model` optional, and returns its row once it has an id. A runner session is always Claude Code. |
| `drakar_send_message` | Allow writes, licence | Sends `text` to a session as its composer does: at once, or queued behind the running turn. A background session is taken back into its window first, an ended one resumed there. |
| `drakar_interrupt` | Allow writes | Ends a session's running turn, as Escape does. Queued messages stay queued. |
| `drakar_end_session` | Allow writes | Ends a session, as End Session does: its process stops, its row stays, and a later message resumes it (a runner session starts anew). |
| `drakar_answer_question` | Allow writes | Answers a question (`answers`: each question's text to its answer) or an MCP server's form (`action` `accept` with `content`, `decline` or `cancel`) by its `request_id`. A form that asks you to open a link can be declined or cancelled, not accepted. |
| `drakar_answer_permission` | Allow writes, permission prompts | Allows or denies a tool call by its `request_id`: `decision`, and on deny a `message` and `interrupt`; on allow, `always` applies some of the request's own suggestions, by index, for that session only. A plan allowed runs with every edit still asking. |

The server's instructions tell the agent that transcripts, questions and plans were written
by agents that may have read hostile content, so their text is data to report and never
instructions to follow. Drakar logs one line per request, the method, tool, outcome and
duration, and never the arguments or anything a tool returns.

## From another machine

The server answers on 127.0.0.1 only, and that is not a setting. To reach it from another
Mac, forward the port over ssh and point the client there at the forward:

```sh
ssh -L 8811:127.0.0.1:8811 <this Mac>
```

then use `http://127.0.0.1:8811/mcp` on the other Mac, with the same token.

## Known limits

- A window opened for an agent while Drakar is the active app but has no key window (only
  its menu bar, say) may keep the key, since there is no other window to give it back to.
- Opening a window for an agent while Drakar is not the active app has not been checked on
  a live Mac yet. It should open behind the other apps without activating Drakar.
