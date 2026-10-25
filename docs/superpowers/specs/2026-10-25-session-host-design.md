# Sessions that outlive the app

## Why

Every `claude` and `codex app-server` a session runs is a child of Drakar, with its stdin and
stdout piped to the app (`AgentProcess`). Quitting Drakar, a crash, a Sparkle update and
every `make run` therefore end every running turn mid-way. The conversation survives (the
CLI writes its transcript as it goes and Drakar resumes it), but the turn in flight, its
pending permission prompt and a fan-out's waiting sessions do not.

The person runs dozens of sessions at once (26 working on 2026-10-24) out of the Debug build
they develop, so a relaunch is routine, and today it costs all of that work. The goal is
that a relaunch costs nothing: the app goes away, the sessions keep working, and when it
comes back every window shows them as if it had never left.

## Goals

- A session at work (mid-turn, or waiting for the person) keeps running across a quit, a
  crash, a Sparkle update and a rebuild and relaunch of Drakar.
- After the relaunch, each such session is back in its window, live: its transcript
  complete with nothing doubled or missing, its turn still streaming, a permission prompt
  that arrived while the app was gone shown and answerable, its pills and context gauge
  right.
- A fan-out's waiting sessions are still waiting, and are sent as the running ones finish.
- Claude Code and Codex alike: both are JSON lines over pipes.

## Non-goals

- Surviving a logout, a reboot or the host's own crash. Those end the processes, as today;
  the conversations are resumed as today.
- Notifying the person while the app is gone (a prompt that waits, a turn that ends). The
  host shows no UI.
- Hosting the short-lived processes: the capability probe, `CodexOneShot`, the skills
  lists. They stay the app's own children.
- Changing what the transcript, the backends or the session model do with a live process.
  The one addition is replaying a log (§3).

## Anti-goals

- A host that does anything but hold processes and their bytes. It must not parse the
  protocol, decide anything about sessions, or know Claude Code from Codex. Every rule
  stays in the app, where it is tested; the host is small enough that crashing it is
  unlikely, because when it crashes, everything it holds dies.
- A second way for sessions to behave when the host is absent. If the host cannot start,
  sessions run as children of the app, as today, and say so; there is no third mode.
- Anything another user, or a program not signed by us, can reach.

## Constraints

- Distributed with Developer ID and Sparkle, not sandboxed (no `.entitlements`): a helper
  binary in the bundle and a Unix socket are both open to it.
- A Sparkle update replaces the bundle while the old host runs from it. The running binary
  keeps working (its inode stays open), but the next app speaks to a host built from older
  code: the protocol is versioned and the app copes with an older host (§5).
- Tests run inside the app (`XCTestConfigurationFilePath`). They must never reach the real
  host, nor leave a host running.
- Several Claude sessions build and relaunch Debug Drakar from different worktrees, all
  under bundle id `io.mgcrea.Drakar` and team `75QE9PRT3V`, as the installed Release build
  is. They all share one host, which is the point: `make run` from a worktree reattaches to
  the sessions the main checkout's build started, and a Sparkle update to those the old
  version started. *(My call.)* Whichever build starts the host first runs its copy;
  hosts are interchangeable within a protocol major, which is what keeps that safe.
- Network rules (`IDEServer`, `scripts/audit-network.sh`): the IDE bridge stays the only
  `NWListener`. The host's socket is a Unix socket, not a network listener; the audit
  script learns to allow exactly that one and to check its permissions.

## §1 The host

`DrakarHost`, a command-line target built into `Drakar.app/Contents/Helpers/`.

- **Started on demand** by the app, the first time it needs to start a hosted process and
  finds no host listening. It is spawned detached (`posix_spawn` with `POSIX_SPAWN_SETSID`,
  stdio to `/dev/null`), so it is not the app's child and does not die with it. Not a
  launchd agent: that needs a Login Items approval and a background-item notification for
  something that only lives while sessions do.
- **One per user and bundle id**, found by its socket: `~/Library/Application
  Support/<bundle id>/host/host-v<major>.sock`, in a 0700 directory, the socket 0600. A
  second host that finds the socket answered exits at once (§5 covers a socket nobody
  answers).
- **Holds processes.** For each one: its `AgentProcess.Configuration` (executable,
  arguments, environment, working directory) as the app sent it, the process itself with
  its three pipes, an opaque `meta` blob the app writes and reads back (§3), a log of both
  directions, its stderr's tail, its exit status once it has one, and which app is
  attached, if any.
- **The log is both directions**, in the order the host saw them: each record is what the
  CLI wrote on stdout (`out`) or what the app wrote to its stdin (`in`), unparsed, with its
  offset in the log. Both, because the CLI never echoes what it was sent: a prompt, a
  permission answer, a Codex JSON-RPC call exist only on the app's side, and a replay
  without them loses prompts, shows answered permissions as pending again, and leaves Codex
  unable to match a response to its call.
- **The log is on disk**, one file per process beside the socket. On disk because a long
  session writes megabytes and dozens of them would not fit comfortably in memory; it also
  makes a replay a file read. It is deleted when the app acknowledges the process's end
  (§2).
- **Exits** when it holds no process, running or ended-but-unacknowledged, and no app has
  been connected for 30 seconds.
- **Stays dumb:** it frames, stores and forwards bytes. It never parses a line.

## §2 The protocol

Newline-delimited JSON over the Unix socket, one request or event per line; bytes from the
CLI travel base64-encoded so a line the CLI wrote is never split or re-encoded.

- `hello {protocol, appVersion}` → `{protocol, hostVersion, pid}`. A major mismatch ends the
  connection (§5).
- `list` → every process held: `id`, `meta`, `running`, `exitStatus`, `logLength`, and
  the pid of the app attached to it, if any.
- `spawn {configuration, meta}` → `{id}`; the host starts the process and begins logging.
- `attach {id, from}`: send the log from offset `from`, then stream new records, stderr and
  the exit as they come. Refused while another app is attached (§4).
- `write {id, bytes}`: written to the CLI's stdin and logged as `in`. `note {id, bytes}`:
  logged as `note` and written to nothing, the app's own marks for its replay.
  `closeInput {id}`, `terminate {id}`: what `AgentProcess.closeInput` and `terminate` do
  today.
- `setMeta {id, meta}`: replace the blob.
- `acknowledge {id}`: the app has the process's end; the host forgets it and its log.
- `detach {id}` (minor 1): the app lets go; the process carries on with nobody attached, and
  the other apps get `released`.
- Events: `record {id, offset, kind, time, attached, bytes}` (`kind` is `out`, `in` or
  `note`; an `in` echoes the attached app's own write, so its offset is known; `time` is when
  the host logged it and `attached` whether an app was attached then, which says nothing of
  a reply), `caughtUp {id, offset}` (the attach's backlog is sent and what follows is live,
  `offset` being the log's end), `stderr {id, text}`, `exited {id, status}`, and, to every
  connected app, `released {id}` when the app attached to a process disconnects.

**Who may connect:** the peer's uid must be the host's (`getpeereid`), and the peer's code
signature, checked from its audit token, must carry the host's own team identifier. Debug
builds are signed with the team too, so there is no exception for them.

## §3 The app's side

- **`ProcessTransport`**, the seam: what `AgentSession` asks of a process today (start,
  events, send, close input, terminate, is running) as a protocol, with two
  implementations: `AgentProcess` as it is (the direct child) and `HostedProcess`, which
  does the same over the host connection. The backends and the transcript change only by
  the replay mode below.
  Tests get the direct transport unless a test is about hosting, which then runs its own
  host on a socket in a temporary directory.
- **`meta`** is the app's per-process record: the session's id once known, folder, agent,
  account, name, mode and model picks, the project window it belongs to, the fan-out batch
  it is in, and where its history stood when the process started: for Claude Code the
  transcript file's length, for Codex the number of turns the thread held.
  The app updates it as these change. With it, the relaunched app can rebuild the session
  without asking the CLI anything.
- **Quitting** hands over the sessions at work: mid-turn, or waiting on a permission or a
  question. The app sends them nothing and they carry on. An idle session's process is
  stopped, as today: nothing is in flight, and its next prompt resumes it. *(My call: it
  keeps the host from holding every open window's idle `claude` and its MCP servers
  forever, and lets it exit.)* A session handed over whose turn then ends stays up, idle,
  in the host until the app comes back and stops it by the same rule. The quit confirmation
  for running sessions goes; the unsaved-files one stays.
- **Closing a window, End Session, removing a row** still stop the process, as now: those
  are about the session, not the app. *(My call; see "Settled with the person".)*
- **Relaunch.** At launch the app connects, lists what the host holds, and makes sure every
  project window with a held process no app is attached to is open, whether or not windows
  reopen in Settings. Each window rebuilds its sessions from `meta`, loads the history from
  before the process, then attaches from the log's start and replays it.
  - *History before the process:* Claude Code's transcript file up to the length in
    `meta`; for Codex, the thread read as today (`readCodexHistory`) and cut to the turn
    count in `meta`, since the rest is in the log.
  - *Replay mode*, in the backends and the session: records are taken in order with
    every write muted. An `in` record goes through the path the app's own send took (a
    prompt is added to the transcript, an answer resolves its permission, a Codex call is
    registered so its response is matched); an `out` record is received as usual. History
    before the process plus the replay gives each entry exactly once.
  - *Owed replies:* the backends answer some requests on their own (Claude Code declines
    an elicitation, refuses an unknown control request, asks for context usage after a
    `result`). At the end of the replay they send those still owed: for a request that no
    `in` record answers. A permission no `in` record answers is shown pending, and the
    person answers it as usual.
- **A process that ended while the app was away** is replayed the same way, its end shown
  as usual, then acknowledged.
- **Fan-out batches** are recorded in the `meta` of their sessions (batch id, prompt,
  limit, place in the queue). The waiting sessions have no process yet, so the batch also
  goes in the window's `StoredProject`; after the relaunch the batch carries on sending
  where it stopped.

## §4 Two apps, one host

Two Drakar builds can be up at once (a worktree's `make run` while the main build runs). A
process belongs to the app attached to it; a launching app attaches only to those no app
is attached to, so it never takes sessions from a running one. A process another app
holds is shown as a session live elsewhere is today:

- Claude Code: read-only, following its transcript file (`isReadOnly`).
- Codex has no file to follow, so it shows its history up to the handover and a line
  saying it runs in another Drakar window. That line is new; it is not live.

When the other app quits, the host sends `released`, and an app showing that process
read-only attaches and replays it, so it comes back to life without a relaunch. There is
no way to take a process from an app that is running.

## §5 Versions and failure

- **The protocol major is in the socket's name.** A new app that speaks a newer major does
  not use an older host for new processes; it starts its own host, on its own socket. The
  older host's processes are found by listing older sockets the app knows how to read (a
  `list` with no `attach` is kept compatible across majors) and are shown read-only, as in
  §4. That host exits when its last process ends. Minor
  versions only add fields and requests, and both sides ignore what they do not know.
- **No host can be started** (the helper missing from the bundle, the spawn failing):
  sessions run as children of the app, as today, and the quit confirmation for running
  sessions comes back for them. The footer says these sessions stop with the app.
- **The socket exists but nothing answers** (a host that crashed): the app removes it and
  starts a host. The crashed host's processes died with it; their sessions resume from
  their transcripts, as after a quit today.
- **The app loses the connection** while running: its hosted sessions show as interrupted,
  it reconnects with backoff, and reattaches from the offset it last read.

## Testing

- The host on its own (its target's tests, socket in a temporary directory): spawn, write,
  log replay from an offset, exit while nobody is attached, acknowledge, idle exit, takeover,
  a refused peer.
- `HostedProcess` against a real host with a stand-in CLI (the tests' `cat` scripts): the
  `AgentSession` suites that drive a stand-in process pass on both transports.
- Reattaching: start a session through a host, drop the app's side mid-turn, rebuild the
  project from `list`, check the transcript has each entry once (prompts included), an
  answered permission is not pending again, an unanswered one is, and replay wrote nothing
  to the CLI; then a process that exits while nothing is attached.
- Owed replies: an elicitation that arrives while no app is attached is declined once,
  after the replay, and one already declined is not declined again.
- Codex: a thread rebuilt from its history cut to the turn count plus the replay has each
  turn once, and the session can then steer and interrupt.
- Two apps: a launching app leaves a process another app holds alone, and takes it on
  `released`.
- Versions: an app finding an older major's socket shows its sessions read-only and never
  writes to them.

## Left to the builder

- Framing details, base64 or not for stderr, request ids and error replies.
- How `meta` is encoded and versioned, as long as the host never reads it.
- Where `ProcessTransport` lives (`DrakarKit` is the likely home, next to `AgentProcess`).
- The reconnect backoff, the idle timeout's exact value, log file naming.
- How the Makefile and CI build and sign the helper.

## Risks to check first

1. **Replay mode.** The backends write while they read, and the transcript builds entries
   from live stream differently than from the transcript file (partial messages,
   `stream_event`s). A spike first: record a real session's log in both directions and its
   transcript file, rebuild a session from the history before the start plus the replay,
   compare it with what the live session showed, and check nothing was written. For both
   agents.
2. **A CLI whose reader goes away.** While the app is gone the host still reads stdout, so
   the CLI never sees a closed pipe. Check that a CLI waiting on a permission answer for
   hours is still there when the app comes back, for both agents.
3. **Codex's app-server under a host:** the same check for its requests and approvals.

## Settled with the person

Approved 2026-10-25. The two questions left open were not answered, so the document's
defaults stand, each the builder's call until the person says otherwise:

- Closing a window stops its sessions, as today (§3); only quitting, a crash or an update
  hands sessions to the host.
- Quitting says nothing when sessions keep running: the confirmation for running sessions
  simply goes.

## Departures in the build

The protocol as built is in `docs/session-host.md`. Where the build differs from the text
above, the build stands:

- **Owed replies (§3)** are decided by the log's `in` records, not by the `attached` flag:
  an automatic write the replay produced while taking an `out` record, which no later
  byte-equal `in` matches. The flag stays on records and says nothing of a reply; the
  flag rule double-replied after a second relaunch and dropped replies at the quit boundary.
- **`note` and `caughtUp` (§2)** are in the protocol from the start: the app's own marks
  for its replay, and the end of an attach's backlog.
- **`detach {id}` (§2)** was added (minor 1): the app lets go of a process that carries on.
  `released` follows from it, from a disconnect, and also from `acknowledge`, since a
  process an app watches read-only is gone once it is forgotten. A new connection relists
  what rows show read-only and settles them the same way, since a `released` sent while
  disconnected is lost.
- **Lanes (§2)** are per connection and process, not per process: a detach never overtakes
  the same connection's later attach, and a stuck write on one connection delays no other.
  `terminate` runs inline.
- **Who may connect (§2)** adds the app's identifier to the team check (read from the
  host's own signature, `<id>.DrakarHost` minus the suffix): a team-signed tool without the
  hardened runtime could carry an injected library.
- **One clock (§3):** `AgentProcess` stamps each batch it reads with the time it was read,
  and a replayed record is timed by the host's `time`, so a live session and its replay
  time entries alike.
- **The replay's bound (§5)** is silence, not time: a host that sends nothing of the log for
  10 seconds is let go of (`Failure.quiet`), as a long log takes seconds.
- **Spawn limit:** a host that does not answer a `spawn` within 10 seconds is given up on,
  and a late `spawned` is ended and acknowledged at once.
- **A process that ends while the app runs** (window closed, End Session, row removed, its
  own exit) is acknowledged as its exit arrives; only processes stopped during quit stay
  unacknowledged for the next launch to show. Otherwise the idle exit never comes.
- **Rows another app holds (§4):** the live-session filter excludes a host's descendant
  only when its session is one this app's own rows host, so another Drakar's sessions still
  read as live elsewhere.
- **A window taking back its held sessions** (`takeBackHeld`) gates the rows it kept for the
  same sessions (`waitsForHost`): they send nothing until the host's processes are adopted,
  so none starts a second process.
- **The slowest peer** is dropped once 512 MiB waits unread for it; it reattaches from its
  offset.
- **Quitting (§3)** sends the host a `detach` for each session handed over: the CLI is sent
  nothing, but the host clears the attachment and tells the other apps `released`, so a
  second Drakar can take the session without waiting for the socket to close.
- **`hello` (§2, §5)** never ends the connection: the host always answers `welcome` with its
  own major, and the app decides. It skips a host whose protocol is not lower than its own
  for older-host listing, and reads an older one list-only.
