#!/usr/bin/env bash
# zsh startup: wayu vs other ways of setting up zsh, measured with zsh-bench.
#
# Every contender loads the same workload in its own throwaway HOME:
#   - compinit (completion system)
#   - zsh-autosuggestions + zsh-syntax-highlighting
#   - 20 aliases, 10 PATH entries, 5 exported env vars
#   - no prompt theme: every .zshrc ends with PROMPT='%1~ %# ' (zsh-bench needs
#     the cwd in the prompt to detect it); oh-my-zsh runs with ZSH_THEME=""
#     and wayu's native prompt stays off, so prompt engines are not compared.
#
# Contenders:
#   floor          .zshrc with only the PROMPT line (zsh + /etc/zshrc cost)
#   plain          hand-written .zshrc: path=(...), export, alias, compinit, source x2
#   plain-c        same with `compinit -C` (skip the security audit and the dump
#                  freshness check; new completions need a manual rebuild)
#   wayu           `wayu init` + entries.json + `wayu plugin add` x2, defaults
#   wayu-defer     same + [settings] defer_plugins = true (plugins after 1st prompt)
#   oh-my-zsh      default lib, plugins=(the two, as custom plugins), no theme,
#                  auto-update off; workload lines after `source oh-my-zsh.sh`
#   zinit          `zinit light` x2, compinit, `zinit cdreplay -q`
#   zinit-turbo    zinit README's turbo recipe: `zinit wait lucid for` with
#                  atinit"ZINIT[COMPINIT_OPTS]=-C; zicompinit; zicdreplay"
#   antidote       static bundle (README's lazy-generate snippet), compinit
#   antidote-defer same with `kind:defer` on both plugins (zsh-defer)
#
# Metric: romkatv/zsh-bench (https://github.com/romkatv/zsh-bench) runs a real
# interactive login zsh in a pty and reports first_prompt_lag (prompt drawn),
# first_command_lag (prompt usable: deferred work done), command_lag,
# input_lag and exit_time (= `zsh -lic exit`, which misreads deferred
# loaders). zsh-bench keeps per-iteration values (--raw); this script reports
# the median of ITERS iterations.
#
# Deferred loaders (wayu-defer, zinit-turbo, antidote-defer) draw the prompt
# before loading the plugins; zsh-bench's first command still runs before
# they load (csh column: 0 = not loaded yet when the first command ran), so
# their first_command_lag does not include the deferred work. Compare them
# with each other, not with the configs that load everything up front. Each HOME is warmed first (two shells) so
# compinit dumps, .zwc files and generated bundles already exist.
#
# Third-party code is fetched at pinned commits (below) into the work dir only;
# wayu's plugins are installed with `wayu plugin add` and then checked out at
# the same commits. Nothing outside the work dir is written.
#
# Run from the repo root (needs zsh >= 5.8, git, network for the clones):
#   tests/benchmark/compare.sh
#   WAYU_BIN=/path/to/wayu ITERS=32 tests/benchmark/compare.sh
#   ONLY="floor wayu plain" tests/benchmark/compare.sh
#   KEEP=1 tests/benchmark/compare.sh          # keep the work dir
#   JSON=out.json tests/benchmark/compare.sh   # also write results as JSON
#
# Second scenario (SCENARIOS="stack optimize"): a typical hand-grown .zshrc
# (plain compinit + `eval "$(tool completion zsh)"` for 3 tools that take
# ~25 ms each to print their completion) before and after `wayu optimize --yes`.
set -eu

WAYU_BIN=${WAYU_BIN:-$PWD/bin/wayu}
ITERS=${ITERS:-32}
ONLY=${ONLY:-"floor plain plain-c wayu wayu-defer oh-my-zsh zinit zinit-turbo antidote antidote-defer"}
SCENARIOS=${SCENARIOS:-"stack optimize"}
KEEP=${KEEP:-0}
JSON=${JSON:-}

# Pinned third-party commits (2026-11-08).
OMZ_REPO=https://github.com/ohmyzsh/ohmyzsh.git                      OMZ_SHA=cca3bdfbef8c52ef8939ce7911ff68852b949daa
ZINIT_REPO=https://github.com/zdharma-continuum/zinit.git            ZINIT_SHA=cb4968123979cf073384e93aa8066d8fd450580f # v3.17.1+10
ANTIDOTE_REPO=https://github.com/mattmc3/antidote.git                ANTIDOTE_SHA=e6612794db27e6fae70eddbcff08201a6cba0748 # v2.3.0+3
ZSA_REPO=https://github.com/zsh-users/zsh-autosuggestions.git        ZSA_SHA=85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5 # v0.7.1+6
ZSH_HL_REPO=https://github.com/zsh-users/zsh-syntax-highlighting.git ZSH_HL_SHA=e6683f20e5c38d3e5447f45845d04ddda75d0f23 # 0.8.0+8
ZSH_DEFER_REPO=https://github.com/romkatv/zsh-defer.git              ZSH_DEFER_SHA=53a26e287fbbe2dcebb3aa1801546c6de32416fa
ZSH_BENCH_REPO=https://github.com/romkatv/zsh-bench.git              ZSH_BENCH_SHA=28b1b1bc888159f0a2cf50f9d29381758341aba1

case $WAYU_BIN in /*) ;; *) WAYU_BIN=$PWD/$WAYU_BIN ;; esac
[ -x "$WAYU_BIN" ] || { echo "wayu binary not found: $WAYU_BIN (build it or set WAYU_BIN)" >&2; exit 1; }
ZSH_EXE=$(command -v zsh) || { echo "zsh not found" >&2; exit 1; }
GIT_EXE=$(command -v git) || { echo "git not found" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/wayu-compare.XXXXXX")
work=$(cd "$work" && pwd -P)
[ "$KEEP" = 1 ] && echo "work dir: $work" || trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
mkdir -p "$work/src" "$work/bin" "$work/results"
ln -s "$WAYU_BIN" "$work/bin/wayu"
ln -s "$GIT_EXE" "$work/bin/git"
# The PATH every benchmarked shell starts with (wayu reachable, as installed).
BASE_PATH=$work/bin:/usr/bin:/bin:/usr/sbin:/sbin

# Run a command in a clean environment with HOME=$1.
in_home() {
	local h=$1; shift
	(cd "$h" && env -i HOME="$h" USER="${USER:-$(id -un)}" LOGNAME="${USER:-$(id -un)}" \
		SHELL="$ZSH_EXE" TERM=xterm-256color LANG=en_US.UTF-8 TMPDIR="${TMPDIR:-/tmp}" \
		PATH="$BASE_PATH" "$@")
}

# fetch <url> <sha> <dest>: a shallow checkout of exactly <sha>.
fetch() {
	git init -q "$3"
	git -C "$3" remote add origin "$1"
	git -C "$3" fetch -q --depth 1 origin "$2"
	git -C "$3" -c advice.detachedHead=false checkout -q FETCH_HEAD
}
# pin <dir> <sha>: move an existing clone to <sha>.
pin() {
	git -C "$1" fetch -q --depth 1 origin "$2"
	git -C "$1" -c advice.detachedHead=false checkout -q "$2"
}

echo "Fetching pinned sources..."
fetch $OMZ_REPO $OMZ_SHA "$work/src/ohmyzsh"
fetch $ZINIT_REPO $ZINIT_SHA "$work/src/zinit"
fetch $ANTIDOTE_REPO $ANTIDOTE_SHA "$work/src/antidote"
fetch $ZSA_REPO $ZSA_SHA "$work/src/zsh-autosuggestions"
fetch $ZSH_HL_REPO $ZSH_HL_SHA "$work/src/zsh-syntax-highlighting"
fetch $ZSH_DEFER_REPO $ZSH_DEFER_SHA "$work/src/zsh-defer"
fetch $ZSH_BENCH_REPO $ZSH_BENCH_SHA "$work/src/zsh-bench"

# The workload as plain zsh (for every contender but wayu, which stores it in
# entries.json). $1 = HOME.
workload_rc() {
	local i
	printf 'path=('
	i=1; while [ $i -le 10 ]; do printf '"%s/bins/b%d" ' "$1" $i; i=$((i + 1)); done
	printf '$path)\ntypeset -U path\n'
	i=1; while [ $i -le 5 ]; do printf "export BENCH_E%d='value-%d'\n" $i $i; i=$((i + 1)); done
	i=1; while [ $i -le 20 ]; do printf "alias ba%d='echo alias %d && ls -la'\n" $i $i; i=$((i + 1)); done
}
PROMPT_LINE="PROMPT='%1~ %# '"

new_home() {
	local h=$work/home-$1 i
	mkdir -p "$h"
	i=1; while [ $i -le 10 ]; do mkdir -p "$h/bins/b$i"; i=$((i + 1)); done
	echo "$h"
}

setup_floor() { echo "$PROMPT_LINE" > "$1/.zshrc"; }

setup_plain() { # $1 = HOME, $2 = compinit flags
	mkdir -p "$1/.zsh"
	cp -R "$work/src/zsh-autosuggestions" "$work/src/zsh-syntax-highlighting" "$1/.zsh/"
	{
		workload_rc "$1"
		echo "autoload -Uz compinit && compinit${2:+ $2}"
		echo 'source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh'
		echo 'source ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh'
		echo "$PROMPT_LINE"
	} > "$1/.zshrc"
}

# wayu's own completions (as startup.sh does). With an empty completions dir,
# wayu <= 6.0.0's compinit signature starts with a space that `read -r` strips,
# so the dump never matches and every shell runs a full `compinit -u` rebuild
# (~+280 ms). WAYU_EMPTY_COMPLETIONS=1 skips this step to measure that case.
wayu_completions() {
	[ "${WAYU_EMPTY_COMPLETIONS:-0}" = 1 ] || in_home "$1" wayu --shell zsh completions generate </dev/null >/dev/null
}

setup_wayu() { # $1 = HOME, $2 = defer (0|1)
	local h=$1 data=$1/.local/share/wayu i
	mkdir -p "$h/.config"
	in_home "$h" wayu init --shell zsh </dev/null >/dev/null
	wayu_completions "$h"
	in_home "$h" wayu --shell zsh plugin add autosuggestions </dev/null >/dev/null
	in_home "$h" wayu --shell zsh plugin add syntax-highlighting </dev/null >/dev/null
	pin "$data/plugins/zsh-autosuggestions" $ZSA_SHA
	pin "$data/plugins/zsh-syntax-highlighting" $ZSH_HL_SHA
	{
		echo '{'
		echo '  "version": 1,'
		echo '  "paths": ['
		i=1; while [ $i -le 10 ]; do
			sep=,; [ $i -lt 10 ] || sep=
			echo "    {\"key\": \"b$i\", \"dir\": \"$h/bins/b$i\"}$sep"; i=$((i + 1))
		done
		echo '  ],'
		echo '  "aliases": ['
		i=1; while [ $i -le 20 ]; do
			sep=,; [ $i -lt 20 ] || sep=
			echo "    {\"name\": \"ba$i\", \"value\": \"echo alias $i && ls -la\"}$sep"; i=$((i + 1))
		done
		echo '  ],'
		echo '  "env": ['
		i=1; while [ $i -le 5 ]; do
			sep=,; [ $i -lt 5 ] || sep=
			echo "    {\"name\": \"BENCH_E$i\", \"value\": \"value-$i\"}$sep"; i=$((i + 1))
		done
		echo '  ]'
		echo '}'
	} > "$data/entries.json"
	[ "$2" = 1 ] && printf '\n[settings]\ndefer_plugins = true\n' >> "$h/.config/wayu/wayu.toml"
	in_home "$h" wayu --shell zsh build >/dev/null
	{
		echo 'source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh"'
		echo "$PROMPT_LINE"
	} > "$h/.zshrc"
}

setup_omz() {
	cp -R "$work/src/ohmyzsh" "$1/.oh-my-zsh"
	cp -R "$work/src/zsh-autosuggestions" "$work/src/zsh-syntax-highlighting" "$1/.oh-my-zsh/custom/plugins/"
	{
		echo 'export ZSH="$HOME/.oh-my-zsh"'
		echo 'ZSH_THEME=""'
		echo "zstyle ':omz:update' mode disabled"
		echo 'plugins=(zsh-autosuggestions zsh-syntax-highlighting)'
		echo 'source $ZSH/oh-my-zsh.sh'
		workload_rc "$1"
		echo "$PROMPT_LINE"
	} > "$1/.zshrc"
}

setup_zinit() { # $1 = HOME, $2 = turbo (0|1)
	local zh=$1/.local/share/zinit
	mkdir -p "$zh/plugins"
	cp -R "$work/src/zinit" "$zh/zinit.git"
	cp -R "$work/src/zsh-autosuggestions" "$zh/plugins/zsh-users---zsh-autosuggestions"
	cp -R "$work/src/zsh-syntax-highlighting" "$zh/plugins/zsh-users---zsh-syntax-highlighting"
	{
		echo 'ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"'
		echo 'source "${ZINIT_HOME}/zinit.zsh"'
		workload_rc "$1"
		if [ "$2" = 1 ]; then
			echo 'zinit wait lucid for \'
			echo '  atinit"ZINIT[COMPINIT_OPTS]=-C; zicompinit; zicdreplay" zsh-users/zsh-syntax-highlighting \'
			echo '  atload"!_zsh_autosuggest_start" zsh-users/zsh-autosuggestions'
		else
			echo 'zinit light zsh-users/zsh-autosuggestions'
			echo 'zinit light zsh-users/zsh-syntax-highlighting'
			echo 'autoload -Uz compinit && compinit'
			echo 'zinit cdreplay -q'
		fi
		echo "$PROMPT_LINE"
	} > "$1/.zshrc"
}

setup_antidote() { # $1 = HOME, $2 = defer (0|1)
	local ah=$1/.cache/antidote kind=
	[ "$2" = 1 ] && kind=' kind:defer'
	mkdir -p "$ah/github.com/zsh-users" "$ah/github.com/romkatv"
	cp -R "$work/src/antidote" "$1/.antidote"
	cp -R "$work/src/zsh-autosuggestions" "$work/src/zsh-syntax-highlighting" "$ah/github.com/zsh-users/"
	cp -R "$work/src/zsh-defer" "$ah/github.com/romkatv/"
	printf 'zsh-users/zsh-autosuggestions%s\nzsh-users/zsh-syntax-highlighting%s\n' "$kind" "$kind" > "$1/.zsh_plugins.txt"
	{
		echo 'export ANTIDOTE_HOME=$HOME/.cache/antidote'
		workload_rc "$1"
		echo 'autoload -Uz compinit && compinit'
		echo 'zsh_plugins=${ZDOTDIR:-$HOME}/.zsh_plugins'
		echo 'if [[ ! ${zsh_plugins}.zsh -nt ${zsh_plugins}.txt ]]; then'
		echo '  ( source $HOME/.antidote/antidote.zsh; antidote bundle <${zsh_plugins}.txt >|${zsh_plugins}.zsh )'
		echo 'fi'
		echo 'source ${zsh_plugins}.zsh'
		echo "$PROMPT_LINE"
	} > "$1/.zshrc"
}

# --- Scenario "optimize": a hand-grown rc, then `wayu optimize --yes` --------
# A fake CLI that, like kubectl/gh/helm, prints its zsh completion on
# `<tool> completion zsh` and takes ~25 ms to start.
make_slow_tool() { # $1 = HOME, $2 = name
	mkdir -p "$1/tools"
	cat > "$1/tools/$2" <<EOF
#!/bin/sh
perl -e 'select(undef, undef, undef, 0.025)'
if [ "\$1 \$2" = "completion zsh" ]; then
	echo '#compdef $2'
	echo '_$2() { _arguments "1: :(get set list)"; }'
	echo 'if [ "\$funcstack[1]" = "_$2" ]; then _$2 "\$@"; else compdef _$2 $2; fi'
fi
EOF
	chmod +x "$1/tools/$2"
}
setup_rc_stack() { # $1 = HOME
	local t
	setup_plain "$1"
	for t in kubectl-fake gh-fake helm-fake; do make_slow_tool "$1" $t; done
	{
		echo 'path=("$HOME/tools" $path)'
		cat "$1/.zshrc" | grep -v '^PROMPT='
		for t in kubectl-fake gh-fake helm-fake; do echo "eval \"\$($t completion zsh)\""; done
		echo "$PROMPT_LINE"
	} > "$1/.zshrc.new"
	mv "$1/.zshrc.new" "$1/.zshrc"
}
setup_rc_optimized() { # $1 = HOME: the same rc, after wayu init + wayu optimize --yes
	setup_rc_stack "$1"
	mkdir -p "$1/.config"
	in_home "$1" wayu init --shell zsh </dev/null >/dev/null
	wayu_completions "$1"
	printf '%s\n' 'source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh"' | cat - "$1/.zshrc" > "$1/.zshrc.new"
	mv "$1/.zshrc.new" "$1/.zshrc"
	in_home "$1" wayu --shell zsh optimize --yes </dev/null >"$1/optimize.log" 2>&1
	in_home "$1" wayu --shell zsh build >/dev/null
}

setup() { # $1 = contender name, $2 = HOME
	case $1 in
		floor) setup_floor "$2" ;;
		plain) setup_plain "$2" ;;
		plain-c) setup_plain "$2" -C ;;
		wayu) setup_wayu "$2" 0 ;;
		wayu-defer) setup_wayu "$2" 1 ;;
		oh-my-zsh) setup_omz "$2" ;;
		zinit) setup_zinit "$2" 0 ;;
		zinit-turbo) setup_zinit "$2" 1 ;;
		antidote) setup_antidote "$2" 0 ;;
		antidote-defer) setup_antidote "$2" 1 ;;
		rc-before) setup_rc_stack "$2" ;;
		rc-wayu-optimize) setup_rc_optimized "$2" ;;
		*) echo "unknown contender: $1" >&2; exit 64 ;;
	esac
}

METRICS="first_prompt_lag_ms first_command_lag_ms command_lag_ms input_lag_ms exit_time_ms"

# median <metric> <raw file>
median() {
	sed -n "s/^$1=( \(.*\) )\$/\1/p" "$2" | tr ' ' '\n' | sort -g |
		awk '{ v[NR] = $1 } END { if (NR == 0) { print "nan"; exit } if (NR % 2) printf "%.1f", v[(NR + 1) / 2]; else printf "%.1f", (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
}
flag() { sed -n "s/^$1=( \([0-9]\).*/\1/p" "$2"; }

bench() { # $1 = contender
	local h out
	h=$(new_home "$1")
	setup "$1" "$h"
	# Warm: dumps, .zwc, bundles, zinit's compiled plugins.
	in_home "$h" "$ZSH_EXE" -lic exit </dev/null >/dev/null 2>&1 || true
	sleep 1
	in_home "$h" "$ZSH_EXE" -lic exit </dev/null >/dev/null 2>&1 || true
	sleep 1
	out=$work/results/$1.raw
	printf '%-18s' "$1"
	if ! in_home "$h" "$ZSH_EXE" "$work/src/zsh-bench/zsh-bench" --raw --iters "$ITERS" --git no </dev/null >"$out" 2>"$out.err"; then
		echo "zsh-bench failed:"; cat "$out.err"; return 1
	fi
	printf '%9s %9s %9s %9s %9s   %s%s%s\n' \
		"$(median first_prompt_lag_ms "$out")" "$(median first_command_lag_ms "$out")" \
		"$(median command_lag_ms "$out")" "$(median input_lag_ms "$out")" "$(median exit_time_ms "$out")" \
		"$(flag has_compsys "$out")" "$(flag has_autosuggestions "$out")" "$(flag has_syntax_highlighting "$out")"
}

header() {
	printf '\n== %s (zsh-bench, median of %s iterations, ms) ==\n' "$1" "$ITERS"
	printf '%-18s%9s %9s %9s %9s %9s   %s\n' contender 1st-prmpt 1st-cmd cmd-lag input exit "csh"
}

for s in $SCENARIOS; do
	case $s in
		stack)
			header "same workload: compinit + autosuggestions + syntax-highlighting + 20 aliases + 10 PATH + 5 env"
			for c in $ONLY; do bench "$c"; done ;;
		optimize)
			header "hand-grown .zshrc (compinit + 3x eval \"\$(tool completion zsh)\", ~25 ms each) before/after wayu optimize"
			for c in rc-before rc-wayu-optimize; do bench "$c"; done ;;
	esac
done
echo
echo "csh = has_compsys / has_autosuggestions / has_syntax_highlighting as zsh-bench detected them"

if [ -n "$JSON" ]; then
	{
		echo '{'
		printf '  "iters": %s,\n  "zsh": "%s",\n  "results": {\n' "$ITERS" "$("$ZSH_EXE" --version)"
		first=1
		for f in "$work"/results/*.raw; do
			n=$(basename "$f" .raw)
			[ $first = 1 ] || echo ','
			first=0
			printf '    "%s": {' "$n"
			sep=
			for m in $METRICS; do printf '%s"%s": %s' "$sep" "$m" "$(median $m "$f")"; sep=', '; done
			printf '}'
		done
		printf '\n  }\n}\n'
	} > "$JSON"
	echo "wrote $JSON"
fi
