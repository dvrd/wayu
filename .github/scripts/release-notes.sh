#!/usr/bin/env bash
# Render a GitHub release body to stdout.
#
# Usage: release-notes.sh <version-tag> <cliff-notes.md> [UPGRADING.md]
#   cliff-notes.md: `git cliff --latest --strip header` output for the tag
#   UPGRADING.md:   default docs/UPGRADING.md
#
# The "⚠ Upgrade notes" of the release are the "## X.Y.Z" section of
# docs/UPGRADING.md: it is written by hand, kept current on develop and
# complete, while git-cliff only sees commit footers (one per commit, which
# later commits may have superseded). The rest of the body (Added, Fixed, …)
# is git-cliff's. Without an UPGRADING section for the version, git-cliff's
# own upgrade notes (the BREAKING CHANGE footers) are kept.
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <version-tag> <cliff-notes.md> [UPGRADING.md]" >&2
  exit 64
fi

VERSION="$1"
CLIFF_NOTES="$2"
UPGRADING="${3:-docs/UPGRADING.md}"

if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like vX.Y.Z, got '$VERSION'" >&2
  exit 65
fi
for f in "$CLIFF_NOTES" "$UPGRADING"; do
  if [ ! -r "$f" ]; then
    echo "error: cannot read $f" >&2
    exit 66
  fi
done

VERSION_BARE="${VERSION#v}"
ANCHOR="${VERSION_BARE//./}"
UPGRADING_URL="https://github.com/dvrd/wayu/blob/${VERSION}/docs/UPGRADING.md#${ANCHOR}"
# GitHub rejects release bodies over 125000 characters; leave room for the
# rest of the notes and link to the file instead.
MAX_SECTION_BYTES=100000

# The "## X.Y.Z" section without its heading, blank lines at both ends trimmed.
SECTION=$(awk -v want="## ${VERSION_BARE}" '
  $0 == want      { inside = 1; next }
  inside && /^## / { exit }
  inside          { print }
' "$UPGRADING" | awk 'NF { started = 1 } started' | awk '
  { lines[NR] = $0 }
  END { last = NR; while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--; for (i = 1; i <= last; i++) print lines[i] }
')

if [ -z "$SECTION" ]; then
  cat "$CLIFF_NOTES"
  exit 0
fi

if [ "${#SECTION}" -gt "$MAX_SECTION_BYTES" ]; then
  SECTION="The upgrade notes for ${VERSION_BARE} are too long for a release page: see [docs/UPGRADING.md](${UPGRADING_URL})."
else
  SECTION="${SECTION}

Also in [docs/UPGRADING.md](${UPGRADING_URL})."
fi

# Replace git-cliff's "### ⚠ Upgrade notes" section (up to the next "### "
# heading) with the UPGRADING.md section; insert it after the "## [X.Y.Z]"
# heading when git-cliff had no breaking commits.
SECTION="$SECTION" awk '
  function emit() { print "### ⚠ Upgrade notes"; print ""; print ENVIRON["SECTION"]; print ""; done = 1 }
  /^### ⚠ Upgrade notes/ { emit(); skipping = 1; next }
  skipping && /^### /    { skipping = 0 }
  skipping               { next }
  !done && /^### /       { emit() }
  { print }
  END { if (!done) { print ""; emit() } }
' "$CLIFF_NOTES"
