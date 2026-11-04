# Sessions on another Mac

## Why

The person has a second Apple Silicon MacBook they keep on around the clock, and wants it to
take the work that takes over a screen: screenshot runs, `make smoke`, a Cupertino driving
session, anything where using the Mac meanwhile disrupts the run or the run disrupts them.
On their own Mac that work has to wait for a hands-off window (Cupertino's driving checks
exist because typing into a run ruins it), and it cannot run while the laptop sleeps or
travels.

The session host already holds `claude` processes apart from the app, logs both directions
and replays them to whichever app attaches (`docs/session-host.md`). This design puts that
host on the second Mac and lets the Drakar on the person's Mac attach to it: the `claude`
runs on the runner, in a checkout on the runner, with the runner's own MCP servers
(Cupertino installed there, so its tools drive the runner's screen); the person watches the
conversation, answers its permission prompts and sends prompts from their own Mac, and
nothing moves on their screen.

Names used below: **the Mac** is the person's, where they work; **the runner** is the other
one. Both run a regular, signed Drakar.

## Goals

- From the Mac, start a Claude Code session in a folder on the runner, and use it as any
  session: prompts, the streamed conversation, tool calls, permission prompts and
  questions, elicitations, interrupt, model/mode/effort picks, End Session.
- The session keeps working while the Mac sleeps, quits Drakar, loses the network or
  travels; when the Mac's Drakar comes back it reattaches and replays, as a relaunch does
  for a local host today.
- Home on the Mac lists the runner's sessions, under the runner, apart from local projects.
- **Open on the runner**: the person hands a session to the runner's own Drakar (reached
  over Screen Sharing) when they need the editor, the file tree or anything else v1 leaves
  out, and **Bring back** hands it back.
- Off until the person names a runner. A Drakar with no runner configured behaves, and
  audits, exactly as today.

## Non-goals (v1)

- **The editor on remote sessions**: file sidebar, tabs, ⌘P, ⇧⌘F, file watching, save,
  Show in Finder, file links. A remote window shows the conversation only. The way to the
  editor is Open on the runner. *(Settled with the person.)*
- **Resuming, forking or renaming a remote session after its process ends**, the "ended"
  sidebar groups for the runner, and subagent feeds. All of these read transcripts from
  disk (`TranscriptFollower`, `locateTarget`, `SubagentFeed`), and the runner's transcripts
  are not on the Mac. v1 covers a session for as long as its process lives, which is what
  the host log already carries. A transcript channel is the v2 that lifts this (see
  "After v1").
- **Codex on the runner.** Its history and skills come from a short-lived local
  `codex app-server` (`AgentSession.swift:701-716`, `CodexSkills.swift`). v1 is Claude
  Code only; the new-session picker offers no Codex for a runner folder. *(My call.)*
- **Scheduling.** Sessions on the runner are started by the person from the Mac. A
  scheduler comes after remote sessions have been lived with.
- Fan-out across runner subfolders (`SubfolderScan` is local). The fan-out button is
  hidden for runner folders.
- More than one runner. The setting holds one; the model below keys everything by runner
  name so a second is an addition, not a rewrite.

## Anti-goals

- **A host that changes.** `DrakarHost` stays a holder of bytes: no network, no knowledge of
  ssh, no new requests for this feature. Everything new is in the app and the relay.
- **Anything a stranger can reach.** The host's peer check (`PeerSignature`, same uid, the
  app's own signature) stays exactly as it is. The only new way in is ssh, authenticated by
  the person's own keys, landing in a process that passes that check.
- **A remote session that lies.** Where v1 cannot do something for a runner session, the
  control is absent or says why. It never shows the Mac's files, transcripts, accounts or
  usage as if they were the runner's. The sweep in "Every local read" is the list of places
  where today's code would do exactly that.
- **Drakar opening network connections of its own.** The Mac's Drakar spawns
  `/usr/bin/ssh`, as it spawns `claude`; it links nothing new.

## Constraints

- Developer ID, Sparkle, not sandboxed, no entitlements (as today). A spawned
  `/usr/bin/ssh` is open to it.
- The host's peer requirement is `anchor apple generic and identifier "<app id>" and
  certificate leaf[subject.OU] = "<team>"` (`DrakarHost/PeerSignature.swift`): only the
  app's own binary passes. Hence the relay is the app's binary, not a new helper.
- `HostClient` speaks over a single fd with plain `read`/`write`
  (`Host/UnixSocket.swift:144,181`), so a `socketpair` whose other end is ssh's stdin and
  stdout works unchanged. `HostClient.init(_:)` is private: it needs a public
  `connect(fd:)` (or equivalent) beside `connect(socket:)`.
- `AgentSession.sessionHost` and `Project.sessionHost` default to `SessionHost.shared` and can
  be injected (`AgentSession.swift:157`, `Project.swift:393`): a remote session gets its
  runner's host object there.
- Network rules: `make audit`, `make audit-running` and `make audit-release` must still pass
  with no new allowance in Drakar's own code. README and SECURITY gain one sentence each
  (§6).
- Tests never reach a real host or a real runner (as today).

## §1 The relay

`Drakar.app/Contents/MacOS/Drakar --relay` is the app's binary started in a mode that never
brings up AppKit or SwiftUI. `DrakarApp` is `@main` today; it gets an explicit entry point
that checks for `--relay` first and otherwise runs `DrakarApp.main()`. *(My call: the app
binary passes the peer check as it stands; a separate relay helper would need the
requirement widened.)*

The relay:

1. Writes one line of **facts** to stdout, JSON, then nothing else of its own:
   - `relay`: its own protocol version (`1`), independent of HostWire's.
   - `drakar`: its version and build.
   - `hostMajors`: the HostWire majors this build speaks.
   - `home`, `user`, `hostname`.
   - `environment`: the environment of the runner's **GUI session**, where the host and
     every `claude` run (§2), not the ssh session the relay itself runs in. The runner's
     Drakar writes it at each launch (`ShellEnvironment.read` as today, run in the GUI
     session) to `runner-environment.json`, mode 0600, beside the host's directory; the
     relay reads that file. It is the app's file, not the host's: the host neither writes
     nor reads it. Should the file be missing, the relay reads the login shell itself and
     removes `SSH_CONNECTION`, `SSH_CLIENT`, `SSH_TTY` and `SSH_AUTH_SOCK`, and says so in
     the facts (`environmentFrom: "ssh"`), which Settings shows. *(My call: an
     `SSH_AUTH_SOCK` from the ssh session is dead once it closes, and a `git push` from the
     runner needs the GUI session's agent.)*
   - `claude`: what `ClaudeLocator` finds on the runner (path, version), every candidate
     as Settings lists them locally; `accounts`: the runner's Claude config directories, as
     `AccountStore` finds them.
   Before the facts, the relay checks that the runner accepts remote sessions
   (Settings › Runner › "Let my other Macs start sessions here", §2, read from the app's
   own defaults domain, which the relay shares). Off, it writes the reason to stderr and
   exits non-zero; nothing else happens.
2. Makes sure a host is up on the runner (§2), connects to `host-v1.sock`, and from then on
   copies bytes stdin → socket and socket → stdout until either side closes. It parses no
   HostWire, so the host's protocol can move without the relay knowing.
3. Exits when stdin closes or the socket does. Its stderr is ssh's stderr; it writes a
   reason there before any non-zero exit (no host could be started, the socket path does
   not fit, a major it does not speak).

The relay does no licence check (the host does none either; the licence covers every Mac
the person owns, `apps/apple/EULA`).

## §2 Starting the runner's host from ssh

**The host must not be started from inside the ssh session.** A process started under
sshd lives in sshd's (non-GUI) bootstrap context, and so would every `claude` it spawns:
the login Keychain, where Claude Code keeps its credentials, the window server, and the
TCC attribution a screenshot or UI test needs all belong to the person's GUI session, not
to that one. This is the first thing to check by spike (Risks, 1).

So the host is only ever started by the runner's Drakar app, in the GUI session:

- **The runner opts in.** Settings › Runner on the runner has "Let my other Macs start
  sessions here", off by default. While it is on and the app runs, the app keeps a
  connection to its host open (connecting, starting the helper as today, at launch and
  whenever the connection drops), so the host's idle exit never fires while the app is up.
  The host is unchanged: an app staying connected is already what keeps a host alive.
  Turning it off closes that connection; the host then leaves when it holds nothing, as
  today.
- **The app is not running** (it quit, or the runner just rebooted before the login item
  came up): the relay asks LaunchServices to start it in the person's GUI session, as
  Cupertino's bridge does for its app: `/usr/bin/open -g -j -a <its own bundle>`. With the
  opt-in on, that launch connects to (and so starts) the host as above. No launch argument
  is involved, because `open` drops `--args` for an app that is already running.
- The relay waits for the socket to answer (15 s), then gives up with a reason on stderr.

*(My calls: the opt-in doubles as the runner's consent, so a Mac whose ssh key reaches the
runner still cannot use it as a runner until someone at the runner said yes; and it avoids
a URL scheme or Apple Event that other programs could trigger.)*

This needs the person to be logged in to the runner's desktop, which an always-on runner
is (auto-login, no lock; see "Setting up the runner").

## §3 The Mac's side: a runner and its host

**Settings › Runner** (new pane): a name to show (default: the runner's `hostname` from its
facts), the ssh destination (anything `ssh` accepts: a `~/.ssh/config` alias, `user@host`),
and the path to Drakar on the runner (default `/Applications/Drakar.app`). A **Test**
button connects, shows the facts (Drakar version, `claude` found and its version, accounts)
and disconnects. Empty destination means no runner; nothing below happens.

**`RemoteSessionHost`**, the runner's counterpart to `SessionHost`, owned by the app for
the configured runner:

- Connects by spawning `/usr/bin/ssh -T -o BatchMode=yes <destination>
  <path>/Contents/MacOS/Drakar --relay`, with a `socketpair` end as its stdin and stdout and
  a pipe for stderr. `BatchMode` because there is nobody to type a passphrase into; the
  person's `~/.ssh/config` supplies everything else (keys, `ControlMaster`, Tailscale
  names). Drakar writes nothing to `~/.ssh`.
- Reads the facts line, then hands the fd to `HostClient.connect(fd:)` and says `hello` as
  `SessionHost` does.
- Keeps that connection open while the app runs and a runner is configured, so Home can
  list it; reconnects with backoff when it drops (sleep, network, the runner rebooting),
  reattaching each attached session from the offset it last read, as §5 of the
  session-host design does for a lost local connection.
- **A stale relay.** When the network drops without a clean close, the runner's old relay
  stays attached until the runner's sshd notices (`ClientAliveInterval 30`,
  `ClientAliveCountMax 3` in its `sshd_config`, a setup step) and hangs it up; the relay
  exits on SIGHUP or stdin EOF, and the host sends `released`. Meanwhile a reattach is
  refused as "attached to another app": for a process this Mac owns, `RemoteSessionHost`
  treats that refusal as "still releasing", retries with backoff for up to three minutes,
  and shows the session as reconnecting rather than as held elsewhere. *(My call: the relay
  stays a byte copier, and no relay can end another.)*
- `hostPID` is nil. Nothing that walks local process parents (`ProcessAncestry`, the live
  checks in `SessionIndex`) is ever given a runner's pid.
- A major the facts do not list, or a relay version it does not know: no connection, and
  Settings and Home say "Update Drakar on <runner>" (the runner's Sparkle only runs when
  its app runs; see "Setting up the runner").
- ssh's stderr tail is kept and shown with any failure (host key changed, permission
  denied, `Drakar` not found at the path).

## §4 A remote session

**Identity.** A project, a window route and a session gain a `runner` field (the
runner's configured name; nil means this Mac). A runner project is keyed by
`(runner, path)`: a runner folder never merges with a local project at the same path, in
Home, in window restore or anywhere else. `ReopenedWindows` does not drop a runner window
because its folder is missing on the Mac; it reopens it disconnected if the runner is not
reachable.

**Choosing a folder.** File › New Session on Runner… (and a runner section in the session
picker) takes a path on the runner, typed, with the runner's recent folders below it (those
of its sessions the host lists, by `meta.windowFolder`). No local `fileExists`
(`AgentSession.swift:813`, `CapabilityProbe.swift:51`): a folder that does not exist on the
runner fails the spawn there, and the host's refusal is shown.

**The spawn.** The `Configuration` is built from the runner's facts, never from the Mac:
the executable is the runner's `claude` (its default candidate, or the one picked for the
runner in Settings), the environment is the runner's login-shell environment, the account
directory is one of the runner's, `currentDirectory` is the runner path. Nothing of the
Mac's environment (HOME, PATH, TMPDIR, SSH_AUTH_SOCK…) reaches it
(`AgentSession.swift:1480-1488` today passes the Mac's). The arguments are what
`ClaudeLaunch` builds for a new session today, with no resume.

**`meta`** is as today, plus:

- `runner` as above.
- **`origin`**: the Mac that started the session (that Mac's
  `Host.current().localizedName`, sent by its app). Set at the spawn, never changed.
- **`owner`**: the Mac whose Drakar the session belongs to now: the same name as `origin`
  while the Mac holds it, absent once it is handed to the runner's own Drakar (§5).

Every path in `meta` (`start.folder`, `accountPick`, `history`) is a runner path, which is
what makes the handoff work: the runner's Drakar can rebuild the session from `meta` as a
relaunch does, from its own disk.

**History.** A runner session starts new, so its history before the process is empty and
`historyMark` is length 0, which is true. Everything after the spawn comes from the host's
log, as a relaunch's replay does today. No `TranscriptFollower` is started for a runner
session.

**Closing, quitting, ending.** The host already keeps a process alive with no app
attached; today's app ends an idle local session at a close or a quit
(`AgentSession.stop()`, `AgentSession.swift:1046-1064`, terminate with `forget`) only
because resuming it from its transcript costs nothing. A runner session cannot be resumed in
v1, so it is never ended that way: closing its window, closing its tab, quitting Drakar or
losing the connection **detaches** it, at work or idle, and the host keeps it. **End
Session** is the only way to end one, from its window or from its row in Home, and its
confirmation says the conversation cannot be resumed from this Mac. Home lists the runner's
detached sessions under the runner, idle ones included, and opens one's window again on a
click, reattaching from 0 and replaying, as a relaunch does. Relaunch reopens the windows of
runner sessions that had one, as it does for local sessions handed over at work. No
automatic reaping in v1: Home's runner section shows how many idle sessions the runner
holds, with **End Idle Sessions…**. *(Settled with the person: the host holds runner
sessions; nothing but End Session ends one.)*

**Capabilities.** No local `CapabilityProbe` for a runner folder (it would spawn the Mac's
`claude` in a path that does not exist here). The composer's slash commands, MCP servers and
tools come from the stream's `system`/`init` message. Until it arrives, the composer offers
none.

**Usage and models.** Rate limits and the model list the stream reports are not recorded
in the Mac's `AccountStore` (`AgentSession.swift:1360-1365`); the session shows them as
today, and they are kept on the session only. *(My call; a runner account list in the
usage view can come later.)*

**What is absent or says why**, from the sweep (file:line as of 2026-11-01):

| Control | Runner session in v1 |
|---|---|
| File sidebar, tabs, ⌘P, ⇧⌘F, save (`Workspace.swift`, `ProjectSearchView`) | Absent; the window has no sidebar. |
| Show in Finder, file links, Open in VS Code (`LinkText`, `SessionInspector`, `ProjectSidebar`, `HomeView`, `ShowInVSCode`) | Paths show as text, not links. |
| Permission sheet's Write diff against the local file (`PermissionSheet.swift:69-78`) | Shows the new content whole, labelled "on <runner>", with no diff. Edit's old/new strings still diff. |
| Fork, rename with no process, resume after exit (`Project.swift:1176-1262`, `AgentSession.swift:971-980`) | Fork absent. Rename works while the process lives (it is a control request); otherwise absent. An ended runner session leaves Home. |
| Subagent feed (`SubagentFeed.swift:54-66`) | The card shows; its feed says "on <runner>". |
| Task output tail (`TaskControls.swift:88-91`) | Asks the process, the existing fallback. |
| Moving sessions between accounts (`SessionMoves`) | Refused for runner sessions. |
| Skills manager, fan-out | Not offered for runner folders. |
| Worktree note (`ComposerView.swift:279-296`) | Absent. |
| The editor's selection in the prompt (`EditorSelection.promptContext`) | There is no editor, so none. |
| Attachments (`AttachmentIntake`) | Work as today (read on the Mac, sent inline). |
| URL elicitations (`ElicitationPanel.swift:440-444`) | Open in the Mac's browser, as today; a `localhost` callback would land on the Mac, not the runner: the panel says so for a `localhost` URL. |

## §5 Owner, and the handoff

Two Drakars attach to the runner's host: the Mac's (through the relay) and, sometimes, the
runner's own (when the person opens it over Screen Sharing, or it runs as a login item).
The host's rules hold (one app per process, `released` to the others), but its relaunch
rule would let the runner's Drakar take the Mac's sessions every time the Mac sleeps: the
ssh connection drops, the host sends `released`, and an app that is showing those sessions
read-only attaches. Hence `owner`:

- **An app does not attach on its own to a process another Mac owns**, neither at launch
  nor on `released`. The runner's Drakar shows such a session read-only, following its
  transcript (it is on the runner's disk), with "Belongs to <owner>" and a **Take over
  here** button. The Mac's app reattaches to it when it reconnects.
- **Open on the runner** (Mac, Session menu and the window's toolbar): the Mac's app sends
  `setMeta` with `owner` removed, then `detach`, and closes the session's tab (its window, if
  it was the last). The runner's Drakar, if it shows that session, attaches on `released`
  as today; if it is not running, it attaches at its next launch, also as today.
- **Bring back** (runner's Drakar, offered only on a session with an `origin`): `setMeta`
  with `owner` set to `origin`, then `detach`. The Mac's app, connected, attaches on
  `released` and opens the session's window.
- **Take over here** (runner's Drakar, on a session a Mac owns): refused by the host while
  that Mac is attached, which is the existing "no way to take a process from a running
  app". While the Mac is disconnected, it sets `owner` to absent and attaches. *(My call:
  being away must not leave a session out of reach of the person sitting at the runner.)*

**What the Mac shows of sessions it does not hold.** It has no transcript to follow, so it
opens no window for them. Home lists every process the runner's host holds, under the
runner, and a session the Mac does not hold is a row only: "on the runner" (owner absent:
handed over, taken over, or started on the runner's own Drakar), with what `list` gives
(running or ended, its name from `meta`). Clicking it says to open it on the runner. A
window the Mac had open on a session that was taken over closes its tab when it finds the
process attached elsewhere after the three-minute "still releasing" wait (§3), with a
notice. A process whose `owner` is another Mac is listed the same way.

## §6 The network promise

README's "The only connections Drakar opens of its own are Sparkle's … Everything else that
reaches the network is the `claude` or `codex` you installed" becomes "… is the `claude`,
`codex` or, once you name a runner, `ssh` you installed". SECURITY says the same, and says
that the relay is reached only through the person's own ssh login and lands in the app's own
signed binary, which is what the host checks. `scripts/audit-network.sh` gains nothing: ssh
is a spawned program, not a Drakar API. The spawn of `/usr/bin/ssh` gets the same kind of
comment the `claude` spawn has, pointing at this section.

## Setting up the runner (documentation, not code)

A page, `docs/runner.md`, for the person and for users:

- Apple Silicon, the same major macOS as the Mac (not required by Drakar; it keeps the two
  sides of a screenshot golden comparable).
- Power and sleep: `sudo pmset -a sleep 0 disksleep 0 displaysleep 0`, lid open (or a
  display dummy), battery capped.
- Logged in to the desktop at all times: automatic login, no lock, no screensaver
  password. FileVault: `sudo fdesetup authrestart` for planned reboots.
- Remote Login on; Screen Sharing on, for Open on the runner. Tailscale (or any VPN) to
  reach it away from home. In `/etc/ssh/sshd_config` (or a file in `sshd_config.d`):
  `ClientAliveInterval 30` and `ClientAliveCountMax 3`, so a relay whose Mac vanished is
  hung up within about 90 seconds (§3).
- In the runner's Drakar, Settings › Runner › "Let my other Macs start sessions here" on.
- An ssh key on the Mac that the Mac's Drakar can use without a passphrase
  (`BatchMode`), and a `~/.ssh/config` alias with `ControlMaster auto` and
  `ServerAliveInterval 30`. Optional hardening: give that key a `command=` in the runner's
  `authorized_keys` that allows only `…/Drakar --relay`.
- Drakar installed in `/Applications`, licensed, as a login item so Sparkle keeps it
  current. Claude Code installed and logged in **from the runner's desktop** (its Keychain
  item belongs to that session).
- The checkouts the runner works in, cloned there, with credentials to push (results come
  back as branches and commits, not files).
- Cupertino installed there, wired into the runner's Claude Code, with Driving set to
  "Take it straight away" and Shell to "Don't ask", since nobody sits at the runner; its
  grants given once by hand over Screen Sharing; Sparkle automatic updates off, because an
  in-place update can leave Full Disk Access stale with nobody there to toggle it.
  Cupertino's code does not change for this.

## Testing

- **The relay, without ssh.** Tests start `Drakar --relay` (the test host's own build, with
  a test host directory: the relay takes the same `--directory` the host does, and in a test
  never uses the real one) with a `socketpair`, read the facts, then drive a full
  `HostClient` session through it: spawn a fake CLI, attach, replay, detach, reconnect from
  an offset. This is the same suite the local host has, run over the relay transport.
- **`RemoteSessionHost` against a fake ssh.** `ssh` is a configurable executable; tests put a
  script there that execs the relay locally, and one that fails each way ssh fails
  (non-zero exit with a stderr message, hanging before the facts line, closing mid-stream).
- **Spawn configuration.** Unit tests on the builder: given runner facts and a Mac
  environment, the `Configuration` carries none of the Mac's environment or paths.
- **Close and quit.** An idle runner session's window closing, and a quit, send `detach`
  and never `terminate`; End Session sends `terminate` with `forget` and acknowledges.
- **Owner rules.** Unit tests over the attach decision: launch and `released`, each with
  `owner` absent, this Mac, another Mac; the handoff sequences of §5.
- **Absent controls.** The hosted suite opens a runner session against a fake runner and
  checks each row of §4's table is absent or labelled.
- **On the real runner, by hand** (recorded in the build's report): a session started from
  the Mac runs `make smoke` in a Cupertino checkout on the runner; the Mac sleeps for ten
  minutes mid-turn and catches up on wake; a permission prompt raised while the Mac slept is
  answered after; Open on the runner and Bring back, over Screen Sharing.

## Left to the builder

- The facts line's exact field names and the relay's exit codes.
- How the window looks without the sidebar, and where "on <runner>" labels sit.
- Backoff timings for reconnecting (start from the local host's).
- Whether `RemoteSessionHost` shares a protocol with `SessionHost` or is injected beside it,
  as long as sessions see the same surface they do now.
- Whether a runner session's window title carries the runner's name or a badge does.

## Risks to check first

1. **Where the runner's processes live.** Spike before anything else: from an ssh session,
   with the runner's Drakar not running, `open -g -j -a Drakar` starts it in the GUI
   session and it brings up the host; a `claude` that host spawns finds its Keychain
   credentials; a screenshot job it runs (ScreenCaptureKit, a
   UI test) is allowed, and which app macOS names in Screen Recording and Accessibility for
   it (grant it there, once). If LaunchServices will not start the app from ssh while the
   desktop is logged in, §2 needs another answer before the rest is built.
2. **The app binary as a command-line program.** `Drakar --relay` started by sshd: it must
   not touch AppKit, Sparkle or the licence before branching, must not register with
   LaunchServices as a second Drakar, and must pass `PeerSignature` (its audit token's code
   is the app's). Check with the real signed build, not Debug only.
3. **`released` on a lost ssh.** When ssh dies without a clean close, the host must see the
   relay's socket close (the relay exits on stdin EOF or SIGHUP). A relay left running with
   a dead ssh would keep the session attached to nobody reachable. Check with the network
   pulled mid-turn.
4. **Throughput.** A replay can be large (the host drops a peer leaving 512 MiB unread).
   Check that a long session's replay over ssh across Tailscale is fast enough to show the
   window in a few seconds, and that it streams rather than arriving in one piece.

## Settled with the person

- The runner is a second Apple Silicon MacBook, always on. A VM on the Mac was considered
  and set aside (it sleeps with the Mac, takes its memory, renders screenshots on a virtual
  GPU).
- The link between the Macs belongs to Drakar, not Cupertino. Cupertino on the runner is a
  regular install whose tools the runner's `claude` uses locally; nothing is added to
  Cupertino's code.
- iCloud is not the transport.
- The runner runs a regular Drakar. v1 has no editor for remote sessions; the editor is
  reached by Open on the runner, in the runner's Drakar, over Screen Sharing.
- The host holds runner sessions: closing a window or quitting detaches them, idle or not,
  and only End Session ends one.

## Departures in the build

How it works for the person is in `docs/runner.md`. Where the build differs from the text
above, the build stands:

- **An ended runner session stays in Home** as "Ended · …" until it is forgotten, against
  §4's table ("leaves Home"): the host keeps an exited process until it is acknowledged,
  and hiding it would misstate what the runner holds.
- **The runner has a stable id** (`RunnerSettings.id`, a UUID made on first save). Routes,
  project keys and `meta.runner` use it, not the name or destination. Renaming the runner
  updates its host object in place; a new destination or path retargets it in place (close
  the ssh, swap the endpoint, reconnect). Only clearing the runner closes that host, and its
  sessions end. Replacing the object on a rename would end every runner session, since a
  closed runner host is final (next item).
- **A closed runner host is final** for the sessions using it: they end, with no retry.
- **A runner session always runs under the runner's own account** (its shell's
  `CLAUDE_CONFIG_DIR`, or `~/.claude`). The spawn ignores the Mac's account pick: a Mac pick
  with the same path, such as `~/.claude`, would otherwise match and strip the runner's
  `CLAUDE_CONFIG_DIR`. The cost is no account choice for runner sessions in v1.
- **On the runner's own Drakar, a runner session is a local session.** Its replay clears
  `runner` and ignores a `meta.accountPick` that is not one of its accounts. `isOnRunner`
  means "this app reaches it through a runner endpoint", so the runner's Drakar ends such a
  session at an idle close or quit as it does any local one.
- **A version mismatch names the Mac that is behind**: "Update Drakar on <runner>" or
  "Update Drakar on this Mac". The spec assumed the runner is always the older one.
- **Turning the opt-in off leaves `runner-environment.json` in place** (0600). The relay
  refuses before reading it, and the next opt-in rewrites it.
- **An unknown listing is never "free".** While the runner is out of reach (a nil `list`),
  End Session, reconnecting and Home's rows treat a session's owner as unknown, so none of
  them takes a session another Mac may hold.
- **Tests never write `UserDefaults.standard`.** The opt-in and `RunnerSettings` read an
  injectable `UserDefaults`, and the relay takes `--defaults-suite <name>`, honoured only
  with `--directory`, so a test cannot flip the person's own Drakar settings.

## After v1

- **Transcripts from the runner** (v2): a second relay mode, `Drakar --read <path> --from
  <offset>`, over the same ssh (`ControlMaster` makes each call cheap), limited to the
  runner's account directories. It lifts resume, fork, rename after exit, subagent feeds and
  the runner's ended sessions in Home.
- **Codex on the runner**, once its history has a remote answer.
- **Scheduling**: a schedule kept on the runner, its sessions owned by the Mac so they show
  up there.
- **Files** (the editor on remote sessions), if Open on the runner turns out to be needed
  often.
