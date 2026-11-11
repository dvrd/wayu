#!/usr/bin/env bash
# Builds a throwaway HOME for the demo recording (docs/demo/demo.tape).
#
#   docs/demo/setup.sh [DIR] > env.sh && source env.sh   # enter it
#
# Everything lives under DIR (default: a new mktemp dir): HOME, ZDOTDIR,
# WAYU_CONFIG_DIR, WAYU_DATA_DIR and the XDG dirs all point inside it, so
# the real ~/.config/wayu and ~/.local/share/wayu are never read or written.
# The secrets backend is a key file in that dir; every value is fake.
# Uses the repo's bin/wayu (WAYU_BIN overrides); build it first: ./build_it
set -eu

repo=$(cd "$(dirname "$0")/../.." && pwd)
WAYU_BIN=${WAYU_BIN:-$repo/bin/wayu}
[ -x "$WAYU_BIN" ] || { echo "setup.sh: $WAYU_BIN missing; run ./build_it" >&2; exit 1; }

demo=${1:-$(mktemp -d "${TMPDIR:-/tmp}/wayu-demo.XXXXXX")}
case $demo in
	"$HOME"|"$HOME/") echo "setup.sh: refusing to use the real HOME" >&2; exit 1 ;;
esac
rm -rf "$demo"
mkdir -p "$demo"
demo=$(cd "$demo" && pwd)

export HOME=$demo
export ZDOTDIR=$demo
export XDG_CONFIG_HOME=$demo/.config
export XDG_DATA_HOME=$demo/.local/share
export XDG_CACHE_HOME=$demo/.cache
export XDG_RUNTIME_DIR=$demo/.run
export WAYU_CONFIG_DIR=$demo/.config/wayu
export WAYU_DATA_DIR=$demo/.local/share/wayu
export SHELL=/bin/zsh
unset VISUAL EDITOR
mkdir -p "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" "$demo/bin"
chmod 700 "$XDG_RUNTIME_DIR"

# wayu itself, first on PATH (a link, so the rc PATH stays short).
ln -s "$WAYU_BIN" "$demo/bin/wayu"
export PATH="$demo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

"$WAYU_BIN" init --shell zsh </dev/null >/dev/null 2>&1

cat > "$WAYU_CONFIG_DIR/wayu.toml" <<'EOF'
[shell]
type = "zsh"

[prompt]
enabled = true
format  = "{dir}{git_branch}{character} "

[prompt.dir]
format = "[$basename](cyan bold) "

[prompt.git_branch]
format = "[$branch](magenta) "

[prompt.character]
success_symbol = "[❯](green)"
error_symbol   = "[❯](red)"

[prompt.interactive]
async_rprompt = false

[scripts]
default_lang = "python"

[secrets]
backend = "file"
EOF

# A few directories and entries so the lists look lived-in.
mkdir -p "$demo/.cargo/bin" "$demo/go/bin" "$demo/.bun/bin" "$demo/projects/api"
w() { "$WAYU_BIN" "$@" >/dev/null; }
w path add "$demo/go/bin"
w path add "$demo/.bun/bin"
w alias add ll 'ls -lah'
w alias add k kubectl
w const add GOPATH "$demo/go"
w const add PAGER less
"$WAYU_BIN" build >/dev/null

# A project dir with a git branch for the prompt.
git -C "$demo/projects/api" init -q -b main
git -C "$demo/projects/api" -c user.name=demo -c user.email=demo@example.com \
	commit -q --allow-empty -m init

# The interactive shell: wayu's init line and nothing else.
cat > "$demo/.zshrc" <<EOF
source "\${WAYU_DATA_DIR:-\${XDG_DATA_HOME:-\$HOME/.local/share}/wayu}/init.zsh"
EOF

# The editor `wayu script new` opens: writes a finished script (the demo
# can't show typing into an editor in the time it has).
cat > "$demo/bin/demo-editor" <<'EOF'
#!/bin/sh
cat > "$1" <<'PY'
#!/usr/bin/env python3
"""Ask the model API, using the key from `wayu secrets run`."""
import os, sys

key = os.environ.get("OPENAI_API_KEY")
if not key:
    sys.exit("ask: OPENAI_API_KEY not set")
print(f"ask: key {key[:8]}… ({len(key)} chars) → POST /v1/responses")
PY
EOF
chmod +x "$demo/bin/demo-editor"

# Printed for the caller to source: enter the demo dir and replace the shell
# with a zsh whose environment is only these variables (env -i), so nothing
# from the recording machine's environment shows up in `const list`.
cat <<EOF
cd '$demo/projects/api' && exec env -i HOME='$demo' ZDOTDIR='$demo' USER=demo LOGNAME=demo LANG=en_US.UTF-8 TERM="\$TERM" COLORTERM=truecolor XDG_CONFIG_HOME='$XDG_CONFIG_HOME' XDG_DATA_HOME='$XDG_DATA_HOME' XDG_CACHE_HOME='$XDG_CACHE_HOME' XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' WAYU_CONFIG_DIR='$WAYU_CONFIG_DIR' WAYU_DATA_DIR='$WAYU_DATA_DIR' SHELL=/bin/zsh EDITOR='$demo/bin/demo-editor' PATH='$PATH' /bin/zsh -i
EOF
