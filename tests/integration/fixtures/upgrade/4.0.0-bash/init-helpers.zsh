# init-helpers.zsh - Support functions for wayu

# ============================================================================
# EVALCACHE - Cache eval output, regenerate if binary changed
# ============================================================================
_wayu_evalcache() {
  local cmd="$1"
  shift
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/wayu/evalcache"
  local cache_file="$cache_dir/${cmd//\//_}"
  local bin_path="$(command -v $cmd 2>/dev/null)"

  # Skip silently if the tool isn't installed
  [[ -z "$bin_path" ]] && return 0

  [[ -d "$cache_dir" ]] || mkdir -p "$cache_dir"

  # Regenerate if: cache doesn't exist, is empty, or binary is newer than cache
  if [[ ! -s "$cache_file" ]] || [[ "$bin_path" -nt "$cache_file" ]]; then
    local tmp_file="${cache_file}.tmp.$$"
    if "$cmd" "$@" > "$tmp_file" 2>/dev/null && [[ -s "$tmp_file" ]]; then
      mv -f "$tmp_file" "$cache_file"
    else
      # Failed or empty output — drop the tmpfile, leave any prior good cache alone
      rm -f "$tmp_file"
      [[ ! -s "$cache_file" ]] && return 1
    fi
  fi

  source "$cache_file"
}

# ============================================================================
# ZSH-DEFER BUILT-IN - Implementation without external plugin
# Defers execution until the prompt is ready and idle
# ============================================================================

# Deferred command queue
(( ${+_wayu_defer_queue} )) || typeset -a _wayu_defer_queue

# Main zsh-defer function
zsh-defer() {
  local delay=0
  
  # Parse options
  while [[ "$1" == -* ]]; do
    case "$1" in
      -t|--time) delay="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  
  # Add to queue
  local cmd="$*"
  [[ -n "$cmd" ]] && _wayu_defer_queue+=("$cmd:$delay")
}

# Process one deferred command
_wayu_defer_process_one() {
  [[ ${#_wayu_defer_queue} -eq 0 ]] && return 0
  
  local item="${_wayu_defer_queue[1]}"
  local cmd="${item%:*}"
  local delay="${item##*:}"
  
  shift _wayu_defer_queue
  
  # Execute
  if [[ "$delay" != "0" && "$delay" != "" ]]; then
    (sleep "$delay" && eval "$cmd") &
  else
    eval "$cmd" 2>/dev/null
  fi
  
  return ${#_wayu_defer_queue}
}

# precmd hook - runs deferred commands after the first prompt
_wayu_defer_precmd() {
  [[ ${#_wayu_defer_queue} -eq 0 ]] && return
  
  # Execute first one immediately
  _wayu_defer_process_one
  
  # If more remain, schedule execution between commands
  if [[ ${#_wayu_defer_queue} -gt 0 ]]; then
    # Use a small trick: TMOUT with trap
    ( sleep 0.1 && kill -USR1 $$ 2>/dev/null ) &
  fi
}

# Signal handler to continue processing
trap '_wayu_defer_process_one' USR1

# Instalar hook
autoload -Uz add-zsh-hook
add-zsh-hook precmd _wayu_defer_precmd

# ============================================================================
# WAYU COMPILE - Compilar init files a bytecode (comando manual)
# ============================================================================
wayu_compile() {
  echo "Compilando init files a bytecode..."
  zcompile ~/.config/wayu/init-core.zsh 2>/dev/null && echo "✓ init-core.zsh"
  zcompile ~/.config/wayu/init-lazy.zsh 2>/dev/null && echo "✓ init-lazy.zsh"
  zcompile ~/.config/wayu/init-login.zsh 2>/dev/null && echo "✓ init-login.zsh"
  echo "Done. Loading 2-3x faster."
}
