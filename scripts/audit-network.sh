#!/usr/bin/env bash
# Falsify Drakar's network claim:
#
#   Drakar opens one socket, a listener on 127.0.0.1 that answers only a client holding
#   this launch's token, and makes no connection of its own. Everything that reaches the
#   network is the `claude` you installed.
#
# A marketing claim CI can check is the property worth keeping (bastion's
# audit-listener.sh); this asserts the rules in Drakar/Services/IDEServer.swift's header.
# Static rules prove the code cannot be talked into misbehaving by a setting; --running
# proves the live process does not.
#
#   scripts/audit-network.sh            # sources
#   scripts/audit-network.sh --running  # and the running app: lsof, lock files, the token
#
# Portable on purpose (BSD and GNU tools): it runs on CI as well as on this Mac. No
# `set -e`: a check that fails must be counted and reported, not end the script early
# and green, which is the silent death cupertino's audit once recorded.
set -uo pipefail

cd "$(dirname "$0")/.."
SOURCES="apps/apple/Drakar apps/apple/Packages/DrakarKit/Sources"
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

outgoing=$(code 'URLSession|NWConnection\((host|to):|NWBrowser|CFStreamCreatePairWithSocket|getaddrinfo' | wc -l | tr -d ' ')
[ "$outgoing" -eq 0 ] && pass "no outgoing networking API in Drakar's sources" \
  || fail "$outgoing outgoing networking call(s)"

if [ "${1:-}" = "--running" ]; then
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

# A gate that passes when it inspected nothing is not a gate.
[ "$checked" -gt 0 ] || { echo "nothing was checked"; exit 1; }
echo "$checked checked, $failures failed"
[ "$failures" -eq 0 ]
