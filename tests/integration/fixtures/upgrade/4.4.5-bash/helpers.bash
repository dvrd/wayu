# helpers.bash - Support functions for wayu

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
