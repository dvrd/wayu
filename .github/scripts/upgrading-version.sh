#!/usr/bin/env bash
# Name docs/UPGRADING.md's "## Unreleased" section after the release.
#
# Usage: upgrading-version.sh <version-tag> [UPGRADING.md]
#
# Renames the "## Unreleased" heading to "## X.Y.Z" (the release notes take
# the upgrade notes from that section, see release-notes.sh). No-op when the
# file already has a "## X.Y.Z" section or has no "## Unreleased" one.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <version-tag> [UPGRADING.md]" >&2
  exit 64
fi

VERSION="$1"
FILE="${2:-docs/UPGRADING.md}"
if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like vX.Y.Z, got '$VERSION'" >&2
  exit 65
fi
VERSION_BARE="${VERSION#v}"

if grep -qxF "## ${VERSION_BARE}" "$FILE"; then
  echo "$FILE already has a ## ${VERSION_BARE} section"
  exit 0
fi
if ! grep -qxF "## Unreleased" "$FILE"; then
  echo "$FILE has no ## Unreleased section; nothing to rename"
  exit 0
fi

TMP=$(mktemp "${FILE}.XXXXXX")
awk -v v="## ${VERSION_BARE}" '!done && $0 == "## Unreleased" { print v; done = 1; next } { print }' "$FILE" > "$TMP"
# Copy back instead of mv: keeps the file's mode (mktemp creates 0600).
cat "$TMP" > "$FILE"
rm -f "$TMP"
echo "$FILE: ## Unreleased -> ## ${VERSION_BARE}"
