#!/usr/bin/env bash
# What changed in the VS Code extension's UI since we last looked.
#
# The extension's look is Drakar's design reference (PLAN.md §2.2) and it ships every few
# days. This extracts what a release can change about its UX, from the installed copy,
# and diffs it against the snapshot committed in docs/extension-surface/:
#
#   requests.txt     what the webview asks its host to do (`accept_diff`, `rewind_code`):
#                    the literals in both webview/index.js (`type:"…"`) and extension.js
#                    (`case"…"`). One per feature, the list docs/extension-parity.md tracks.
#   cli-requests.txt the control requests `claude` accepts, as the Agent SDK bundled in
#                    extension.js sends them (`this.request({subtype:"…"})`). Most features
#                    are a thin wrapper over one; some the extension never calls
#                    (`ultrareview_launch`). The ledger's "CLI control requests" section
#                    tracks these too.
#   strings.txt      the webview's UI copy (quoted strings that start with a capital and
#                    hold a space). Noisy in absolute terms (Monaco's own strings are in
#                    it), quiet between releases, which is all a diff needs.
#   contributes.txt  package.json's commands, keybindings, settings and views.
#   settings.txt     every key path in claude-code-settings.schema.json.
#
# The snapshot is committed rather than cached because VS Code deletes an old version's
# folder soon after updating: the last reviewed version must outlive it. Several releases
# between two reviews diff as one span.
#
#   scripts/extension-surface.sh           # diff the newest installed version, check the ledger
#   scripts/extension-surface.sh --accept  # make it the snapshot (after updating the ledger)
#   scripts/extension-surface.sh DIR       # use this extension folder (either mode)
#
# Exit 0 when nothing changed and every request has a ledger row, 1 otherwise, 2 when no
# extension is found. Needs jq (in macOS since 15). Portable on purpose (BSD and GNU tools).
set -uo pipefail
export LC_ALL=C

cd "$(dirname "$0")/.."
SNAPSHOT=docs/extension-surface
LEDGER=docs/extension-parity.md

accept=0
ext=""
for arg in "$@"; do
  case "$arg" in
    --accept) accept=1 ;;
    -h | --help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ext="$arg" ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

# The newest anthropic.claude-code-* by its package.json version, not by folder name:
# a lexical sort puts 2.1.99 after 2.1.310.
if [ -z "$ext" ]; then
  root="${VSCODE_EXTENSIONS:-$HOME/.vscode/extensions}"
  ext=$(for d in "$root"/anthropic.claude-code-*; do
    [ -f "$d/package.json" ] && printf '%s %s\n' "$(jq -r .version "$d/package.json")" "$d"
  done | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | cut -d' ' -f2-)
fi
[ -n "$ext" ] && [ -f "$ext/webview/index.js" ] || {
  echo "no Claude Code extension found${ext:+ at $ext} (set VSCODE_EXTENSIONS or pass its folder)" >&2
  exit 2
}

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

jq -r .version "$ext/package.json" >"$out/VERSION"

literals() { grep -oE "$1\"[a-z]+(_[a-z0-9]+)+\"" "$2" | sed "s/^$1\"//; s/\"\$//" | sort -u; }
literals 'type:' "$ext/webview/index.js" >"$out/webview-types"
literals 'case' "$ext/extension.js" >"$out/host-cases"
comm -12 "$out/webview-types" "$out/host-cases" >"$out/requests.txt"
rm "$out/webview-types" "$out/host-cases"

grep -oE 'request\(\{subtype:"[a-z_]+"' "$ext/extension.js" | sed 's/.*subtype:"//; s/"$//' \
  | sort -u >"$out/cli-requests.txt"

grep -oE '"[A-Z][^"\\<>{}=]{4,160}"' "$ext/webview/index.js" | grep ' ' | grep -v '  ' \
  | sed 's/^"//; s/"$//' | sort -u >"$out/strings.txt"

jq -r '.contributes
  | (.commands[]? | "command \(.command)  \(.title)"),
    (.keybindings[]? | "key \(.command)  \(.mac // .key)\(if .when then "  when \(.when)" else "" end)"),
    (.configuration | if type == "array" then .[] else . end | .properties // {} | to_entries[]
      | "setting \(.key)  \(.value.type // "")  default \(.value.default | tojson)"),
    (.views // {} | to_entries[] | .value[] | "view \(.id)  \(.name // "")")' \
  "$ext/package.json" | sort >"$out/contributes.txt"

jq -r '[paths | select(length >= 2 and .[-2] == "properties")][]
  | map(tostring)
  | map(select(. != "properties" and . != "items" and . != "additionalProperties"
               and . != "anyOf" and . != "oneOf" and (test("^[0-9]+$") | not)))
  | join(".")' "$ext/claude-code-settings.schema.json" | sort -u >"$out/settings.txt"

new=$(cat "$out/VERSION")

if [ "$accept" -eq 1 ]; then
  mkdir -p "$SNAPSHOT"
  cp "$out"/* "$SNAPSHOT"/
  echo "snapshot is now $new ($ext)"
  exit 0
fi

status=0
old=$(cat "$SNAPSHOT/VERSION" 2>/dev/null || echo none)
echo "extension $new (snapshot $old)"

for f in requests.txt cli-requests.txt contributes.txt settings.txt strings.txt; do
  if [ ! -f "$SNAPSHOT/$f" ]; then
    echo "  $f: no snapshot yet (run with --accept)"; status=1; continue
  fi
  if diff -q "$SNAPSHOT/$f" "$out/$f" >/dev/null; then
    echo "  $f: unchanged"
  else
    status=1
    added=$(comm -13 "$SNAPSHOT/$f" "$out/$f" | wc -l | tr -d ' ')
    removed=$(comm -23 "$SNAPSHOT/$f" "$out/$f" | wc -l | tr -d ' ')
    echo "  $f: +$added -$removed"
    comm -13 "$SNAPSHOT/$f" "$out/$f" | sed 's/^/      + /'
    comm -23 "$SNAPSHOT/$f" "$out/$f" | sed 's/^/      - /'
  fi
done

# Every request has a row in the ledger, and every row is still a request. A row is a
# table line whose first cell is the request in backticks and second its status; a row
# marked `gone` records a request the extension dropped. Webview requests are the rows
# above the "CLI control requests" heading, CLI requests the rows below it: some names
# (`rename_session`) are both.
CLI_HEADING='^## CLI control requests'
rows() {
  grep -E '^\| `[a-z0-9_]+` \|' | sed -E 's/^\| `([a-z0-9_]+)` \| *([^ |]*).*/\1 \2/' \
    | grep -v ' gone$' | cut -d' ' -f1 | sort -u
}
: >"$out/ledger-requests.txt"
: >"$out/ledger-cli-requests.txt"
if [ -f "$LEDGER" ]; then
  sed "/$CLI_HEADING/,\$d" "$LEDGER" | rows >"$out/ledger-requests.txt"
  sed -n "/$CLI_HEADING/,\$p" "$LEDGER" | rows >"$out/ledger-cli-requests.txt"
fi
for f in requests.txt cli-requests.txt; do
  missing=$(comm -23 "$out/$f" "$out/ledger-$f")
  dropped=$(comm -13 "$out/$f" "$out/ledger-$f")
  if [ -n "$missing" ]; then
    status=1
    echo "  in $f with no row in $LEDGER:"
    echo "$missing" | sed 's/^/      /'
  fi
  if [ -n "$dropped" ]; then
    status=1
    echo "  rows in $LEDGER the extension no longer sends, from $f (mark them gone):"
    echo "$dropped" | sed 's/^/      /'
  fi
done

[ "$status" -eq 0 ] && echo "nothing to review"
exit "$status"
