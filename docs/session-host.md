# The session host

`DrakarHost` is a small helper in `Drakar.app/Contents/Helpers/` that holds the `claude`
and `codex app-server` processes Drakar's sessions run, so they outlive the app: a quit, a
crash, a Sparkle update or a `make run` leaves them working, and the next launch attaches
again and replays what they did meanwhile. This is the protocol as built (HostWire major 1,
minor 3). The design and its reasons are in
`docs/superpowers/specs/2026-10-25-session-host-design.md`, which lists where the build
departed from it.

## What it is, and is not

- **It holds bytes.** For each process: its configuration as the app sent it, the process
  with its three pipes, an opaque `meta` blob, a log of both directions on disk, the tail of
  its stderr, its exit status once it has one, and which app is attached. It frames lines on
  `\n` and nothing else: it never parses a line, a note or `meta`, and does not know Claude
  Code from Codex. Every rule about sessions stays in the app.
- **No host is a fallback, not a mode.** With no host (helper missing, spawn failing), the
  app runs sessions as its own children and says so; the footer reads "Stops when Drakar quits.".
- **Tests never reach the real one.** Under XCTest (`XCTestConfigurationFilePath`) the app's
  `SessionHost` is off unless a test gives it a directory.

## Where things live

`~/Library/Application Support/<bundle id>/host/`, mode 0700 (`io.mgcrea.Drakar`, shared by
the Release build and every Debug build, so they share one host):

| File | What |
| --- | --- |
| `host-v1.sock` | The Unix socket, mode 0600. The `1` is the protocol major. |
| `host.lock` | `flock`ed (exclusive, non-blocking) by the running host, close-on-exec so no CLI it spawns keeps it. A second host that cannot take it exits 0. |
| `<id>.log` | One process's log, mode 0600; `<id>` is the UUID `spawned` returned. Removed when the host forgets the process (`acknowledge`, or a `terminate` with `forget` once it ends). |

The socket path must fit `sockaddr_un.sun_path` (103 bytes and a NUL); a longer one is
refused with an error, never truncated.

The app starts the helper on demand: `posix_spawn` with `POSIX_SPAWN_SETSID`, stdio on
`/dev/null`, `--directory <dir>`. It is not a launchd agent. The host raises its descriptor
limit (about four descriptors per process held), ignores `SIGPIPE`, and holds `host.lock`
for its life. No CLI it spawns can hold the socket or an app's connection: Foundation's
`Process` on Darwin closes every inherited descriptor but stdio in the child (checked
2026-10-25 with `lsof` on a `Process`-spawned `/bin/sh` whose parent had a socket and a file
open without close-on-exec: only 0–2 were left), and the host also sets close-on-exec on
every socket it opens or accepts. A spawn path other than `Process` would need its own
`POSIX_SPAWN_CLOEXEC_DEFAULT`. Whoever starts it first runs its copy; hosts of one major are interchangeable.
A host that takes `host.lock` removes every `*.log` in the directory before it serves: it
holds nothing yet, so they are what a host killed by a logout, a reboot or a crash left.

**Idle exit.** The host leaves when it holds no process, running or ended and
unacknowledged, and no app has been connected, for 30 seconds in a row (checked every 5).

## Who may connect

1. The peer's uid is the host's (`getpeereid`). Checked first; nothing else is shown another
   user's program.
2. The peer's code signature, read from its audit token (`LOCAL_PEERTOKEN`, which a reused
   pid cannot fake), satisfies `anchor apple generic and identifier "<app id>" and
   certificate leaf[subject.OU] = "<team>"`. The team and the app's identifier are the
   host's own, read from its signature (the helper is signed `<app id>.DrakarHost`). Not any
   program the team signed: one without the hardened runtime could be made to load a
   stranger's code. Debug builds are signed with the team, so there is no exception. A host
   that is unsigned, or not named as the app's helper, lets nobody in.

A peer refused is closed without a word. `DrakarHost` is the only target that imports
`Security`.

## Framing

Newline-delimited JSON, one object per line, both directions, `\n` ends a line. The default
`Codable` shapes: an enum case is `{"<case>": {<labelled values>}}`, an unlabelled value is
`_0`, `_1`; `Data` is base64; `Date` is seconds since 2001-01-01 (a number); a `URL` is a
`file://` string. A line the CLI wrote travels as base64 in `bytes`, so it is never split
or re-encoded. Key order is not significant.

**Requests** carry an id the app numbers, from 1, per connection:

```json
{"id": 4, "request": {"attach": {"id": "7B1C…", "from": 0}}}
```

**Answers** are one line each, and name the request they answer:

```json
{"to": 4, "events": [{"refused": {"reason": "no process 7B1C…"}}]}
```

`events` holds the core's direct replies, often none: a `write` that works is answered
`{"to": 5, "events": []}`. An answer with no `to` carries one event the host delivers on
its own: an attach's stream (records, `caughtUp`, `stderr`, `exited`) or a `released`.

A request the host does not know (a newer minor's) is answered `refused` ("unknown
request") if its `id` can be read; a line it cannot read at all is dropped. An app skips an
event it does not know, not the whole answer.

## Requests

| Request | Answer | Does |
| --- | --- | --- |
| `hello {protocol, appVersion}` | `welcome {protocol, hostVersion, pid}` | Always the host's major, whatever the app sent: the app decides. A newer app reading an older host only lists. |
| `list` | `listed [HeldProcess]` | `HeldProcess`: `id`, `meta`, `running`, `exitStatus?`, `logLength`, `attachedApp?` (the attached app's pid). |
| `spawn {configuration, meta}` | `spawned {id}` or `refused` | Starts the process and its log. `configuration`: `executable`, `arguments`, `environment`, `currentDirectory`. |
| `attach {id, from}` | none; the stream | Sends the log from byte offset `from`, then `caughtUp`, then live. Refused while another app is attached. `from` must be a record's offset or the end. |
| `write {id, bytes, logged?}` | none | Written to stdin, then logged as `in`. Returns once the CLI has taken the bytes. `logged` (minor 3), when present, is what the `in` record holds in place of `bytes`: the app sends it for an accepted MCP form, its values each `"<redacted>"` (`ClientMessage.redactedLine()`). Omitted, as an older app sends it, `bytes` are logged. An older host ignores it and logs `bytes` in full. |
| `note {id, bytes}` | none | Logged as `note`, written to nothing: the app's own marks for its replay. |
| `closeInput {id}` | none | Closes stdin. |
| `terminate {id, forget?}` | none | Ends the process. `forget: true` (minor 2) has the host forget it once it has ended, as `acknowledge` would, for an app that may be gone by then; at once if it has ended already. Omitted, as an older app sends it, what ended is kept. |
| `setMeta {id, meta}` | none | Replaces the blob. |
| `acknowledge {id}` | none | The app has the process's end: the host forgets it and deletes its log. Refused while it still runs. |
| `detach {id}` | none | Minor 1. The app lets go: the process carries on with nobody attached. A no-op when nobody is. |

A request naming a process attached to another app is refused (`<id> is attached to another
app`); `terminate` and `closeInput` are checked the same way. An unknown id is refused (`no process <id>`).
The request is not repeated: the app learns of a refusal from the answer, or, for the
fire-and-forget ones, in the process's attach stream.

## Events

| Event | Sent | Fields |
| --- | --- | --- |
| `welcome` | to `hello` | `protocol`, `hostVersion`, `pid` |
| `listed` | to `list` | `[HeldProcess]`, sorted by id |
| `spawned` | to `spawn` | `id` |
| `record` | attach stream | `id`, then the record (below) |
| `caughtUp` | attach stream | `id`, `offset`: the log's end; what follows is live |
| `stderr` | attach stream | `id`, `text` as it comes; an attach after the exit gets the tail |
| `exited` | attach stream | `id`, `status`; ends the stream |
| `released` | unprompted | `id`: no app holds it any more, and it may be gone |
| `refused` | answers | `reason`, free text |

`released` goes to every other connected app when (a) the app attached to a process
disconnects or sends `detach`, and (b) a process is forgotten: acknowledged, or ended after a
`terminate` with `forget`. An app that holds nothing ignores it.

## The log and its records

One JSON line per record, in the order the host saw them. A record:

```json
{"offset": 812, "kind": "out", "time": 814000000.5, "attached": false, "bytes": "<base64>"}
```

- `offset`: where the record's line starts in `<id>.log`, in bytes. What `attach` resumes
  from; the log's length is `logLength`.
- `kind`: `out` is a line the CLI wrote on stdout, with its `\n` kept; `in` is what the app
  wrote to its stdin, logged after the CLI took it (only a logged `in` says it was sent);
  `note` is what the app left for its own replay.
- `time`: when the host logged it, from the host's one clock, which is the only clock a
  replay times entries by.
- `attached`: an app was attached when it was logged. Informational: it says nothing of a
  reply.
- `bytes`: opaque.

**Order.** A line the CLI writes in answer to a write is never logged before the write's
`in`: output read while a write is under way waits and is logged after it. Everything is
appended under one lock together with becoming the attached app's live receiver, so an
attach reads its backlog (off that lock: the log's own lock is held only to read the bytes,
not to decode them, so a long log holds up the process's appends for the read alone), then
the records logged meanwhile, then goes live: each record reaches the app once, as backlog,
catch-up or live.

**Crash safety.** A last line the host died halfway through writing is not a record: the log
ends before it and the next append overwrites it.

stderr is forwarded to the attached app and its tail kept; it is not in the log.

## Lanes and ordering

Requests are handled off the connection's read queue so that a write blocked on a CLI slow
to read stalls nothing else.

- Per connection and per process there is one serial lane. `attach`, `write`, `note`,
  `closeInput`, `setMeta`, `detach` and `acknowledge` naming a process run on that lane in
  the order the app sent them, so a `detach` never overtakes the same connection's earlier
  `write` or is overtaken by its later `attach`.
- `terminate` runs inline, not on the lane: killing the CLI is how a stuck write ends.
- `hello`, `list` and `spawn` run inline too, so a `list` is not ordered against the lane
  requests before it.
- Lanes of different processes, and of different connections, do not wait on each other.
- Delivery to an app is in the order events were made, on one queue per host.

A peer that leaves more than 512 MiB unread is dropped, which detaches it like any lost
app; it reattaches from its offset.

## Versions

- **The major is in the socket's name** (`host-v1.sock`). A new major does not talk to an
  older host: it starts its own on its own socket. The app lists older sockets it knows
  (`host-v<n>.sock`, `n` below its major), says `hello`, `list`s, and shows what it finds as
  sessions held elsewhere (read-only). It never attaches to them.
- **Minor versions only add** fields, requests and events, and both sides ignore what they
  do not know. Minor 0 → 1 added `detach`; 1 → 2 added `terminate`'s `forget`; 2 → 3 added `write`'s `logged`. `HostWire.major` / `HostWire.minor` are the
  constants.
- A Sparkle update replaces the bundle while the old host runs from its open inode; the new
  app then speaks to an older-built host of the same major, hence the rules above.

## From the app's side

**Starting a session.** `HostedProcess.start()` sends `spawn` (the process and its `meta`),
then attaches from 0 and streams. Requests made before `spawned` arrives are held and sent
in order. A host that does not answer within 10 seconds is given up on; a late `spawned`
is terminated and acknowledged at once.

**Keeping `meta` current.** The session's id, folder, agent, account, picks, window, fan-out
mark and where its history stood when the process started. The app sends `setMeta` as these
change, and `note`s for what a replay needs to redo its own actions (a command's effect, a
start). The host reads none of it.

**Quitting.** Sessions at work (mid-turn, or waiting for a permission or a question) are
handed over: the CLI is sent nothing, but the app sends the host a `detach`, which clears
`attachedApp` and tells the other apps `released`. An idle session's process is terminated
with `forget`: the host forgets it once it ends, the app being gone by then. The connection is
flushed at will-terminate. A window closed, End Session or a removed row stops its process
the same way, and the app also acknowledges it when its exit arrives (an older host ignores
`forget`). So what the next launch finds is only what a quit handed over at work. A window
that closes while it takes a process back stops the session it rebuilt as it stops its rows,
rather than leave the process attached to the app with no row.

**Relaunch.** The app connects, `list`s, and for each process no app is attached to whose
`meta` names a window, opens the window and rebuilds the session from `meta` (history from
before the process: Claude Code's transcript file up to the length in `meta`, Codex's thread
cut to the turn count), then `attach`es from 0 and replays.

**Replay.** Records are taken in order with every write muted: an `in` goes through the path
the app's own send took (a prompt is added, an answer resolves its permission, a Codex call
is registered), an `out` is received as usual, a `note` redoes the app's own effect. Nothing
reaches the CLI. A replay is parsed off the main actor and yields between slices. A host
that sends nothing of the log for 10 seconds (quiet, not slow: a long log takes seconds)
is let go of and the row shows the failure; a refused attach or an ended connection does the
same.

**Owed replies.** Some requests the backends answer on their own (an elicitation declined,
an unknown control request refused, a context-usage request after a `result`). One is owed
if the replay received it as an `out` record and no later logged `in` is byte-equal to the
reply it would produce. The `attached` flag does not decide this. Owed replies are sent once,
at the end of the replay, before live lines are taken. A permission no `in` answers shows
pending.

**Ended while away.** A process whose `exited` the replay reaches is shown ending as it would
live, then `acknowledge`d: the host forgets it and deletes the log.

**A connection that ends** ends the events but not the process. The app reattaches on a new
connection from the later of the last `caughtUp` offset and the last record delivered
(which is sent again and skipped), with backoff.

**Two apps.** A process belongs to the app attached. A launching app attaches only to those
with `attachedApp` nil; the others show read-only (Claude Code follows its transcript file;
Codex shows its history and a line saying it runs in another window). On `released`, the
app lists again: a process still held and unattached is attached and replayed; one the host
no longer holds is replaced by a plain resumable session (draft kept). On every new
connection, rows shown read-only are settled the same way, since a `released` sent while
disconnected is lost. While a window takes back its held sessions (`takeBackHeld`), rows it
kept for the same sessions send nothing, so none starts a second process.

**Fan-out.** The batch's state is in the `meta` of its running sessions and in the window's
stored project; after a relaunch the batch carries on where it stopped.

## Inspecting a log by hand

The host is not needed: a log is plain JSON lines.

```sh
cd ~/Library/Application\ Support/io.mgcrea.Drakar/host
ls -l                                   # host-v1.sock, host.lock, <id>.log
# What happened, in order (time is seconds since 2001):
jq -c '{offset, kind, t: (.time + 978307200 | todate), attached}' <id>.log | head
# What the CLI wrote:
jq -r 'select(.kind == "out") | .bytes | @base64d' <id>.log
# What the app sent it, and its notes:
jq -r 'select(.kind != "out") | "\(.kind) \(.bytes | @base64d)"' <id>.log
# Is a host up? Its pid is in the welcome; the lock is held by it:
lsof host.lock
```

To ask a running host, connect to the socket from a program signed by the app's team; a
shell cannot pass the peer check. The `HostWire` tests in DrakarKit and `HostClient` are the
reference clients.

## Checking replay against the real CLIs

The replay tests use stand-in CLIs. Two opt-in tests in `SessionReplayTests` run the real
ones: `liveClaudeReplayMatches` (Haiku, `--setting-sources project`, a prompt that thinks and
runs a tool needing permission, then a second turn) and `liveCodexReplayMatches` (a scratch
git folder). Each records a live session, replays the record, and requires
`transcript.entries` to be equal, nothing written during replay, and nothing owed. They are
skipped unless the variable is set, and `xcodebuild` only passes it to the tests with the
`TEST_RUNNER_` prefix:

```sh
TEST_RUNNER_DRAKAR_LIVE_CLI=1 xcodebuild test -project apps/apple/Drakar.xcodeproj \
  -scheme Drakar -destination 'platform=macOS' -only-testing:DrakarTests/SessionReplayTests
```

Run it after a CLI update that changes the stream. Observed 2026-10-25 with Claude Code
2.1.308 and codex-cli 0.163.0: exact equality for both, once lines were timed when read
(before that, thinking durations differed by up to 51 ms). A Claude run costs about $0.025;
each live part takes 8–19 s. Every run leaves its session in the person's own stores
(`~/.claude/projects/-private-tmp-dh-live-*`, `~/.codex/sessions/<date>/`); nothing removes
them.

Not covered by it: Codex reasoning items (the cheap models produced none), a resumed session
(history cut at the transcript length), and the host's raw bytes (the test's recorder logs
each line re-serialised after parsing).
