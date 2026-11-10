#!/usr/bin/env bash
# Fail when a macOS binary needs a newer macOS than .github/macos-minimum-version.
#
# Usage: check-macos-minos.sh <binary>
#
# Reads the minimum OS the binary was linked for (LC_BUILD_VERSION minos, or
# LC_VERSION_MIN_MACOSX version on old toolchains) with `otool -l`. Without
# an explicit -minimum-os-version Odin stamps the build host's macOS, so a
# release built on a new runner would not start on older Macs.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <binary>" >&2
  exit 64
fi

BINARY="$1"
FLOOR_FILE="$(cd "$(dirname "$0")/.." && pwd)/macos-minimum-version"
FLOOR=$(tr -d '[:space:]' < "$FLOOR_FILE")
if [ -z "$FLOOR" ]; then
  echo "error: $FLOOR_FILE is empty" >&2
  exit 65
fi

MINOS=$(otool -l "$BINARY" | awk '
  /cmd LC_BUILD_VERSION/     { want = "minos" }
  /cmd LC_VERSION_MIN_MACOSX/ { want = "version" }
  want != "" && $1 == want   { print $2; exit }
')
if [ -z "$MINOS" ]; then
  echo "error: no LC_BUILD_VERSION / LC_VERSION_MIN_MACOSX in $BINARY" >&2
  exit 1
fi

# minos above the floor: the binary refuses to start on supported Macs.
HIGHEST=$(printf '%s\n%s\n' "$MINOS" "$FLOOR" | sort -V | tail -1)
if [ "$MINOS" != "$FLOOR" ] && [ "$HIGHEST" = "$MINOS" ]; then
  echo "error: $BINARY requires macOS $MINOS; the floor is $FLOOR ($FLOOR_FILE)." >&2
  echo "Build with -minimum-os-version:$FLOOR (./build_it build does)." >&2
  exit 1
fi
echo "$BINARY: minos $MINOS (floor $FLOOR)"
