# Being Claude Code's editor

Findings from a spike run on 2026-10-03 against Claude Code 2.1.288 and the VS Code
extension 2.1.288: a throwaway Python server posing as an IDE, driven by a real
interactive `claude` in a pseudo-terminal. The server side was read out of the extension's
`extension.js`; everything below about the CLI's behaviour was observed, not inferred.
The requests are kept as the `ide-requests` fixture in DrakarKit's tests.

## Verdict

- **Any app can be the editor of a terminal `claude`.** A lock file and a loopback
  WebSocket speaking MCP are the whole contract. The CLI calls `openDiff` for every edit
  and applies it or not on the answer.
- **Only interactive sessions connect.** A headless `claude -p` (stream-json or not)
  never connected, with `--ide` and with `CLAUDE_CODE_SSE_PORT`. Drakar's own sessions
  keep their permission sheet; the bridge is for `claude` run in a terminal.
- **The editor's selection reaches it.** Sent as `selection_changed`, it shows in the
  CLI's prompt ("⧉ 3 lines selected") and goes with the next message ("⧉ Selected 3 lines
  from src/main.swift in Drakar"); asked to quote it, the model did (2026-10-03).
- **Undocumented, like the rest.** It is what the VS Code and JetBrains integrations use,
  so it is stable in practice, but the shapes below are observed, not promised.

## The lock file

`$CLAUDE_CONFIG_DIR/ide/<port>.lock`, or `~/.claude/ide/<port>.lock` without the variable
(the extension's `WW()`), directory mode 0700, file mode 0600:

```json
{"pid": 4242, "workspaceFolders": ["/Users/me/project"], "ideName": "Drakar",
 "transport": "ws", "runningInWindows": false, "authToken": "<random uuid>"}
```

- `pid` is the editor's process. `ideName` is what `/ide` lists.
- A `claude` offers an IDE whose `workspaceFolders` contain its working directory. The
  others are listed under "Found N other running IDE(s). However, their workspace or
  project directories don't match the current directory."
- **`claude --ide` auto-connects only when exactly one IDE matches.** With two matching
  lock files (a stale one included) it silently connects to neither; `/ide` still lets
  the user pick. So an editor must remove its lock file on exit and sweep stale ones it
  left after a crash: in the spike, killing the server with SIGTERM left its lock behind.
- A `claude` started in VS Code's integrated terminal finds its editor through
  `CLAUDE_CODE_SSE_PORT`, which the extension exports. Nothing else needs it.

## The connection

`GET /` on `127.0.0.1:<port>`, a WebSocket upgrade with:

- `x-claude-code-ide-authorization: <authToken>`; the extension closes the socket with
  1008 on a mismatch;
- `Sec-WebSocket-Protocol: mcp`;
- `Sec-WebSocket-Extensions: permessage-deflate` offered, not required (the spike
  declined it and nothing changed);
- `User-Agent: claude-code/2.1.288 (claude-vscode, agent-sdk/0.3.288)`.

The extension serves one client at a time and drops the previous one. Nothing in the CLI
requires that; Drakar serves several.

## The session, in order

1. `initialize` (MCP `protocolVersion` 2025-11-25, client `claude-code`), answered with
   the same version and `capabilities.tools`.
2. `notifications/initialized`, then **`ide_connected`** with `{"pid": <claude's pid>}`.
3. `tools/list`. The CLI exposes the tools to the model as `mcp__ide__*`.
4. On every edit: `closeAllDiffTabs`, then **`openDiff`**:

   ```json
   {"old_file_path": "/p/notes.md", "new_file_path": "/p/notes.md",
    "new_file_contents": "alpha\nBETA\ngamma\n",
    "tab_name": "✻ [Claude Code] notes.md (492709) ⧉"}
   ```

   The call **blocks until the user decides**. The answer is two text blocks:
   `FILE_SAVED` and the contents to write (the extension returns what the user saved,
   edits included), or `DIFF_REJECTED` and the tab name. The CLI writes the file itself on
   `FILE_SAVED`; on `DIFF_REJECTED` the file was left untouched (both verified). It writes
   the contents it is **sent back**, not the ones it proposed: a spike editor that appended
   a line to its `FILE_SAVED` answer got that line in the file (2.1.288). That is what
   lets the user edit a proposal before accepting it.
5. Then `close_tab` with the tab name (twice), answered `TAB_CLOSED`, and
   `getDiagnostics` for the file and for everything, answered with a JSON array.

The terminal shows its own permission prompt while the diff is open. If the user answers
there, the CLI sends `close_tab`; the extension resolves the pending `openDiff` as
`DIFF_REJECTED` when its tab closes, and Drakar does the same.

## The selection

The editor sends it unasked, as a notification, to every connected `claude`:

```json
{"jsonrpc": "2.0", "method": "selection_changed",
 "params": {"text": "func greet…}", "filePath": "/p/src/main.swift",
            "fileUrl": "file:///p/src/main.swift",
            "selection": {"start": {"line": 2, "character": 0},
                          "end": {"line": 4, "character": 1}, "isEmpty": false}}}
```

- Lines and characters count from 0, characters in UTF-16 code units, as VS Code counts
  them. An empty selection is the caret, and still names the file: the CLI then shows
  "In main.swift" (the extension's `attachOpenFile`, on by default).
- The extension debounces it 300 ms, sends it only when it changed, and sends the latest
  one 500 ms after a client connects. Drakar does the same.
- `at_mentioned` (`{filePath, lineStart?, lineEnd?}`, lines from 0, only with a
  selection) is the extension's ⌘⌥K: it asks the CLI to put a reference into the prompt
  being written. Drakar sends it from the same shortcut. Its ⌥K is the chat's own
  `@src/main.swift#L3-5`, which Drakar puts into its composer.

## The other tools

Read out of the extension's handlers (`extension.js` 2.1.288). Every result is MCP
`content` holding one text block, JSON unless noted; a handler that throws comes back
with `isError: true`.

| Tool | Answer |
| --- | --- |
| `openFile` (`filePath`, `preview`, `startText`, `endText`, `selectToEndOfLine`, `makeFrontmost`) | A sentence: "Opened file: <path>", or which text it selected. With `makeFrontmost: false` and no `startText`, JSON: `success`, `filePath`, `fileUrl`, `lineCount`, `isDirty`… A relative path is relative to the first workspace folder; a missing file throws "File not found: <path>". |
| `getCurrentSelection` | The `selection_changed` params plus `success: true`, or `{"success": false, "message": "No active editor found"}`. |
| `getLatestSelection` | The last params sent, or `{"success": false, "message": "No selection available"}`. |
| `getOpenEditors` | `{"tabs": [{uri, isActive, isPinned, isPreview, isDirty, label, groupIndex, viewColumn, isGroupActive, fileName, languageId, lineCount, isUntitled, selection?}]}`; only the active tab carries its selection. |
| `checkDocumentDirty` | `{success, filePath, isDirty, isUntitled}`, or "Document not open: <path>". |
| `saveDocument` | `{success, filePath, saved, message}`. |
| `getWorkspaceFolders` | `{"success": true, "folders": [{name, uri, path, index}], "rootPath", "workspaceFile"}`. |

Drakar answers all of them from its open windows, and leaves out the Jupyter
`executeCode`. `getDiagnostics` answers an empty list: Drakar has no language service.

## Re-checking it

Worth doing on a new Claude Code minor, since none of this is a promised interface. The
spike's throwaway scripts were not kept; Drakar itself is now the editor to test against.

1. Pick a folder **outside every VS Code workspace** (a temporary directory). A folder
   two editors claim gives `claude --ide` two matches, and it then connects to neither.
2. Open a Drakar session there. A window counts as soon as it shows a session, prompt or
   not: `make run ARGS='-drakar.debugFolder <dir> -drakar.debugModel
   claude-haiku-4-5-20251001 -drakar.debugSettingSources project'`.
3. `make audit-running`: loopback only, lock files 0600, the upgrade refused without the
   token (400 on 2026-10-03) and accepted with it.
4. The editor tools need no `claude` at all: any WebSocket client holding the lock's
   token can call them, which is the quickest check of their shapes. `openFile` with a
   `startText` also moves the selection, so the notification follows.
5. Run an **interactive** `claude --ide --setting-sources project` in that folder. From
   an agent there is no terminal, so give it one: Python's `pty.fork()`, then about six
   seconds later a `\r` to accept the folder-trust prompt, then the prompt text and its
   own `\r`. Ask for an edit; the Review Changes window shows it (`review.accept`,
   `review.reject` through accessibility), and the file changes only after Accept.
6. If it does not connect, type `/ide` in the session: it lists the editors it can use
   and, for every other lock file, why not ("their workspace or project directories don't
   match the current directory").
7. Leave no lock behind: quit Drakar normally, and check `grep -l '"ideName":"Drakar"'
   ~/.claude/ide/*.lock` comes back empty. A process killed without cleanup leaves its
   lock until the next Drakar launch sweeps it.
