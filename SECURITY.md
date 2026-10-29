# Security

Drakar runs the `claude` or `codex` you installed on your files, with your accounts, and
answers the terminal `claude` sessions that ask it for your editor's selection. A hole in it
is a hole in everything those sessions can touch. Reports are welcome and answered.

## Reporting

Email **security@mgcrea.io**. Do not open a public issue for something exploitable.

Include the version (Settings › Updates shows it, with the build number, which is the
commit count of the tree it was built from), what you did, and what you expected to be
refused. A proof of concept against your own machine is ideal; one against somebody
else's is not needed and not wanted.

## What Drakar claims

Drakar listens on one network socket, on 127.0.0.1, which answers only a client holding
this launch's token, and its session host on one Unix socket, which only your own Drakar
can reach. The only connections Drakar opens of its own are Sparkle's, to check for and
fetch updates, and only once you said yes to update checks. Everything else that reaches
the network is the `claude` or `codex` you installed.

In detail:

- **The listener is the IDE bridge**, for `claude --ide` in a terminal. It is bound to
  `127.0.0.1` and refuses non-local clients, and it refuses the WebSocket upgrade to any
  client without the token written, 0600, into the lock file Claude Code reads.
- **The session host's socket** is a Unix socket in a 0700 folder, made 0600 before it
  listens, and it lets in only a peer running as you, signed with Drakar's identifier by
  Drakar's team.
- **The update check is Sparkle's**, and it does not exist until you answer yes on Home or
  in Settings › Updates, or press Check Now there: before that the updater is never
  constructed. A check reads one file, `drakar.mgcrea.io/appcast.xml`, and sends no
  identifier with it: not your licence key, not a machine id. When it finds a release and
  you choose to install it, Sparkle downloads that release's `Drakar.zip` from GitHub
  (`github.com/mgcrea/drakar/releases/download/…`), and installs it only if it carries
  Drakar's own EdDSA signature. It always asks before installing: the shipped Info.plist
  turns automatic installs off and takes away Sparkle's option to turn them on
  (`SUAllowsAutomaticUpdates` is false), and profile reporting is off.
- **No licence call.** A licence key is checked on this Mac, against a public key built
  into the app, and the trial is counted on this Mac too.
- **No entitlements, no sandbox.** Drakar spawns `claude` and `codex`, which work on your
  files and read their own settings in your home folder, and App Sandbox would hand every
  child its container. So it ships
  with the hardened runtime and no entitlements at all, on the app or on any helper.

## Checking it yourself

`scripts/audit-network.sh` exists to falsify that claim, and CI runs it on every release.
From a checkout of this repository (it needs Xcode's command-line tools for `nm`, `otool`
and `codesign`):

```sh
scripts/audit-network.sh                          # the sources
scripts/audit-network.sh --app /Applications/Drakar.app
                                                  # and the bundle you downloaded
scripts/audit-network.sh --running                # and the Drakar running now
```

- **The sources** (`make audit`): exactly one `NWListener`, bound to the loopback address
  with non-local clients refused and no wildcard address anywhere; the token check before
  the upgrade; exactly one Unix socket and no internet one; the session host's folder and
  socket modes and its peer check; no outgoing networking API (`URLSession`,
  `NWConnection` to a host, `NWBrowser`, `getaddrinfo`); no entitlements file.
- **The bundle** (`make audit-release` on the release build): every Mach-O in it, found
  rather than listed, swept with `nm -u` and `otool -L` for URL loading, name lookup and
  TLS, and for Network.framework's outgoing API. A binary the tools could not read fails,
  and so does a Mac without the Command Line Tools, rather than reading as clean. The two
  exceptions are named in the script, each matched exactly both ways against the symbols
  it was measured to use: Sparkle's framework, the three URL-loading classes it needs to
  fetch the appcast and the update; and Drakar's own executable, its link to
  Network.framework for the listener and nothing outgoing. A bundle that has lost Sparkle
  or Drakar's executable fails rather than keeping the pardon. Then Sparkle's defaults in
  the shipped Info.plist (no automatic checks, no automatic installs and no option to turn
  them on, no profile, that one feed), its sandbox-only XPC services stripped, no
  entitlements in any signature, and the hardened runtime on every binary.
- **The running app** (`make audit-running`): it listens only on `127.0.0.1`; its lock
  files are 0600 in a folder no one else can write; the upgrade is refused without the
  token or with a wrong one, and accepted with it; the session host's socket is 0600, in a
  0700 folder, and the session host holds no network socket.

A failure in any of them is the claim being false, and worth a report.

## Not in scope

- **What `claude` does.** It talks to Anthropic, and to whatever your MCP servers and
  tools reach, on your own sign-in: that is the program's job. Drakar spawns it unmodified
  and reads its answers. This audits Drakar, not the program it runs.
- **What `codex` does.** The same, for OpenAI: Drakar starts your own `codex app-server`
  for a Codex session, unmodified, and reads its answers. It talks to OpenAI, and to
  whatever your MCP servers and tools reach, on your own sign-in.
- **Other programs running as you.** They can already read every transcript and rewrite
  every config directly, so nothing in Drakar changes their reach.

## Supported versions

Only the newest release is supported. Fixes ship in the next release rather than being
back-ported, and the update check offers that release to every earlier build that checks.
Report against the newest release or `main`.
