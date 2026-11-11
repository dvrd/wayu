#!/usr/bin/env bash
# Shell startup benchmark: init.<ext> vs turbo vs eval vs an empty shell.
#
# Builds a fixed entry store (21 paths, 60 aliases, 20 constants) in a throwaway
# HOME, runs `wayu init` + `wayu build` + `wayu export --turbo`, then times
# `zsh -f -c 'source …'` / `bash --norc -c …` / `fish --no-config -c …` with
# hyperfine when it is installed, otherwise with a plain loop (mean of RUNS).
#
#   tests/benchmark/startup.sh                       # ./bin/wayu, zsh only
#   WAYU_BIN=/path/to/wayu RUNS=50 tests/benchmark/startup.sh
#   SHELLS="zsh bash fish" TOOLS=1 tests/benchmark/startup.sh
#
# TOOLS=1 adds [tools] entries (a lazy loader and an evalcache tool) and
# PROMPT=1 enables the native prompt (zsh, fish), to measure the full feature set.
set -eu

WAYU_BIN=${WAYU_BIN:-$PWD/bin/wayu}
RUNS=${RUNS:-30}
SHELLS=${SHELLS:-zsh}
TOOLS=${TOOLS:-0}
PROMPT=${PROMPT:-0}
[ -x "$WAYU_BIN" ] || { echo "wayu binary not found: $WAYU_BIN (build it or set WAYU_BIN)" >&2; exit 1; }
HYPERFINE=$(command -v hyperfine || true)

home=$(mktemp -d "${TMPDIR:-/tmp}/wayu-bench.XXXXXX")
trap 'rm -rf "$home"' EXIT
export HOME=$home
unset ZDOTDIR WAYU_CONFIG WAYU_CONFIG_DIR WAYU_DATA_DIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
cfg=$home/.config/wayu
data=$home/.local/share/wayu
mkdir -p "$home/.config" "$home/bin"

for sh in $SHELLS; do
	SHELL=/bin/$sh "$WAYU_BIN" init --shell "$sh" >/dev/null 2>&1
done
if [ "$TOOLS" = 1 ]; then
	# A fake evalcache tool on PATH (prints an alias definition).
	printf '#!/bin/sh\necho "alias benchtool_ok=true"\n' > "$home/bin/benchtool"
	chmod +x "$home/bin/benchtool"
fi
# The temp HOME path holds no quotes or backslashes, so plain JSON strings.
{
	echo '{'
	echo '  "version": 1,'
	echo '  "paths": ['
	echo "    {\"key\": \"bin\", \"dir\": \"$home/bin\"},"
	i=1
	while [ $i -le 20 ]; do
		mkdir -p "$home/bins/b$i"
		sep=,; [ $i -lt 20 ] || sep=
		echo "    {\"key\": \"p$i\", \"dir\": \"$home/bins/b$i\"}$sep"
		i=$((i + 1))
	done
	echo '  ],'
	echo '  "env": ['
	i=1
	while [ $i -le 20 ]; do
		sep=,; [ $i -lt 20 ] || sep=
		echo "    {\"name\": \"BENCH_E$i\", \"value\": \"value-$i:\${HOME}/x\"}$sep"
		i=$((i + 1))
	done
	echo '  ],'
	echo '  "aliases": ['
	i=1
	while [ $i -le 60 ]; do
		sep=,; [ $i -lt 60 ] || sep=
		echo "    {\"name\": \"ba$i\", \"value\": \"echo alias $i && ls -la\"}$sep"
		i=$((i + 1))
	done
	echo '  ]'
	echo '}'
} > "$data/entries.json"
{
	if [ "$TOOLS" = 1 ]; then
		echo "[tools]"
		echo 'sdk = { kind = "lazy", init_script = "~/.sdk/init.sh", hook_commands = ["sdk"] }'
		echo 'benchtool = { args = "init" }'
	fi
	if [ "$PROMPT" = 1 ]; then
		echo
		echo "[prompt]"
		echo "enabled = true"
	fi
} > "$cfg/wayu.toml"

for sh in $SHELLS; do
	SHELL=/bin/$sh "$WAYU_BIN" --shell "$sh" completions generate >/dev/null 2>&1 || true
	SHELL=/bin/$sh "$WAYU_BIN" --shell "$sh" build >/dev/null
	SHELL=/bin/$sh "$WAYU_BIN" --shell "$sh" export --turbo >/dev/null
done
# Let the background zcompile finish so every run sees the same state.
sleep 1

flag_of() { case $1 in zsh) echo -f ;; bash) echo --norc ;; *) echo --no-config ;; esac; }

for sh in $SHELLS; do
	exe=$(command -v "$sh" || true)
	[ -n "$exe" ] || [ "$sh" != fish ] || exe=$( (ls /opt/homebrew/bin/fish /usr/local/bin/fish 2>/dev/null || true) | head -1)
	[ -n "$exe" ] || { echo "$sh: not installed, skipped"; continue; }
	f=$(flag_of "$sh")
	names="empty init turbo eval"
	# Interactive: completion (compinit) and the prompt are set up only there.
	[ "$sh" = bash ] || names="$names empty-i init-i turbo-i"
	# Warm the compinit dump (+ its .zwc) / evalcache.
	"$exe" $f -i -c "source '$data/init.$sh'" >/dev/null 2>&1 </dev/null || true
	sleep 1
	cmd_of() {
		case $1 in
			empty|empty-i) echo ":" ;;
			init|init-i) echo "source '$data/init.$sh'" ;;
			turbo|turbo-i) echo "source '$data/turbo.$sh'" ;;
			eval) if [ "$sh" = fish ]; then echo "'$WAYU_BIN' --shell fish export --eval | source"; else echo "eval \"\$('$WAYU_BIN' --shell $sh export --eval)\""; fi ;;
		esac
	}
	if [ -n "$HYPERFINE" ]; then
		set --
		for n in $names; do
			fl=$f
			case $n in *-i) fl="$f -i" ;; esac
			set -- "$@" -n "$sh $n" "$exe $fl -c \"$(cmd_of "$n" | sed 's/"/\\"/g')\""
		done
		"$HYPERFINE" -N --warmup 3 --runs "$RUNS" --style basic "$@" 2>/dev/null | grep -E '^(Benchmark|  Time)'
	else
		for n in $names; do
			c=$(cmd_of "$n")
			fl=$f
			case $n in *-i) fl="$f -i" ;; esac
			t0=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1e6')
			i=0
			while [ $i -lt "$RUNS" ]; do "$exe" $fl -c "$c" >/dev/null 2>&1; i=$((i + 1)); done
			t1=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1e6')
			awk -v n="$sh $n" -v d=$((t1 - t0)) -v r="$RUNS" 'BEGIN { printf "%-18s %.1f ms mean\n", n, d / r / 1000 }'
		done
	fi
done
