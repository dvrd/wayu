#!/usr/bin/env zsh
# init-core.zsh - ESENCIAL (menos de 10ms)
# Generado automáticamente por wayu build

# === PATH ===
export PATH="@HOME@/tools:@HOME@/bin dir:$PATH"
# Deduplicate PATH (preserva orden, elimina duplicados)
typeset -U path PATH

# === Environment (from wayu.toml [env]) ===
export EDITOR="nvim"
export GREETING="hello world"
export PROJECTS="@HOME@/projects"

# === Aliases (from wayu.toml [[aliases]]) ===
alias ll="ls -la"
alias gs="git status --short"
alias q="echo "it's quoted""

# === wayu shell wrapper ===
wayu() {
  command wayu "$@"
  local _exit=$?
  if [[ $_exit -eq 0 && "$1" == "path" && "$2" == "add" ]]; then
    command wayu build eval > /dev/null 2>&1
    export PATH="${3}:$PATH"
  fi
  return $_exit
}

# === Completions ===
fpath=("$HOME/.config/wayu/completions" $fpath)
autoload -Uz compinit && compinit -C

# === Plugins críticos (inmediato) ===
[ -f "$HOME/.config/wayu/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ] && source "$HOME/.config/wayu/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
[ -f "$HOME/.config/wayu/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ] && source "$HOME/.config/wayu/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
[ -f "$HOME/.config/wayu/plugins/config.zsh" ] && source "$HOME/.config/wayu/plugins/config.zsh"

# === Load helpers (zsh-defer propio) ===
source "@HOME@/.config/wayu/init-helpers.zsh" 2>/dev/null || true

# === Prompt (wayu native, interactive) ===
# === Interactive Prompt Features ===

# === Base Prompt (from starship.toml) ===
# === Wayu Native Prompt (from starship.toml) ===

typeset -g _WAYU_GIT_BRANCH=""
typeset -g _WAYU_GIT_DIR=""

_wayu_update_git_info() {
  local git_info
  git_info="$(git rev-parse --short HEAD --show-toplevel 2>/dev/null)"
  if [[ -n "$git_info" ]]; then
    _WAYU_GIT_DIR="${git_info##*$'\n'}"
    _WAYU_GIT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "${git_info%%$'\n'*}")"
  else
    _WAYU_GIT_BRANCH=""
    _WAYU_GIT_DIR=""
  fi
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _wayu_update_git_info

_wayu_prompt_full() {
  local result=""
  # _WAYU_LAST_EXIT set by _wayu_prompt_master

  # Username (only in SSH)
  if [[ -n "$SSH_CONNECTION" ]]; then
    result+="%F{7}%B%n%b%F{reset}@"
  fi

  # Directory
  result+="%F{6}%B%~%b%F{reset} "

  # Git branch
  if [[ -n "$_WAYU_GIT_BRANCH" ]]; then
    result+="%F{5}%B${_WAYU_GIT_BRANCH}%b%F{reset} "
  fi

  # Character (success/error with VI mode support)
  local char_symbol char_color
  case "$_WAYU_VI_MODE" in
    INSERT)
      char_symbol="➜" ;;
    NORMAL)
      char_symbol="❮" ;;
    VISUAL)
      char_symbol="❮" ;;
    REPLACE|REPLACE_ONE)
      char_symbol="❮" ;;
    *)
      # Fallback: usar exit code
      if [[ ${_WAYU_LAST_EXIT:-0} -eq 0 ]]; then
        char_symbol="➜"
      else
        char_symbol="✗"
      fi
    ;;
  esac
  case "$_WAYU_VI_MODE" in
    INSERT) char_color="202" ;;
    NORMAL) char_color="2" ;;
    VISUAL) char_color="129" ;;
    REPLACE|REPLACE_ONE) char_color="129" ;;
    *)
      # Fallback: usar exit code
      if [[ ${_WAYU_LAST_EXIT:-0} -eq 0 ]]; then
        char_color="2"
      else
        char_color="1"
      fi
    ;;
  esac
  result+="%F{${char_color}}%B${char_symbol}%b%F{reset} "

  echo "$result"
}


# State variables
typeset -g _WAYU_PROMPT_MODE="full"
typeset -g _WAYU_VI_MODE="INSERT"
typeset -g _WAYU_CONTEXT="default"
typeset -g _WAYU_CONTEXT_VER=""
typeset -g _WAYU_ASYNC_DATA=""

# === Feature: Toggle Prompt (Minimal/Full) ===
_wayu_toggle_prompt() {
  if [[ "$_WAYU_PROMPT_MODE" == "full" ]]; then
    _WAYU_PROMPT_MODE="minimal"
  else
    _WAYU_PROMPT_MODE="full"
  fi
  zle reset-prompt
}
zle -N _wayu_toggle_prompt
bindkey '^P' _wayu_toggle_prompt

# === Feature: VI Mode Indicator ===
# Activar modo VI para selección visual
bindkey -v
export KEYTIMEOUT=1  # Reducir delay al cambiar modos
bindkey -M viins '^?' backward-delete-char
bindkey -M viins '^H' backward-delete-char

# Variables para tracking de modo
typeset -g _WAYU_VI_MODE="INSERT"

function zle-keymap-select {
  case $KEYMAP in
    vicmd) _WAYU_VI_MODE="NORMAL" ;;
    main|viins) _WAYU_VI_MODE="INSERT" ;;
    visual|vivis) _WAYU_VI_MODE="VISUAL" ;;
  esac
  zle reset-prompt
}
zle -N zle-keymap-select
zle -N zle-line-init zle-keymap-select

# Wrappers para visual mode (zle-keymap-select no lo detecta solo)
_wayu_visual_mode() {
  zle visual-mode
  _WAYU_VI_MODE="VISUAL"
  zle reset-prompt
}
_wayu_visual_line_mode() {
  zle visual-line-mode
  _WAYU_VI_MODE="VISUAL"
  zle reset-prompt
}
zle -N _wayu_visual_mode
zle -N _wayu_visual_line_mode
bindkey -M vicmd 'v' _wayu_visual_mode
bindkey -M vicmd 'V' _wayu_visual_line_mode

# Salir de visual mode: 'i' → INSERT, Esc → NORMAL (cancelando selección)
bindkey -M visual 'i' vi-insert
_wayu_visual_exit() {
  zle deactivate-region
  zle vi-cmd-mode
}
zle -N _wayu_visual_exit
bindkey -M visual $'\e' _wayu_visual_exit

# === Feature: Context-Aware Prompt ===
# File-only detection (instant). Version fetched async.
_wayu_detect_context() {
  _WAYU_CONTEXT_VER=""
  if [[ -f "Cargo.toml" ]]; then _WAYU_CONTEXT="rust"
  elif [[ -f "bun.lockb" ]] || [[ -f "bunfig.toml" ]]; then _WAYU_CONTEXT="bun"
  elif [[ -f "gleam.toml" ]]; then _WAYU_CONTEXT="gleam"
  elif [[ -f "Package.swift" ]]; then _WAYU_CONTEXT="swift"
  elif [[ -f "pubspec.yaml" ]]; then _WAYU_CONTEXT="dart"
  elif [[ -f "composer.json" ]]; then _WAYU_CONTEXT="php"
  elif [[ -f "Gemfile" ]] || [[ -f ".ruby-version" ]]; then _WAYU_CONTEXT="ruby"
  elif [[ -f "mix.exs" ]]; then _WAYU_CONTEXT="elixir"
  elif [[ -f "rebar.config" ]] || [[ -f "erlang.mk" ]]; then _WAYU_CONTEXT="erlang"
  elif [[ -f "stack.yaml" ]] || [[ -f "cabal.project" ]]; then _WAYU_CONTEXT="haskell"
  elif [[ -f "Project.toml" ]] || [[ -f "Manifest.toml" ]]; then _WAYU_CONTEXT="julia"
  elif [[ -f "ols.json" ]] || (){ [[ -e $1 ]] } *.odin(NY1) || (){ [[ -e $1 ]] } src/*.odin(NY1); then _WAYU_CONTEXT="odin"
  elif [[ -f "go.mod" ]]; then _WAYU_CONTEXT="golang"
  elif [[ -f "nim.cfg" ]]; then _WAYU_CONTEXT="nim"
  elif [[ -f "dune" ]]; then _WAYU_CONTEXT="ocaml"
  elif [[ -f "flake.nix" ]] || [[ -f "default.nix" ]]; then _WAYU_CONTEXT="nix"
  elif [[ -f "deno.json" ]] || [[ -f "deno.jsonc" ]]; then _WAYU_CONTEXT="deno"
  elif [[ -f "elm.json" ]]; then _WAYU_CONTEXT="elm"
  elif [[ -f "shard.yml" ]]; then _WAYU_CONTEXT="crystal"
  elif [[ -f "cpanfile" ]]; then _WAYU_CONTEXT="perl"
  elif [[ -f "buf.yaml" ]]; then _WAYU_CONTEXT="buf"
  elif [[ -f "package.json" ]]; then _WAYU_CONTEXT="nodejs"
  elif [[ -f "pom.xml" ]] || [[ -f "build.gradle" ]]; then _WAYU_CONTEXT="java"
  elif [[ -f "build.sbt" ]]; then _WAYU_CONTEXT="scala"
  elif [[ -f "requirements.txt" ]] || [[ -f "pyproject.toml" ]]; then _WAYU_CONTEXT="python"
  elif [[ -f "build.zig" ]] || [[ -f "build.zig.zon" ]]; then _WAYU_CONTEXT="zig"
  elif [[ -f "DESCRIPTION" ]]; then _WAYU_CONTEXT="rlang"
  elif [[ -f ".lua-version" ]]; then _WAYU_CONTEXT="lua"
  elif [[ -f "Dockerfile" ]] || [[ -f "docker-compose.yml" ]]; then _WAYU_CONTEXT="docker"
  elif [[ -f ".aws" ]] || [[ -d ".aws" ]]; then _WAYU_CONTEXT="aws"
  else _WAYU_CONTEXT="default"
  fi
}

autoload -Uz add-zsh-hook
add-zsh-hook chpwd _wayu_detect_context
_wayu_detect_context  # Detect on startup

# === Feature: Async RPROMPT ===
typeset -g _WAYU_ASYNC_FD=

_wayu_version_cmd() {
  case "$1" in
    rust)    rustc --version 2>/dev/null | awk '{print $2}' ;;
    bun)     bun --version 2>/dev/null ;;
    dart)    dart --version 2>/dev/null | awk '{print $4}' ;;
    ruby)    ruby --version 2>/dev/null | awk '{print $2}' ;;
    elixir)  elixir --version 2>/dev/null | awk 'NR==1{print $2}' ;;
    odin)    odin version 2>/dev/null | awk '{print $3}' ;;
    golang)  go version 2>/dev/null | awk '{print $3}' | sed 's/go//' ;;
    deno)    deno --version 2>/dev/null | head -1 | awk '{print $2}' ;;
    nodejs)  node --version 2>/dev/null | sed 's/v//' ;;
    python)  python3 --version 2>/dev/null | awk '{print $2}' ;;
    zig)     zig version 2>/dev/null ;;
    *)       ;;
  esac
}

_wayu_async_worker() {
  local git_pending=""
  if [[ -n "$_WAYU_GIT_BRANCH" ]]; then
    git_pending="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$git_pending" -gt 0 ]]; then
      git_pending="%F{242} ✎${git_pending}%f"
    else
      git_pending=""
    fi
  fi

  # Fetch version string for current context (async — never blocks prompt)
  local ver="$(_wayu_version_cmd "$_WAYU_CONTEXT")"

  # Write results to temp file and signal parent
  local tmpf="${TMPDIR:-/tmp}/.wayu_async_$$"
  printf '%s\n%s' "$git_pending" "$ver" > "$tmpf"
  kill -USR1 $$ 2>/dev/null || true
}

TRAPUSR1() {
  local tmpf="${TMPDIR:-/tmp}/.wayu_async_$$"
  if [[ -f "$tmpf" ]]; then
    local lines=("${(@f)$(< "$tmpf")}")
    _WAYU_ASYNC_DATA="${lines[1]}"
    _WAYU_CONTEXT_VER="${lines[2]}"
    rm -f "$tmpf"
  fi
  zle && zle reset-prompt
}

_wayu_start_async() {
  (_wayu_async_worker &)
}

add-zsh-hook precmd _wayu_start_async

# === Feature: Transient Prompt ===
_wayu_prompt_transient() {
  local result=""
  result+="%~ "
  if [[ $? -eq 0 ]]; then
    result+="➜ "
  else
    result+="✗ "
  fi
  echo "$result"
}

# === Master Prompt Function ===
_wayu_prompt_master() {
  local exit_code=$?
  local result=""

  # Guardar exit_code para funciones hijas
  export _WAYU_LAST_EXIT=$exit_code

  # Select prompt based on mode
  if [[ "$_WAYU_PROMPT_MODE" == "minimal" ]]; then
    result+="$(_wayu_prompt_transient)"
  else
    result+="$(_wayu_prompt_full)"
  fi

  echo "$result"
}

setopt promptsubst
PROMPT=$'\n''$(_wayu_prompt_master)'
RPROMPT='${_WAYU_ASYNC_DATA}'

# === Lazy init (tools, extra config) ===
source "@HOME@/.config/wayu/init-lazy.zsh"

# === Login shell ===
[[ -o login ]] && source "@HOME@/.config/wayu/init-login.zsh" 2>/dev/null || true

