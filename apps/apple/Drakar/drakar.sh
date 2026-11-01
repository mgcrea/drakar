#!/bin/sh
# drakar [folder…]: opens each folder (the current one by default) as a project in Drakar,
# as `code .` does for VS Code. Settings › General › Install links it into ~/.local/bin or
# /usr/local/bin; it finds the app it sits in through that link, wherever the app is.
# DRAKAR_OPEN replaces `open`, for the app's tests.
set -e

case "$1" in
-h | --help)
  echo "usage: drakar [folder…]   open folders (the current one by default) in Drakar"
  exit 0
  ;;
esac
[ $# -gt 0 ] || set -- .

for target in "$@"; do
  if [ ! -d "$target" ]; then
    echo "drakar: $target is not a folder" >&2
    exit 1
  fi
done

script=$0
while [ -L "$script" ]; do
  link=$(readlink "$script")
  case $link in
  /*) script=$link ;;
  *) script=$(dirname "$script")/$link ;;
  esac
done
app=$(cd "$(dirname "$script")/../.." && pwd -P)

# Each argument, resolved, in place: the loop walks the list as it was, appending each
# absolute path and dropping the argument it came from.
for target in "$@"; do
  set -- "$@" "$(cd "$target" && pwd -P)"
  shift
done
exec ${DRAKAR_OPEN:-open} -a "$app" "$@"
