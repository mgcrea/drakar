#!/usr/bin/env bash
# Falsify Drakar's network claim:
#
#   Drakar listens on one network socket, on 127.0.0.1, which answers only a client
#   holding this launch's token, and its session host on one Unix socket, which only your
#   own Drakar can reach. The only connections Drakar opens of its own are Sparkle's, to
#   check for and fetch updates, and only once you said yes to update checks. Everything
#   else that reaches the network is the `claude` or `codex` you installed.
#
# A marketing claim CI can check is the property worth keeping (bastion's
# audit-listener.sh); this asserts the rules in Drakar/Services/IDEServer.swift's header,
# and the session host's in DrakarKit's Host/UnixSocket.swift and HostServer.swift.
# Static rules prove the code cannot be talked into misbehaving by a setting; --running
# proves the live process does not; --app proves the artifact does not carry what the
# sources say they lack, so anyone can point it at the .app they downloaded and get the
# answer CI got.
#
#   scripts/audit-network.sh            # sources
#   scripts/audit-network.sh --running  # and the running app: lsof, lock files, the token,
#                                       # the session host's socket
#   scripts/audit-network.sh --app path/to/Drakar.app
#                                       # and the built bundle: every Mach-O swept for URL
#                                       # loading, DNS and TLS, with two exact allowances
#                                       # (Sparkle's URL loading, Drakar's Network.framework
#                                       # link); Sparkle's defaults; no entitlements; the
#                                       # hardened runtime
#
# Since Sparkle landed, the sources no longer hold all the code that ships: one binary
# dependency does networking on purpose, and a symbol table is the only place that shows.
# That is why the Bundle section discovers what to audit rather than being told, and
# spells its allowances out symbol by symbol (cupertino's audit-network.sh, by way of
# armada's). It also fails on what it could not read: a sweep whose tools printed nothing
# would otherwise pass every binary.
#
# Portable on purpose (BSD and GNU tools): it runs on CI as well as on this Mac. No
# `set -e`: a check that fails must be counted and reported, not end the script early
# and green, which is the silent death cupertino's audit once recorded.
set -uo pipefail

usage() { echo "usage: scripts/audit-network.sh [--running] [--app path/to/Drakar.app]" >&2; exit 2; }
running=0
app=""
while [ $# -gt 0 ]; do
  case "$1" in
    --running) running=1 ;;
    --app)
      # A path, not the next flag: `--app --running` would otherwise audit "./--running".
      [ $# -ge 2 ] || usage
      case "$2" in "" | --*) usage ;; esac
      app="$2"
      shift ;;
    *) usage ;;
  esac
  shift
done
# Made absolute before the cd below, so a path given from anywhere still names the bundle.
case "$app" in "" | /*) ;; *) app="$PWD/$app" ;; esac

cd "$(dirname "$0")/.."
SOURCES="apps/apple/Drakar apps/apple/DrakarHost apps/apple/Packages/DrakarKit/Sources"
failures=0
checked=0

pass() { checked=$((checked + 1)); printf '  ok    %s\n' "$1"; }
fail() { checked=$((checked + 1)); failures=$((failures + 1)); printf '  FAIL  %s\n' "$1"; }
# Swift lines only, comments dropped, so a rule quoted in a comment cannot satisfy it.
code() { grep -rhE --include='*.swift' "$1" $SOURCES | grep -vE '^[[:space:]]*//'; }
count() { code "$1" | wc -l | tr -d ' '; }

echo "Sources"

n=$(count 'NWListener\(')
[ "$n" -eq 1 ] && pass "exactly one NWListener" || fail "expected one NWListener, found $n"

code 'requiredLocalEndpoint = \.hostPort\(host: \.ipv4\(\.loopback\)' >/dev/null \
  && pass "listener bound to 127.0.0.1" || fail "listener not bound to the loopback address"

code 'acceptLocalOnly = true' >/dev/null \
  && pass "non-local clients refused" || fail "acceptLocalOnly is not set"

wide=$(code '"0\.0\.0\.0"|INADDR_ANY|in6addr_any|\.ipv4\(\.any\)|\.ipv6\(\.any\)|host: "::"' | wc -l | tr -d ' ')
[ "$wide" -eq 0 ] && pass "no wildcard address anywhere" || fail "$wide wildcard address(es)"

code '"x-claude-code-ide-authorization"' >/dev/null && code 'status: \.reject' >/dev/null \
  && pass "upgrade refused without the token" || fail "no token check before the upgrade"

code 'posixPermissions: 0o600' >/dev/null && code 'posixPermissions: 0o700' >/dev/null \
  && pass "lock files created 0600, folders 0700" || fail "lock file permissions not set"

n=$(count 'socket\(AF_UNIX')
[ "$n" -eq 1 ] && pass "exactly one Unix socket, the session host's" \
  || fail "expected one socket(AF_UNIX, found $n"

inet=$(count 'socket\((AF|PF)_INET')
[ "$inet" -eq 0 ] && pass "no raw network socket" || fail "$inet socket(AF_INET...) call(s)"

code 'chmod\(directory\.path, 0o700\)' >/dev/null \
  && pass "session host folder made 0700" || fail "session host folder mode not set"

code 'chmod\(url\.path, 0o600\)' >/dev/null \
  && pass "session host socket made 0600 before it listens" \
  || fail "session host socket mode not set"

code 'LOCAL_PEERTOKEN' >/dev/null && code 'certificate leaf\[subject\.OU\]' >/dev/null \
  && code 'and identifier ' >/dev/null && code 'getpeereid' >/dev/null \
  && pass "session host lets in only the user's own Drakar (uid, identifier, team)" \
  || fail "session host peer check missing"

outgoing=$(code 'URLSession|NWConnection\((host|to):|NWBrowser|CFStreamCreatePairWithSocket|getaddrinfo' | wc -l | tr -d ' ')
[ "$outgoing" -eq 0 ] && pass "no outgoing networking API in Drakar's sources" \
  || fail "$outgoing outgoing networking call(s)"

# No entitlements, by construction rather than by an empty file (Bastion's precedent,
# PLAN.md §5). A project that cannot be read has not been checked, so it fails.
project=apps/apple/Drakar.xcodeproj/project.pbxproj
files=$(find apps/apple \( -name .build -o -name Vendor \) -prune -o -name '*.entitlements' -print)
if [ ! -f "$project" ]; then
  fail "no $project to read"
elif grep -q CODE_SIGN_ENTITLEMENTS "$project" || [ -n "$files" ]; then
  fail "an entitlements file is named or present: $(grep -o 'CODE_SIGN_ENTITLEMENTS = [^;]*' "$project" | sort -u) $files"
else
  pass "no entitlements file, none named in the project"
fi

# ─── Bundle ──────────────────────────────────────────────────────────────────
# Armada's binary sweep: `nm -u` and `otool -L` over every Mach-O in the bundle, against
# networking that no local path needs, with each exception a named row below.
#
# What it does NOT deny, deliberately: `socket`, `bind`, `connect`, `listen`. The session
# host's Unix socket shares those syscalls with anything that reaches the internet, so they
# could never be the test; the address family is, and "Sources" above asserts it (no
# AF_INET, exactly one AF_UNIX). Nor the IDE bridge's NWListener, which "Sources" pins to
# one, on 127.0.0.1, token-gated; here it is the one row for Drakar's own executable.

# High-level networking only. Every one of these implies an intent no local path has:
# loading a URL, resolving a name, negotiating TLS.
#
# DIVERGES from armada: the last three alternatives are Network.framework's outgoing
# Swift API, its NWConnection initialisers (`…cfC`/`…cfc` after a lowercase argument
# label; `NWConnection.ContentContext`'s is a nested type, upper case, and is not one),
# NWBrowser and NWConnectionGroup. Armada links no Network.framework of its own, so its
# list stops at the C API (`_nw_`). Drakar's executable has to link it, for the listener,
# and a pardon for the link without these would be a pardon for the whole framework.
DENY='URLSession|URLConnection|URLRequest|URLDownload|^_nw_|_CFHTTP|_CFURLRequest|CFReadStreamCreateForHTTP|_getaddrinfo|_gethostby|_res_9_|_SSLHandshake|_SSLCreateContext|_curl_'
DENY="$DENY"'|^_\$s7Network12NWConnectionC[0-9]+[a-z][A-Za-z0-9_]*cf[Cc]$|^_\$s7Network9NWBrowserC|^_\$s7Network17NWConnectionGroupC'

# The exceptions, in one place. Adding a line here is the whole decision, and it is a
# diff a stranger can read.
#
# Measured 2026-10-28 against the Release bundle `make bundle ALLOW_PLACEHOLDER_KEYS=1`
# builds (Sparkle 2.9.6, universal), with both rows empty, by:
#
#   find "$app/Contents" -type f | while read -r f; do
#     case "$(file -b "$f")" in *Mach-O*)
#       echo "== $f"
#       { nm -u "$f" | grep -E "$DENY"; otool -L "$f" | grep -E 'CFNetwork|/Network\.framework'; } |
#         sed 's/^[[:space:]]*//; s/ (compatibility version.*//' | sort -u ;;
#     esac
#   done
#
# which found five Mach-Os and hits in two: Sparkle's framework binary, exactly the three
# classes below, and Drakar's executable, exactly the Network.framework link. Sparkle's
# Autoupdate and Updater.app, and DrakarHost, have none, so they have no row and are swept
# like any other binary: a network symbol in one of them fails.

# Sparkle is the update checker: the one thing in this bundle that opens a connection to
# the internet. It is not even constructed until you say yes to update checks or press
# Check Now (Services/Updates.swift, UpdateController), and the claim above admits it.
SPARKLE_BIN='Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle'

# And exactly which symbols it has: the three cupertino measured and armada carries,
# measured again here, one per line. Exact both ways. A Sparkle that starts resolving
# names itself, negotiates TLS by hand or links CFNetwork directly fails this row rather
# than inheriting the allowance the previous version earned; and a row that no longer
# sees what it allows fails as stale, which is also what an `nm` that read nothing looks
# like.
#
# DIVERGES from armada, whose regex is a ceiling: a Sparkle with none of the three passed
# there, and so did a sweep whose tools printed nothing at all.
SPARKLE_ALLOWED=$(
  cat <<'SYMBOLS'
_OBJC_CLASS_$_NSMutableURLRequest
_OBJC_CLASS_$_NSURLSession
_OBJC_CLASS_$_NSURLSessionConfiguration
SYMBOLS
)

# Set to 0 for a deliberately Sparkle-free build. Left at 1, a bundle that has lost
# Sparkle is a failure rather than a quiet pass: see the stale-allowance check below.
SPARKLE_EXPECTED="${SPARKLE_EXPECTED:-1}"

# The second row. DIVERGES from armada, which has no row for its own executable: Drakar's
# links Network.framework, for the IDE bridge's NWListener and nothing else. The link
# line, its version numbers dropped (they move with the OS), and not one denied symbol:
# an outgoing NWConnection, a name lookup or a URL load in Drakar itself still fails. Exact
# both ways too, so an `otool` that read nothing fails here.
DRAKAR_BIN='Contents/MacOS/Drakar'
DRAKAR_ALLOWED='/System/Library/Frameworks/Network.framework/Versions/A/Network'

FEED_URL='https://drakar.mgcrea.io/appcast.xml'

# Every Mach-O in the bundle, FOUND rather than listed: a framework or helper that nobody
# remembered to add to a hand-written list is precisely what this gate exists to catch.
mach_o_paths() {
  find "$1/Contents" -type f -print0 2>/dev/null |
    while IFS= read -r -d '' f; do
      case "$(file -b "$f" 2>/dev/null)" in
        *Mach-O*) printf '%s\n' "${f#"$1/"}" ;;
      esac
    done | LC_ALL=C sort
}

# The hits for one binary, or, when `nm` or `otool` could not read it, the tool's first
# line of complaint and a non-zero status. Without the status an unreadable binary and a
# clean one print the same nothing, and on a Mac without the Command Line Tools every
# binary would pass. sort -u because nm lists undefined symbols once per architecture
# slice, and a universal binary would otherwise report every hit twice.
scan() {
  syms=$(nm -u "$1" 2>/dev/null) || { echo "nm -u: $(nm -u "$1" 2>&1 >/dev/null | head -1)"; return 1; }
  libs=$(otool -L "$1" 2>/dev/null) || { echo "otool -L: $(otool -L "$1" 2>&1 >/dev/null | head -1)"; return 1; }
  {
    printf '%s\n' "$syms" | grep -E "$DENY"
    printf '%s\n' "$libs" | grep -E 'CFNetwork|/Network\.framework'
  } | sed 's/^[[:space:]]*//; s/ (compatibility version.*//' | grep -v '^$' | sort -u
  return 0
}

# The lines of $1 that are not lines of $2, exactly. An empty $2 holds nothing, so all of
# $1 comes back: `grep -F` with an empty pattern would match every line instead.
lines_not_in() {
  if [ -z "$2" ]; then
    printf '%s\n' "$1" | grep -v '^$'
  else
    printf '%s\n' "$1" | grep -v '^$' | grep -vxF "$2"
  fi
}

if [ -n "$app" ]; then
  echo "Bundle"
  if [ ! -d "$app/Contents" ]; then
    fail "no bundle at $app (make bundle builds one)"
  else
    paths=$(mach_o_paths "$app")
    binaries=$(printf '%s\n' "$paths" | grep -c .)
    saw_sparkle=0
    saw_drakar=0
    printf '%s\n' "$paths" | grep -xF "$SPARKLE_BIN" >/dev/null && saw_sparkle=1
    printf '%s\n' "$paths" | grep -xF "$DRAKAR_BIN" >/dev/null && saw_drakar=1

    # A gate that passed having swept nothing is not a gate: no Mach-O means no build.
    [ "$binaries" -gt 0 ] || fail "no Mach-O found under $app"

    # A pardon that outlives the thing it pardons is a hole waiting for whatever lands at
    # that path next. If Sparkle is ever dropped, the allowance has to go with it, and the
    # way to guarantee that is to fail until it does. Drakar's own executable has no
    # switch: a bundle without it is not Drakar.
    if [ "$SPARKLE_EXPECTED" = 1 ] && [ "$saw_sparkle" -eq 0 ]; then
      fail "$SPARKLE_BIN: the allowance names a binary this bundle does not contain"
    fi
    [ "$saw_drakar" -eq 1 ] || fail "$DRAKAR_BIN: not in this bundle"

    # The tools, tried once on a binary every Mac has, before anything is read with them.
    # On a Mac without the Command Line Tools, `nm` and `otool` are shims that print
    # "xcrun: error: invalid active developer path" and exit non-zero; read with 2>/dev/null
    # they would say every binary was clean.
    probe=/bin/ls
    if nm -u "$probe" 2>/dev/null | grep '^_' >/dev/null \
      && otool -L "$probe" 2>/dev/null | grep 'libSystem' >/dev/null; then
      tools=1
    else
      tools=0
      fail "nm and otool cannot read $probe ($( { nm -u "$probe" || otool -L "$probe"; } 2>&1 >/dev/null | head -1)): install the Command Line Tools (xcode-select --install); the sweep was not run"
    fi

    if [ "$tools" -eq 1 ]; then while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if ! hits=$(scan "$app/$rel"); then
        fail "$rel could not be read, so it was not checked: $hits"
        continue
      fi
      # The allowance is exact, not a blanket pardon for a path, and not a ceiling either.
      case "$rel" in
        "$SPARKLE_BIN")
          allowed=$SPARKLE_ALLOWED
          what="reaches the network: Sparkle's updates, once you said yes" ;;
        "$DRAKAR_BIN")
          allowed=$DRAKAR_ALLOWED
          what="links Network.framework for the loopback listener, and opens nothing outgoing" ;;
        *)
          allowed=""
          what="" ;;
      esac
      unexpected=$(lines_not_in "$hits" "$allowed")
      stale=$(lines_not_in "$allowed" "$hits")
      if [ -n "$unexpected" ]; then
        n=$(printf '%s\n' "$unexpected" | wc -l | tr -d ' ')
        fail "$rel reaches the network ($n symbol(s)):"
        printf '%s\n' "$unexpected" | head -8 | sed 's/^/          /'
        [ "$n" -gt 8 ] && printf '          … and %s more\n' "$((n - 8))"
      elif [ -n "$stale" ]; then
        fail "$rel no longer has what its allowance names (a stale row, or a tool that read nothing):"
        printf '%s\n' "$stale" | sed 's/^/          /'
      elif [ -n "$what" ]; then
        pass "$rel $what"
      else
        pass "$rel: no URL loading, no DNS, no TLS"
      fi
    done <<EOF
$paths
EOF
    fi

    # The sweep says the capability exists. These say it is switched off and points where
    # the claim says, which turns "once you said yes" from a promise in a settings pane into
    # something the release refuses to ship without.
    if [ "$saw_sparkle" -eq 1 ]; then
      plist="$app/Contents/Info.plist"
      # Absent is not the same as false: an ABSENT SUEnableAutomaticChecks is what makes
      # Sparkle ask on its own, in its own words, which the consent card on Home replaces;
      # an ABSENT SUAllowsAutomaticUpdates leaves Sparkle's update window offering to
      # download and install updates automatically, which SECURITY.md says it never does.
      for pair in SUEnableAutomaticChecks=false SUAutomaticallyUpdate=false \
        SUAllowsAutomaticUpdates=false SUSendProfileInfo=false "SUFeedURL=$FEED_URL"; do
        key=${pair%%=*}
        want=${pair#*=}
        got=$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)
        [ "$got" = "$want" ] && pass "$key is $want" || fail "$key is ${got:-absent}, must be $want"
      done
      # DIVERGES from armada: SUPublicEDKey's shape is not asserted here. It is about which
      # update Sparkle trusts, not whether Drakar reaches the network, and `make sign`
      # already refuses a bundle without a real one (ALLOW_PLACEHOLDER_KEYS=1 aside, the
      # rehearsal this audit also has to read).

      # Sandbox-only, and Drakar is not sandboxed. Stripped by `make sparkle` because each
      # one is another binary that would need pardoning here.
      [ -d "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" ] \
        && fail "Sparkle's sandbox-only XPC services ship" || pass "Sparkle's XPC services stripped"
    fi

    # DIVERGES from armada, whose one entitlement is the microphone: Drakar ships none, on
    # anything (Bastion's precedent; `make sign` refuses while an .entitlements file
    # exists). Read off every Mach-O found, not just the app, since a helper's signature
    # grants its own. An unsigned binary has none to show, which is the claim, so that
    # reads as none (the hardened-runtime check below fails it); any other error from
    # codesign is a signature that was not read, and fails.
    #
    # And the hardened runtime, on every one: `make sign` passes `--options runtime`, and
    # SECURITY.md says it ships on. Not in armada's audit, which leaves it to its sign step.
    granted=0
    unread=0
    hardened=0
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if out=$(codesign -d --entitlements - --xml "$app/$rel" 2>&1); then
        keys=$(printf '%s\n' "$out" | grep -o '<key>[^<]*</key>')
        if [ -n "$keys" ]; then
          granted=$((granted + 1))
          fail "$rel carries entitlements:"
          printf '%s\n' "$keys" | sed 's/^/          /'
        fi
      else
        case "$out" in
          *"not signed at all"*) ;;
          *)
            unread=$((unread + 1))
            fail "$rel: codesign could not read its entitlements: $(printf '%s\n' "$out" | tail -1)" ;;
        esac
      fi
      # Read whole, then matched: `codesign | grep -q` under pipefail reads as a failure
      # whenever grep stops early and codesign takes the SIGPIPE.
      info=$(codesign -dv "$app/$rel" 2>&1)
      if printf '%s\n' "$info" | grep -E 'flags=0x[0-9a-f]*\([^)]*runtime' >/dev/null; then
        hardened=$((hardened + 1))
      else
        fail "$rel is not signed with the hardened runtime"
      fi
    done <<EOF
$paths
EOF
    [ "$granted" -eq 0 ] && [ "$unread" -eq 0 ] && [ "$binaries" -gt 0 ] \
      && pass "no entitlements in any signature"
    [ "$hardened" -gt 0 ] && [ "$hardened" -eq "$binaries" ] \
      && pass "hardened runtime on all $hardened"
  fi
fi

if [ "$running" -eq 1 ]; then
  echo "Running app"
  pid=$(pgrep -x Drakar | head -1)
  if [ -z "$pid" ]; then
    fail "Drakar is not running"
  else
    listening=$(lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $9}')
    if [ -z "$listening" ]; then
      fail "no listening socket (is a session window open, or the scope set to Never?)"
    else
      bad=$(printf '%s\n' "$listening" | grep -v '^127\.0\.0\.1:' | wc -l | tr -d ' ')
      [ "$bad" -eq 0 ] && pass "listening only on 127.0.0.1 ($listening)" \
        || fail "listening beyond loopback: $listening"
    fi

    locks=$(grep -l '"ideName":"Drakar"' "$HOME"/.claude/ide/*.lock "$HOME"/.claude-*/ide/*.lock 2>/dev/null \
      | while read -r f; do grep -q "\"pid\":$pid[,}]" "$f" && echo "$f"; done)
    if [ -z "$locks" ]; then
      fail "no lock file for pid $pid"
    else
      for f in $locks; do
        mode=$(perl -e 'printf "%o", (stat shift)[2] & 07777' "$f")
        dmode=$(perl -e 'printf "%o", (stat shift)[2] & 07777' "$(dirname "$f")")
        # The token's secrecy is the file's 0600. The folder may predate Drakar (another
        # editor or the CLI made it, often 0755) and is left as it is; what it must not be
        # is writable by anyone else, who could then swap a lock file.
        others_write=$(( 0$dmode & 022 ))
        [ "$mode" = 600 ] && [ "$others_write" -eq 0 ] \
          && pass "$f is 0600, in a folder only its owner can write ($dmode)" \
          || fail "$f is $mode in a $dmode folder"
      done
      lock=$(printf '%s\n' "$locks" | head -1)
      port=$(basename "$lock" .lock)
      token=$(perl -ne 'print $1 if /"authToken":"([^"]+)"/' "$lock")
      upgrade() {
        curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
          -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
          -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Protocol: mcp' \
          "$@" "http://127.0.0.1:$port/"
      }
      without=$(upgrade)
      wrong=$(upgrade -H 'x-claude-code-ide-authorization: not-the-token')
      with=$(upgrade -H "x-claude-code-ide-authorization: $token")
      [ "$without" != 101 ] && [ "$wrong" != 101 ] \
        && pass "upgrade refused without the token ($without) and with a wrong one ($wrong)" \
        || fail "upgrade accepted without the right token ($without, $wrong)"
      [ "$with" = 101 ] && pass "upgrade accepted with the token" \
        || fail "upgrade refused with the token ($with)"
    fi
  fi
fi

if [ "$running" -eq 1 ]; then
  echo "Session host"
  # Started on demand, so often not running; when it is, its socket must be the user's alone.
  socket="$HOME/Library/Application Support/io.mgcrea.Drakar/host/host-v1.sock"
  if [ ! -S "$socket" ]; then
    printf '  skip  no session host socket at %s\n' "$socket"
  else
    mode=$(perl -e 'printf "%o", (stat shift)[2] & 07777' "$socket")
    owner=$(perl -e 'print +(stat shift)[4]' "$socket")
    dmode=$(perl -e 'printf "%o", (stat shift)[2] & 07777' "$(dirname "$socket")")
    [ "$mode" = 600 ] && [ "$owner" = "$(id -u)" ] \
      && pass "session host socket is 0600 and the user's" \
      || fail "session host socket is $mode, owned by uid $owner"
    [ "$dmode" = 700 ] && pass "session host folder is 0700" \
      || fail "session host folder is $dmode"
  fi
  for host in $(pgrep -x DrakarHost); do
    network=$(lsof -nP -a -p "$host" -i 2>/dev/null | awk 'NR > 1' | wc -l | tr -d ' ')
    [ "$network" -eq 0 ] && pass "session host $host has no network socket" \
      || fail "session host $host has $network network socket(s)"
  done
fi

# A gate that passes when it inspected nothing is not a gate.
[ "$checked" -gt 0 ] || { echo "nothing was checked"; exit 1; }
echo "$checked checked, $failures failed"
[ "$failures" -eq 0 ]
