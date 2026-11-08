# helpers.zsh - Support functions for wayu

# ============================================================================
# EVALCACHE - Cache eval output, regenerate if binary changed or args differ
# ============================================================================
_wayu_evalcache() {
  local cmd="$1"
  shift
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/wayu/evalcache"
  local key="${cmd//[^A-Za-z0-9._-]/_}"
  if [ "$#" -gt 0 ]; then
    local args="$*"
    key="${key}__${args//[^A-Za-z0-9._-]/_}"
  fi
  key="${key:0:200}"
  local cache_file="$cache_dir/$key"
  local bin_path
  bin_path="$(command -v "$cmd" 2>/dev/null)"

  # Skip silently if the tool isn't installed
  [ -z "$bin_path" ] && return 0

  [ -d "$cache_dir" ] || mkdir -p "$cache_dir"

  # Regenerate if: cache doesn't exist, is empty, or binary is newer than cache
  if [ ! -s "$cache_file" ] || [ "$bin_path" -nt "$cache_file" ]; then
    local tmp_file="${cache_file}.tmp.$$"
    if "$cmd" "$@" > "$tmp_file" 2>/dev/null && [ -s "$tmp_file" ]; then
      mv -f "$tmp_file" "$cache_file"
    else
      # Failed or empty output - drop the tmpfile, leave any prior good cache alone
      rm -f "$tmp_file"
      [ -s "$cache_file" ] || return 1
    fi
  fi

  source "$cache_file"
}

# ============================================================================
# ZSH-DEFER BUILT-IN - Implementation without external plugin
# Defers execution until the prompt is ready and idle
# ============================================================================

# Deferred command queue
(( ${+_wayu_defer_queue} )) || typeset -ga _wayu_defer_queue

zsh-defer() {
  local delay=0
  while [[ "$1" == -* ]]; do
    case "$1" in
      -t|--time) delay="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  local cmd="$*"
  [[ -n "$cmd" ]] && _wayu_defer_queue+=("$cmd:$delay")
  return 0
}

# Process one deferred command
_wayu_defer_process_one() {
  (( ${#_wayu_defer_queue} )) || return 0
  local item="${_wayu_defer_queue[1]}"
  local cmd="${item%:*}"
  local delay="${item##*:}"
  shift _wayu_defer_queue
  if [[ "$delay" != "0" && -n "$delay" ]]; then
    (sleep "$delay" && eval "$cmd") &!
  else
    eval "$cmd" 2>/dev/null
  fi
  return 0
}

# Ask ourselves (via USR1) to continue draining the queue shortly.
_wayu_defer_kick() {
  ( sleep 0.1 && kill -USR1 $$ 2>/dev/null ) &!
}

# precmd hook - runs deferred commands after the first prompt
_wayu_defer_precmd() {
  (( ${#_wayu_defer_queue} )) || return 0
  _wayu_defer_process_one
  (( ${#_wayu_defer_queue} )) && _wayu_defer_kick
  return 0
}

# Single USR1 handler: drains zsh-defer AND forwards to the async prompt.
TRAPUSR1() {
  if (( ${#_wayu_defer_queue} )); then
    _wayu_defer_process_one
    (( ${#_wayu_defer_queue} )) && _wayu_defer_kick
  fi
  (( ${+functions[_wayu_async_on_usr1]} )) && _wayu_async_on_usr1
  return 0
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _wayu_defer_precmd

# ============================================================================
# WAYU COMPILE - Compile init files to bytecode (manual command)
# ============================================================================
wayu_compile() {
  local f
  echo "Compiling init files to bytecode..."
  for f in core helpers lazy login plugins; do
    [[ -f "${WAYU_DATA_DIR:-$HOME/.config/wayu}/$f.zsh" ]] || continue
    zcompile "${WAYU_DATA_DIR:-$HOME/.config/wayu}/$f.zsh" 2>/dev/null && echo "✓ $f.zsh"
  done
  echo "Done. Loading 2-3x faster."
}
