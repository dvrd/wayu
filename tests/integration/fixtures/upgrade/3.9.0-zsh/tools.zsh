#!/usr/bin/env zsh

# External Tool Initialization
# This file handles the setup and initialization of external tools and utilities
# OPTIMIZED: Uses lazy-loading and cached evals for fast shell startup

# === Cache Directory ===
_WAYU_CACHE="$HOME/.cache/wayu"
[[ -d "$_WAYU_CACHE" ]] || mkdir -p "$_WAYU_CACHE"

# === Helper: Cached eval ===
# Runs "command args" once, caches output, sources cache on subsequent loads.
# Cache is invalidated when the binary is newer than the cache file.
# Usage: _wayu_cached_eval "name" command arg1 arg2 ...
_wayu_cached_eval() {
  local name="$1"; shift
  local cache_file="$_WAYU_CACHE/$name.zsh"
  local bin_path="$(command -v "$1" 2>/dev/null)"

  if [[ -z "$bin_path" ]]; then
    return 1
  fi

  # Regenerate if cache missing or binary is newer
  if [[ ! -f "$cache_file" ]] || [[ "$bin_path" -nt "$cache_file" ]]; then
    "$@" > "$cache_file" 2>/dev/null
  fi

  source "$cache_file"
}

# === Helper: Lazy-load wrapper ===
# Creates wrapper functions that load a tool on first use.
# Usage: _wayu_lazy_load "_loader_func" cmd1 cmd2 cmd3 ...
# The loader function must unset the wrapper functions before loading.

# Add your tool initializations below. Examples:

# === NVM (Node Version Manager) Setup ===
# Uncomment and adjust path if using NVM
# _wayu_setup_nvm_lazy() {
#   local nvm_default_path="$NVM_DIR/alias/default"
#   if [[ -f "$nvm_default_path" ]]; then
#     local default_version="$(<"$nvm_default_path")"
#     while [[ -f "$NVM_DIR/alias/$default_version" ]]; do
#       default_version="$(<"$NVM_DIR/alias/$default_version")"
#     done
#     if [[ "$default_version" == "node" ]]; then
#       local latest_dir="$(ls -d "$NVM_DIR/versions/node/"v* 2>/dev/null | sort -V | tail -1)"
#       [[ -d "$latest_dir/bin" ]] && export PATH="$latest_dir/bin:$PATH"
#     else
#       for node_dir in "$NVM_DIR/versions/node/v${default_version}"*(N); do
#         [[ -d "$node_dir/bin" ]] && export PATH="$node_dir/bin:$PATH" && break
#       done
#     fi
#   fi
#   _wayu_load_nvm() {
#     if (( $_WAYU_NVM_LOADED )); then return; fi
#     _WAYU_NVM_LOADED=1
#     unset -f nvm node npm npx corepack 2>/dev/null
#     [ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"
#     add-zsh-hook -d chpwd _wayu_chpwd_nvmrc
#     add-zsh-hook chpwd load-nvmrc
#   }
#   _wayu_run_node_bin() {
#     local cmd="$1"; shift
#     unset -f "$cmd" 2>/dev/null
#     local bin_path="$(command -v "$cmd" 2>/dev/null)"
#     if [[ -n "$bin_path" ]]; then "$bin_path" "$@"
#     else _wayu_load_nvm; "$cmd" "$@"; fi
#     eval "$cmd() { _wayu_run_node_bin $cmd \"\$@\" }"
#   }
#   nvm()      { _wayu_load_nvm; nvm "$@" }
#   node()     { _wayu_run_node_bin node "$@" }
#   npm()      { _wayu_run_node_bin npm "$@" }
#   npx()      { _wayu_run_node_bin npx "$@" }
#   corepack() { _wayu_run_node_bin corepack "$@" }
#   _wayu_fast_nvmrc() {
#     local nvmrc_file=""
#     [[ -f ".nvmrc" ]] && nvmrc_file=".nvmrc"
#     [[ -f ".node-version" ]] && nvmrc_file=".node-version"
#     [[ -z "$nvmrc_file" ]] && return 1
#     local requested="$(<"$nvmrc_file")"
#     requested="${requested#v}"; requested="${requested## }"; requested="${requested%% }"
#     local match_dir=""
#     for node_dir in "$NVM_DIR/versions/node/"v${requested}*(N); do
#       [[ -d "$node_dir/bin" ]] && match_dir="$node_dir"
#     done
#     if [[ -n "$match_dir" ]]; then
#       local -a path_parts new_parts
#       path_parts=("${(@s/:/)PATH}")
#       for p in "${path_parts[@]}"; do
#         [[ "$p" == ${NVM_DIR}/versions/node/* ]] && continue
#         new_parts+=("$p")
#       done
#       export PATH="$match_dir/bin:${(j/:/)new_parts}"
#       return 0
#     fi
#     return 1
#   }
#   _wayu_chpwd_nvmrc() {
#     if [[ -f ".nvmrc" ]] || [[ -f ".node-version" ]]; then
#       _wayu_fast_nvmrc || { _wayu_load_nvm; load-nvmrc; }
#     fi
#   }
#   add-zsh-hook chpwd _wayu_chpwd_nvmrc
#   _wayu_fast_nvmrc
# }
# _wayu_setup_nvm_lazy

# === Starship Prompt ===
# Uncomment if using Starship
# _wayu_cached_eval "starship" starship init zsh

# === Zoxide - Smarter cd ===
# Uncomment if using Zoxide
# _wayu_cached_eval "zoxide" zoxide init zsh

# === Atuin - Shell History ===
# Uncomment if using Atuin
# _wayu_cached_eval "atuin" atuin init zsh

# === Other Tools ===
# Add your other tool initializations here
# Use _wayu_cached_eval for any "eval $(tool init zsh)" pattern
# Use lazy-load wrappers for heavy tools (NVM, SDKMAN, Conda, etc.)
