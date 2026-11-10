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

# The macOS binary is built for macOS >= .github/macos-minimum-version
# (-minimum-os-version); brew refuses older systems with its own message.
FLOOR_FILE="$(cd "$(dirname "$0")/.." && pwd)/macos-minimum-version"
MACOS_FLOOR=$(tr -d "[:space:]" < "$FLOOR_FILE")
case "${MACOS_FLOOR%%.*}" in
  11) MACOS_SYMBOL=big_sur ;;
  12) MACOS_SYMBOL=monterey ;;
  13) MACOS_SYMBOL=ventura ;;
  14) MACOS_SYMBOL=sonoma ;;
  15) MACOS_SYMBOL=sequoia ;;
  26) MACOS_SYMBOL=tahoe ;;
  *)
    echo "error: no Homebrew macOS name for floor '$MACOS_FLOOR' ($FLOOR_FILE)" >&2
    exit 65
    ;;
esac

BASE_URL="https://github.com/dvrd/wayu/releases/download/${VERSION}"

cat <<FORMULA
class Wayu < Formula
  desc "Shell configuration management CLI — PATH, aliases, env vars, plugins"
  homepage "https://github.com/dvrd/wayu"
  version "${VERSION_BARE}"
  license "MIT"

  # Prebuilt binaries exist for macOS arm64 and Linux x86_64 only.
  # macOS: built for ${MACOS_FLOOR} and later.
  on_macos do
    depends_on arch: :arm64
    depends_on macos: :${MACOS_SYMBOL}
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
      Set wayu up by running:
        wayu init

      It creates ~/.config/wayu (wayu.toml) and the data dir
      ~/.local/share/wayu, and offers to add the line that loads wayu to
      your shell rc file. To add it yourself:
        zsh  (~/.zshrc):
          source "\${WAYU_DATA_DIR:-\${XDG_DATA_HOME:-\$HOME/.local/share}/wayu}/init.zsh"
        bash (~/.bash_profile or ~/.bashrc):
          source "\${WAYU_DATA_DIR:-\${XDG_DATA_HOME:-\$HOME/.local/share}/wayu}/init.bash"
        fish: see "Shell setup" in https://github.com/dvrd/wayu#shell-setup
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/wayu version")
  end
end
FORMULA
