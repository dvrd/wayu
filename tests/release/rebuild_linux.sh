#!/usr/bin/env bash
# Run on a clean Linux AMD64 runner with the release tag's verified Odin on PATH.
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

compare() {
  local published=$1 candidate=$2
  tar -xOzf "$published" wayu > "$work/published.bin"
  tar -xOzf "$candidate" wayu > "$work/candidate.bin"
  if ! cmp -s "$work/published.bin" "$work/candidate.bin"; then
    echo "Executable differs" >&2
    return 1
  fi
  if ! cmp -s "$published" "$candidate"; then
    echo "Executable matches, archive differs" >&2
    return 2
  fi
  echo "Executable and archive match"
}

if [[ ${1:-} == --self-test ]]; then
  echo fixture > "$work/wayu"
  tar -czf "$work/good.tgz" -C "$work" wayu
  compare "$work/good.tgz" "$work/good.tgz"
  chmod 700 "$work/wayu"
  tar -czf "$work/metadata.tgz" -C "$work" wayu
  if compare "$work/good.tgz" "$work/metadata.tgz"; then exit 1; else [[ $? == 2 ]]; fi
  echo changed > "$work/wayu"
  tar -czf "$work/payload.tgz" -C "$work" wayu
  if compare "$work/good.tgz" "$work/payload.tgz"; then exit 1; else [[ $? == 1 ]]; fi
  exit 0
fi

tag=${1:?pass a published release tag}
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && $(uname -sm) == 'Linux x86_64' ]]
commit=$(git rev-parse --verify "refs/tags/$tag^{commit}")
source_dir=${WAYU_REBUILD_CHECKOUT:-"$work/source"}
if [[ -n ${WAYU_REBUILD_CHECKOUT:-} ]]; then
  [[ $(git -C "$source_dir" rev-parse HEAD) == "$commit" ]]
  git -C "$source_dir" diff --quiet HEAD --
else
  mkdir "$source_dir"
  git archive "$commit" | tar -x -C "$source_dir"
fi
asset=wayu-linux-amd64
if [[ -n ${WAYU_PUBLISHED_ASSETS:-} ]]; then
  cp "$WAYU_PUBLISHED_ASSETS/$asset.tar.gz" "$WAYU_PUBLISHED_ASSETS/$asset.sha256" "$work"
else
  for suffix in tar.gz sha256; do
    curl -fsSL --proto '=https' --retry 3 "https://github.com/dvrd/wayu/releases/download/$tag/$asset.$suffix" -o "$work/$asset.$suffix"
  done
fi
epoch=$(git show -s --format=%ct "$commit")
(
  cd "$work"
  sha256sum -c "$asset.sha256"
  echo "Tag $tag, commit $commit, epoch $epoch"
  odin version
  clang --version
  crt=$(clang -print-file-name=crtbeginS.o)
  echo "Linker startup object $crt"
  readelf -p .comment "$crt"
  ld --version
  tar --version
  gzip --version
  (
    cd "$source_dir"
    odin build build "-out:$work/build_it"
    "$work/build_it" build --target=linux_amd64
  )
  mkdir bin
  cp "$source_dir/bin/wayu" bin/wayu
  chmod 0755 bin/wayu
  tar --format=ustar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    -cf - -C bin wayu | gzip -n -9 > candidate.tgz
  tar -xOzf "$asset.tar.gz" wayu > published.bin
  sha256sum "$asset.tar.gz" candidate.tgz published.bin bin/wayu
  if [[ -n ${WAYU_REBUILD_EVIDENCE:-} ]]; then
    mkdir -p "$WAYU_REBUILD_EVIDENCE"
    for exe in published.bin bin/wayu; do
      name=$(basename "$exe")
      readelf -W -S -n -p .comment "$exe" > "$WAYU_REBUILD_EVIDENCE/$name.elf.txt"
      strings "$exe" | awk '/^\/.*\.odin$/ { print }' | sort -u > "$WAYU_REBUILD_EVIDENCE/$name.paths"
      for section in .text .rodata .data .comment; do
        objcopy --dump-section "$section=$work/section" "$exe" "$work/inspected"
        sha256sum "$work/section" | awk -v s="$section" '{print s, $1}'
      done > "$WAYU_REBUILD_EVIDENCE/$name.sections"
    done
  fi
  compare "$asset.tar.gz" candidate.tgz
)
