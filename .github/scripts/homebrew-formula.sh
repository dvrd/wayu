#!/usr/bin/env bash
# Render the Homebrew formula for dvrd/homebrew-wayu to stdout.
#
# Usage: homebrew-formula.sh <version-tag> <macos-arm64-sha256> <linux-amd64-sha256>
#   e.g. homebrew-formula.sh v4.4.3 <64 hex> <64 hex> > Formula/wayu.rb
#
# Published binaries: macOS arm64 and Linux x86_64 only. Each OS block pins
# the one CPU it has a binary for with `depends_on arch:`, so brew stops with
# its own "An ARM64 / x86_64 architecture is required" message on macOS Intel
# or Linux arm64 instead of installing a binary that cannot exec. Every
# platform still gets a url so the formula always loads (a formula with no
# url for the current platform fails to load with a vaguer error).
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <version-tag> <macos-arm64-sha256> <linux-amd64-sha256>" >&2
  exit 64
fi

VERSION="$1"
MACOS_ARM64_SHA="$2"
LINUX_AMD64_SHA="$3"

if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like vX.Y.Z, got '$VERSION'" >&2
  exit 65
fi
for sha in "$MACOS_ARM64_SHA" "$LINUX_AMD64_SHA"; do
  if ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: invalid sha256 '$sha'" >&2
    exit 65
  fi
done

VERSION_BARE="${VERSION#v}"
BASE_URL="https://github.com/dvrd/wayu/releases/download/${VERSION}"

cat <<FORMULA
class Wayu < Formula
  desc "Shell configuration management CLI — PATH, aliases, env vars, plugins"
  homepage "https://github.com/dvrd/wayu"
  version "${VERSION_BARE}"
  license "MIT"

  # Prebuilt binaries exist for macOS arm64 and Linux x86_64 only.
  on_macos do
    depends_on arch: :arm64
    url "${BASE_URL}/wayu-macos-arm64.tar.gz"
    sha256 "${MACOS_ARM64_SHA}"
  end

  on_linux do
    depends_on arch: :x86_64
    url "${BASE_URL}/wayu-linux-amd64.tar.gz"
    sha256 "${LINUX_AMD64_SHA}"
  end

  def install
    bin.install "wayu"
  end

  def caveats
    <<~EOS
      Initialize wayu config files by running:
        wayu init

      Then add this line to your shell RC file:
        source ~/.config/wayu/init.zsh   # zsh
        source ~/.config/wayu/init.bash  # bash
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/wayu version")
  end
end
FORMULA
