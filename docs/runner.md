# Sessions on another Mac

Some work takes over a screen: a screenshot run, a `make` target that drives the UI, a
session that clicks through apps with Cupertino. On the Mac you work on, it has to wait until
you stop typing, since a keystroke ruins the run and the run takes your keyboard, and it stops
when the laptop sleeps. A second Mac kept on, **the runner**, can take it instead. From your
Mac, Drakar starts a Claude Code session in a folder on the runner: its `claude` runs there,
in a checkout there, with the runner's MCP servers, so Cupertino's tools drive the runner's
screen; you follow the conversation, answer its prompts and send yours from your Mac, and
nothing moves on your screen. Results come back the way they would from a colleague's
machine: as commits and branches it pushes.

Names used here: **the Mac** is yours, where you work; **the runner** is the other one. Both
run a regular, signed Drakar. The design behind it is
`docs/superpowers/specs/2026-11-01-remote-sessions-design.md`.

## How the Mac reaches the runner

Nothing of this runs until you name a runner on the Mac, and the runner takes nothing until
someone at the runner turns its opt-in on.

1. The Mac's Drakar runs your own ssh:
   `/usr/bin/ssh -T -o BatchMode=yes <destination> <path>/Contents/MacOS/Drakar --relay`.
   Your `~/.ssh/config` supplies everything else (keys, host names, multiplexing), and Drakar
   writes nothing in `~/.ssh`. `BatchMode` because nobody is there to type a passphrase.
2. On the runner, that ssh login runs Drakar's own binary as **the relay**. It does nothing
   unless "Let my other Macs start sessions here" is on in the runner's Settings › Runner:
   off, it says so on stderr, which the Mac shows, and exits (64).
3. If no session host answers on the runner, the relay asks macOS to open Drakar there,
   hidden and in the background (`/usr/bin/open -g -j -a`), in the desktop session someone
   is logged in to. That Drakar, with the opt-in on, starts its host. The relay never starts
   the host itself: a host started under ssh, and every `claude` it ran, would be cut off from
   the login Keychain where Claude Code keeps its sign-in, and from the screen. It waits 15
   seconds for the host, then gives up and says why.
4. The relay sends the Mac one line of facts (Drakar's version there, the runner's home, user
   and hostname, its desktop's environment, the `claude` it finds, its Claude Code account
   folders), then copies bytes between ssh and the host's socket until either side closes. The
   host lets it in by the same check it gives the app: it runs as you and is signed as
   Drakar, by Drakar's team.

## Setting up the runner

**The machine.** An Apple Silicon Mac, ideally on the same major macOS as the Mac. Drakar
does not need that; it keeps screenshots from both sides comparable.

**Awake at all times.**

```sh
sudo pmset -a sleep 0 disksleep 0 displaysleep 0
```

With the lid open, or a display dummy plugged in, since a closed laptop with no display
sleeps anyway. It stays plugged in, so cap its charge if you can.

**Logged in to the desktop at all times.** Sessions run in the desktop session, not in ssh's,
so somebody must be logged in there: automatic login (System Settings › Users & Groups), no
lock, no screen saver password. FileVault turns automatic login off; restart for planned
reboots with `sudo fdesetup authrestart`, which unlocks the disk at the next start without
anyone typing there (check once, over Screen Sharing, that it comes back to the desktop).
After an unplanned restart the runner waits at the FileVault login until someone types the
password.

**Reachable.** In System Settings › General › Sharing, turn on Remote Login, and Screen
Sharing for the times you need the runner's own Drakar (see "Handing a session over" below).
To reach it away from home, Tailscale or any VPN. Then have the runner's sshd hang up on a
Mac that vanished, in a file of its own, `/etc/ssh/sshd_config.d/drakar.conf`:

```
ClientAliveInterval 30
ClientAliveCountMax 3
```

When the network drops without a clean close, the runner's relay stays attached to the
session until sshd notices, and the Mac cannot take the session back before then. With these
two lines that is about 90 seconds; the Mac shows the session as reconnecting meanwhile.

**One macOS account.** ssh logs in as the user who is logged in to the runner's desktop. The
host, its socket, the opt-in and the sessions all belong to that user, and the host lets in
nobody else.

**Drakar**, in `/Applications` (or give its path on the Mac, below), licensed, and a login
item (System Settings › General › Login Items) so it is up after a restart and Sparkle keeps
it current. Then, in its Settings › Runner, turn on **Let my other Macs start sessions
here**. This is the runner's consent: a Mac whose ssh key reaches the runner still cannot use
it until someone at the runner said yes. While it is on and Drakar runs, Drakar keeps its
session host up, and at each launch records its desktop's environment (the `PATH` and the
rest its login shell sets), which is what the runner's sessions get, in
`runner-environment.json` beside the host's folder in
`~/Library/Application Support/io.mgcrea.Drakar/`. Without that file the relay reads a login
shell from ssh instead, and the Mac's Test says to open Drakar on the runner once.

The two Drakars must speak the same protocol. When they do not, Settings and Home on the Mac
say which Mac to update.

**Claude Code**, installed and logged in **from the runner's desktop**, in Terminal there
(over Screen Sharing if need be), not over ssh: its sign-in goes into that session's login
Keychain. A runner session runs the first `claude` the runner's environment finds, under the
account that environment names: its `CLAUDE_CONFIG_DIR`, or `~/.claude` on the runner. The
Mac's account picks do not apply there. The Mac's Test lists the `claude` and the accounts it
found.

**The checkouts** the runner works in, cloned there, with credentials to push. Since its
sessions get the desktop's environment, a `git push` uses the desktop's ssh agent.

**Cupertino**, if the sessions drive apps: installed on the runner and added to the runner's
Claude Code, with its grants given once by hand over Screen Sharing. Nobody sits at the
runner, so nothing should wait for an answer there:

- Desktop's (and Simulator's, the same setting) **Before driving**: **Nothing**.
- Shell on, with **Before running**: **Don't ask**.
- Settings › Updates › **Check for updates automatically** off. An update in place can leave
  Full Disk Access stale, with nobody there to turn it off and on again. Update it by hand,
  over Screen Sharing.

## Setting up the Mac

**An ssh key Drakar can use without asking.** `BatchMode` means ssh asks for nothing, so the
key needs no passphrase, or must already be in the ssh agent. A key of its own for this is
simplest, and it is what the hardening below needs:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_drakar -N "" -C "drakar@$(hostname -s)"
ssh-copy-id -i ~/.ssh/id_ed25519_drakar.pub you@runner.local
```

**An alias** in `~/.ssh/config`:

```
Host runner
  HostName runner.your-tailnet.ts.net
  User you
  IdentityFile ~/.ssh/id_ed25519_drakar
  IdentitiesOnly yes
  ControlMaster auto
  ControlPath ~/.ssh/drakar-%C
  ServerAliveInterval 30
```

`ServerAliveInterval` has ssh notice a network that went away. `ControlMaster` lets Test ride
the connection already open; its `ControlPath` is Drakar's own, so that an `ssh` to the same
host under another alias never shares it. Check it from Terminal with
`ssh -T -o BatchMode=yes runner true`, which must return without asking anything. Once the
key is tied to the relay (below), that runs the relay instead of `true`: it prints the
runner's facts line and waits (Control-C ends it); or it prints the facts line, finds no
session host within 15 seconds, says so and exits with 69; or, with the opt-in off, it says
so and exits with 64.

**Settings › Runner › Use a runner.** The ssh destination (the alias, or anything ssh takes,
such as `you@runner.local`), the path to Drakar on the runner (`/Applications/Drakar.app`
unless you put it elsewhere; a path starting `~/` is the runner's home), and a name to show,
which defaults to the runner's hostname. **Test** connects and shows what the runner said:
its Drakar, its `claude` and their versions, its accounts. A failure shows ssh's own words
(a host key changed, a key refused, no Drakar at that path) or the relay's (the opt-in off,
no host within 15 seconds). **Save** keeps the runner, and the Mac stays connected to it while
Drakar runs. An empty destination is no runner.

## Tying the key to the relay (optional)

On the runner, `~/.ssh/authorized_keys` can tie the Mac's Drakar key to the relay, so that
it opens no login shell, no terminal and no forwarding. That narrows how the key is used,
not what it can do. **Treat it as a login key for the runner.** Through the relay it reaches
the session host, and the host starts whatever program a client asks for (it is how Drakar
starts `claude`, and it checks nothing about the program), so whoever holds the key can run
any program on the runner as you, `/bin/sh` included.

```
command="/Applications/Drakar.app/Contents/MacOS/Drakar --relay",restrict ssh-ed25519 AAAA… drakar@my-mac
```

sshd runs the `command=` through your login shell in place of whatever the Mac asked for.
What the Mac asked for is in `$SSH_ORIGINAL_COMMAND`, and nothing needs to read it: the Mac
sends `<path>/Contents/MacOS/Drakar --relay`, with the path in single quotes when it holds a
space or another character the shell would split on, and a leading `~/` left unquoted for
the shell to expand, so a check of it would have to follow that quoting. The forced command
already runs the relay and nothing else. Write its path as a shell reads it:
`command="'/Applications/My Tools/Drakar.app/Contents/MacOS/Drakar' --relay"` for a path with a
space in it, `command="~/Applications/Drakar.app/Contents/MacOS/Drakar --relay"` for one in
your home. `restrict` turns off forwarding and the terminal, which the relay needs neither of
(the Mac asks for no terminal: `-T`).

Use this key for Drakar alone: a forced command on the key you log in with would make every
login with it a relay. That is also why the alias above names its key with `IdentitiesOnly`
and has a `ControlPath` of its own.

## Using it

**Starting a session.** File › New Session on Runner… asks for a folder on the runner, typed,
with the runner's recent folders below. A folder that does not exist there fails on the
runner, and its refusal is shown. A runner session is Claude Code only and starts new: no
Codex, no resuming a conversation, no fork.

**Its window** shows the conversation only: prompts, the streamed answer, tool calls,
permission prompts and questions, interrupt, model, mode and effort. It has no file sidebar
and no editor, and its paths are text, not links, since they are the runner's. The toolbar
shows the runner and its usage in place of an account picker.

**Closing it, quitting Drakar, the Mac sleeping or losing the network** leaves the session
working on the runner. When Drakar is back and reaches the runner, it attaches again and
replays what happened meanwhile; a permission prompt raised while the Mac slept is waiting
there to be answered. **End Session**, from its window or its row in Home, is the only way to
end one, and the conversation cannot be resumed from the Mac after.

**Home** lists the runner's sessions under the runner, apart from local projects: open in
Drakar, with no window, on the runner (the runner's own Drakar's, or another Mac's), or
ending. Clicking one with no window opens it again. **End Idle Sessions…**
ends this Mac's sessions that no window shows, working or not, since the runner keeps every
session until it is ended: a run left going with its window closed is one of them.

## Handing a session over

The runner's own Drakar, over Screen Sharing, has what the Mac's window leaves out: the file
tree and the editor.

- **Open on the Runner** (Session menu, and the window's toolbar) hands the shown session to
  Drakar on the runner and closes it on the Mac. The Mac lists it in Home as on the runner.
- **Bring Back to <Mac>**, in the runner's Drakar, gives it back to the Mac that started it.
  A window the Mac has open on that folder takes it at once; otherwise Home on the Mac lists
  it, to open with a click.
- A session the Mac holds shows read-only in the runner's Drakar, "Belongs to <Mac>", with
  **Take Over Here**. That works once that Mac lets it go or loses its connection, so that
  someone at the runner can carry on with a session whose Mac is away.

Once a session is the runner's own Drakar's, opened on the runner or taken over there, that
Drakar treats it as one of its own local sessions: closing its tab there ends it, and so does
closing its window or quitting while it is idle. Its conversation can be resumed on the
runner like any other, but no longer from the Mac. Bring it back first if the Mac should keep
it.

**Renaming the Mac.** A runner session records the Mac that started it and the Mac that holds
it by that Mac's name (System Settings › General › Sharing). Renamed while it holds sessions
on the runner, the Mac no longer finds them its own: each of their tabs closes as taken over,
and Bring Back in the runner's Drakar sends them to the old name, which no Mac answers to.
Rename it with no runner sessions held, or carry on with them in the runner's Drakar after
(Take Over Here).

## What v1 leaves out

The editor and file links in a runner session's window (use Open on the Runner); resuming,
forking or renaming a session after its process ends, since the runner's transcripts are not
on the Mac; subagent feeds, whose cards say they are on the runner; Codex; choosing a Claude
Code account for a session; more than one runner; and scheduling.
