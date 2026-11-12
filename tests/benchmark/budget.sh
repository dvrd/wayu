#!/usr/bin/env bash
# Startup-time budget: how much time wayu adds to an interactive shell, and
# a failing exit when that exceeds the budget. CI runs it (ci.yml
# "startup-budget"); run it locally the same way:
#
#   ./build_it && tests/benchmark/budget.sh
#   WAYU_BIN=/path/to/wayu RUNS=100 SHELLS=zsh tests/benchmark/budget.sh
#   METHOD=hyperfine tests/benchmark/budget.sh   # time with hyperfine instead
#
# Setup, in a throwaway HOME (nothing outside it is read or written; the
# secret uses the file backend, never the keychain / Secret Service):
#   5 PATH entries, 10 aliases, 5 constants, 1 secret constant
#   [tools]: one evalcache tool (a local fake binary, no network)
#   [prompt] enabled = true (zsh; bash has no native prompt)
#   wayu's own completions generated
#
# For each shell it times, many times and interleaved (so drift on a busy
# runner hits both sides alike):
#   base   zsh -i -c exit with an empty .zshrc     bash --rcfile <empty> -i -c exit
#   wayu   zsh -i -c exit, .zshrc sources init.zsh bash --rcfile <init line> -i -c exit
# Both read the same system files (/etc/zshrc, ...), so wayu = base + what
# wayu adds. Before timing, one wayu shell must show the PATH entry, an
# alias, a constant and the secret loaded (a broken init would be "fast").
#
# Budget: added = median(wayu) - median(base) must stay <= max(BUDGET_MS,
# BUDGET_RATIO x median(base)). The absolute cap is the promise; the ratio
# only raises it on runners where an empty shell is itself slow, so a slower
# machine does not flake.
#
# Calibration (2026-11-11, Apple M-series, macOS 27, zsh 5.9, bash 3.2,
# median of 60, 4 runs, loop and hyperfine agree within 0.5 ms):
#   zsh   base 14.6-15.9 ms  wayu 23.8-25.2 ms  added 8.8-9.5 ms
#   bash  base  3.7-5.0 ms   wayu 10.2-11.8 ms  added 6.1-7.1 ms
# (macOS's /etc/zshrc forks `locale`, hence the zsh base.) BUDGET_MS=30 is
# ~3x the zsh delta: real regressions (a fork per entry, an uncached tool
# eval, a compinit rebuild on every start: +20..300 ms) fail, runner noise
# on a median does not. BUDGET_RATIO=2 lifts the cap only where an empty
# shell already takes over 15 ms.
#
# METHOD: loop (default; interleaved, timed by python3, no extra install) or
# hyperfine (runs each command back to back, needs hyperfine). Exit codes:
# 0 within budget, 1 over budget, 2 setup or sanity check failed.
set -eu

WAYU_BIN=${WAYU_BIN:-$PWD/bin/wayu}
RUNS=${RUNS:-60}
WARMUP=${WARMUP:-5}
SHELLS=${SHELLS:-"zsh bash"}
BUDGET_MS=${BUDGET_MS:-30}
BUDGET_RATIO=${BUDGET_RATIO:-2}
METHOD=${METHOD:-loop}

case $WAYU_BIN in /*) ;; *) WAYU_BIN=$PWD/$WAYU_BIN ;; esac
[ -x "$WAYU_BIN" ] || { echo "wayu binary not found: $WAYU_BIN (build it or set WAYU_BIN)" >&2; exit 2; }
PYTHON=$(command -v python3) || { echo "python3 is required" >&2; exit 2; }
if [ "$METHOD" = hyperfine ]; then
	HYPERFINE=$(command -v hyperfine) || { echo "METHOD=hyperfine but hyperfine is not installed" >&2; exit 2; }
fi

home=$(mktemp -d "${TMPDIR:-/tmp}/wayu-budget.XXXXXX")
home=$(cd "$home" && pwd -P)
trap 'rm -rf "$home"' EXIT
mkdir -p "$home/.config" "$home/bin" "$home/tmp" "$home/zd-base" "$home/zd-wayu"
data=$home/.local/share/wayu
cfg=$home/.config/wayu
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
USER_NAME=${USER:-$(id -un)}

# Run a command in a clean environment rooted at the temp HOME (TMPDIR too:
# the secrets session cache lands there).
in_home() {
	(cd "$home" && env -i HOME="$home" USER="$USER_NAME" LOGNAME="$USER_NAME" \
		TERM=xterm-256color LANG=C.UTF-8 TMPDIR="$home/tmp" PATH="$BASE_PATH" "$@")
}
w() { in_home SHELL="/bin/$1" "$WAYU_BIN" --shell "$@" </dev/null; }

exe_of() { command -v "$1" || true; }
shells=
for sh in $SHELLS; do
	case $sh in zsh | bash) ;; *) echo "unsupported shell: $sh (zsh, bash)" >&2; exit 2 ;; esac
	exe=$(exe_of "$sh")
	[ -n "$exe" ] || { echo "$sh: not installed" >&2; exit 2; }
	shells="$shells $sh"
done

# --- Fixed config ------------------------------------------------------------
for sh in $shells; do w "$sh" init >/dev/null 2>&1; done
# A fake evalcache tool on a PATH entry: prints one alias definition.
printf '#!/bin/sh\necho "alias budgettool_ok=true"\n' >"$home/bin/budgettool"
chmod +x "$home/bin/budgettool"
cat >>"$cfg/wayu.toml" <<'EOF'

[secrets]
backend = "file"

[tools]
budgettool = { args = "init" }

[prompt]
enabled = true
EOF
first=${shells# }
first=${first%% *}
w "$first" path add "$home/bin" >/dev/null
for i in 1 2 3 4; do
	mkdir -p "$home/bins/b$i"
	w "$first" path add "$home/bins/b$i" >/dev/null
done
for i in 1 2 3 4 5 6 7 8 9 10; do w "$first" alias add "ba$i" "echo alias $i && ls -la" >/dev/null; done
for i in 1 2 3 4 5; do w "$first" const add "BUDGET_E$i" "value-$i" >/dev/null; done
printf 'budget-secret-value' | in_home SHELL="/bin/$first" "$WAYU_BIN" --shell "$first" const add BUDGET_SECRET --secret >/dev/null
for sh in $shells; do
	w "$sh" completions generate >/dev/null 2>&1 || true
	w "$sh" build >/dev/null
done

: >"$home/zd-base/.zshrc"
printf 'source "%s/init.zsh"\n' "$data" >"$home/zd-wayu/.zshrc"
: >"$home/base.bashrc"
printf 'source "%s/init.bash"\n' "$data" >"$home/wayu.bashrc"

# argv (one word per line) of the measured commands.
cmd_of() { # $1 = shell, $2 = base|wayu, then extra args for -c
	local sh=$1 kind=$2 exe
	shift 2
	exe=$(exe_of "$sh")
	case $sh in
		zsh) printf '%s\n' env "ZDOTDIR=$home/zd-$kind" "$exe" -i -c "${1:-exit}" ;;
		bash) printf '%s\n' "$exe" --rcfile "$home/$kind.bashrc" -i -c "${1:-exit}" ;;
	esac
}
run_cmd() { # $1 = shell, $2 = kind, $3 = command
	local argv=()
	while IFS= read -r a; do argv+=("$a"); done < <(cmd_of "$1" "$2" "$3")
	in_home "${argv[@]}" </dev/null
}

# --- Sanity: the config really loads ------------------------------------------
# shellcheck disable=SC2016 # expanded by the measured shell, not here
check='alias ba3 >/dev/null && alias budgettool_ok >/dev/null && [ "$BUDGET_E5" = value-5 ] && [ "$BUDGET_SECRET" = budget-secret-value ] && case ":$PATH:" in *":'"$home"'/bins/b4:"*) echo LOADED ;; esac'
for sh in $shells; do
	# Twice: the first shell writes caches (compdump, evalcache, secrets cache).
	run_cmd "$sh" wayu "$check" >/dev/null 2>&1 || true
	err=$home/sanity-$sh.err
	out=$(run_cmd "$sh" wayu "$check" 2>"$err" || true)
	if [ "$out" != LOADED ]; then
		echo "$sh: wayu config did not load (alias, tool, constant, secret, PATH); stderr:" >&2
		cat "$err" >&2
		exit 2
	fi
	if grep -q 'wayu' "$err"; then
		echo "$sh: wayu printed to stderr at startup:" >&2
		cat "$err" >&2
		exit 2
	fi
done

# --- Measure -----------------------------------------------------------------
results=$home/results.tsv # shell <TAB> base_ms <TAB> wayu_ms (medians)
: >"$results"
for sh in $shells; do
	argfile=$home/argv-$sh
	{
		cmd_of "$sh" base
		echo "--"
		cmd_of "$sh" wayu
	} >"$argfile"
	if [ "$METHOD" = hyperfine ]; then
		quote() { "$PYTHON" -I -c 'import shlex,sys; print(" ".join(shlex.quote(a) for a in sys.argv[1:]))' "$@"; }
		base_args=() wayu_args=()
		while IFS= read -r a; do base_args+=("$a"); done < <(cmd_of "$sh" base)
		while IFS= read -r a; do wayu_args+=("$a"); done < <(cmd_of "$sh" wayu)
		in_home "$HYPERFINE" -N --warmup "$WARMUP" --runs "$RUNS" --style none \
			--export-json "$home/hf-$sh.json" -n base "$(quote "${base_args[@]}")" -n wayu "$(quote "${wayu_args[@]}")" </dev/null
		"$PYTHON" -I -c '
import json, statistics, sys
r = {x["command"]: statistics.median(x["times"]) * 1000 for x in json.load(open(sys.argv[1]))["results"]}
print("%s\t%.2f\t%.2f" % (sys.argv[2], r["base"], r["wayu"]))' "$home/hf-$sh.json" "$sh" >>"$results"
	else
		in_home "$PYTHON" -I -c '
import statistics, subprocess, sys, time
sh, runs, warmup, path = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
words = open(path).read().split("\n")[:-1]
cut = words.index("--")
cmds = {"base": words[:cut], "wayu": words[cut + 1:]}
times = {"base": [], "wayu": []}
for i in range(warmup + runs):
    # Alternate which side goes first, so neither always runs right after the other.
    for k in (("base", "wayu") if i % 2 == 0 else ("wayu", "base")):
        t0 = time.perf_counter()
        subprocess.run(cmds[k], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        if i >= warmup:
            times[k].append((time.perf_counter() - t0) * 1000)
print("%s\t%.2f\t%.2f" % (sh, statistics.median(times["base"]), statistics.median(times["wayu"])))
' "$sh" "$RUNS" "$WARMUP" "$argfile" </dev/null >>"$results"
	fi
done

# --- Report ------------------------------------------------------------------
report=$home/report.md
status=0
{
	echo "### Shell startup budget"
	echo
	echo "Median of $RUNS runs ($METHOD), \`<shell> -i -c exit\`; budget = max($BUDGET_MS ms, $BUDGET_RATIO x base)."
	echo
	echo "| shell | base (ms) | wayu (ms) | added (ms) | budget (ms) | result |"
	echo "|---|---:|---:|---:|---:|---|"
} >"$report"
while IFS="$(printf '\t')" read -r sh base wayu; do
	line=$("$PYTHON" -I -c '
import sys
sh, base, wayu, cap, ratio = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
added = wayu - base
budget = max(cap, ratio * base)
ok = added <= budget
print("%d| %s | %.1f | %.1f | %.1f | %.1f | %s |" % (0 if ok else 1, sh, base, wayu, added, budget, "ok" if ok else "**over budget**"))' \
		"$sh" "$base" "$wayu" "$BUDGET_MS" "$BUDGET_RATIO")
	[ "${line%%|*}" = 0 ] || status=1
	echo "|${line#*|}" >>"$report"
done <"$results"
{
	echo
	echo "$(uname -sm); $(exe_of zsh >/dev/null && zsh --version 2>/dev/null | head -1); $(bash --version | head -1)"
} >>"$report"

cat "$report"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat "$report" >>"$GITHUB_STEP_SUMMARY"
if [ $status != 0 ]; then
	echo "wayu adds more startup time than the budget (see tests/benchmark/budget.sh)" >&2
	[ -z "${GITHUB_ACTIONS:-}" ] || echo "::error::wayu startup time is over budget (see the job summary)"
fi
exit $status
