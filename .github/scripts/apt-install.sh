#!/usr/bin/env bash
# Install Ubuntu packages on a GitHub-hosted Linux runner, robustly.
#
# Usage: apt-install.sh <apt-package>...
#   BREW_PACKAGES  Homebrew formulae for the fallback (default: the apt names)
#   LINK_BINS      executables the fallback symlinks into /usr/bin, as names
#                  in <brew prefix>/bin or paths under the brew prefix
#                  (opt/llvm/bin/clang); default: the apt names
#
# The runner's Azure apt mirror sometimes fails to resolve: retry, then fall
# back to archive.ubuntu.com, and as a last resort install from Homebrew
# (bottles come from ghcr.io, not the Ubuntu mirrors; x86_64 images only).
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <apt-package>..." >&2
  exit 64
fi

for try in 1 2 3; do
  if sudo apt-get -o Acquire::Retries=3 update -qq &&
     sudo apt-get -o Acquire::Retries=3 install -y -qq "$@"; then
    exit 0
  fi
  sudo sed -i 's#mirror+file:/etc/apt/apt-mirrors.txt#http://archive.ubuntu.com/ubuntu/#' \
    /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
  sleep $((try * 10))
done

brew=/home/linuxbrew/.linuxbrew/bin/brew
if [ ! -x "$brew" ]; then
  echo "::error::apt-get install $* failed and this runner has no Homebrew fallback"
  exit 1
fi
read -r -a formulae <<< "${BREW_PACKAGES:-$*}"
read -r -a links <<< "${LINK_BINS:-$*}"
HOMEBREW_NO_AUTO_UPDATE=1 "$brew" install "${formulae[@]}"
prefix=$("$brew" --prefix)
for bin in "${links[@]}"; do
  case "$bin" in
    */*) src="$prefix/$bin" ;;
    *) src="$prefix/bin/$bin" ;;
  esac
  sudo ln -sf "$src" "/usr/bin/${bin##*/}"
done
