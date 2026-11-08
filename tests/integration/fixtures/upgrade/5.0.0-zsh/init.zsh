#!/usr/bin/env zsh

# Wayu Shell Initialization - Main Orchestrator
# This file loads all configuration modules in the correct order

# Determine directories (supports overrides for testing)
: ${WAYU_CONFIG_DIR:=$HOME/.config/wayu}
: ${WAYU_DATA_DIR:=$HOME/.config/wayu}

# === Fast path: compiled core from wayu.toml ===
# After wayu v3.10 wayu.toml is the source of truth. 'wayu path/alias/
# constants add', 'wayu template apply' and 'wayu build eval' all write
# into core.zsh. When it exists we source it exclusively — the legacy
# individual files below stay empty and would just be no-ops anyway.
# core.zsh sources plugins.zsh and lazy.zsh (which sources tools.zsh and
# extra.zsh exactly once), so nothing else is sourced here.
if [ -f "$WAYU_DATA_DIR/core.zsh" ]; then
    source "$WAYU_DATA_DIR/core.zsh"
    return 0 2>/dev/null || true
fi

# === Legacy fallback (pre-wayu.toml era) ===

# === 1. Core Configuration ===
# Load constants and environment variables first (they may be needed by other modules)
source "$WAYU_DATA_DIR/constants.zsh"

# === 2. PATH Configuration ===
# Set up PATH with duplicate prevention
source "$WAYU_DATA_DIR/path.zsh"

# === 3. Functions Loading ===
# Load custom shell functions from the functions directory
() { emulate -L zsh; typeset -ga _wayu_fn_files; _wayu_fn_files=( "$WAYU_CONFIG_DIR/functions"/*(N-.) ) }
for _wayu_f in "${_wayu_fn_files[@]}"; do source "$_wayu_f"; done
unset _wayu_f _wayu_fn_files

# === 4. Completions Setup ===
# Add custom completions directory to fpath
fpath=("$WAYU_DATA_DIR/completions" "${fpath[@]}")

# Initialize completion system
autoload -U add-zsh-hook compinit
compinit

# === 5. Plugins Loading ===
# Load Wayu-managed plugins
if [ -f "$WAYU_DATA_DIR/plugins.zsh" ]; then source "$WAYU_DATA_DIR/plugins.zsh"; fi
if [ -f "$WAYU_DATA_DIR/plugins/config.zsh" ]; then source "$WAYU_DATA_DIR/plugins/config.zsh"; fi

# === 6. Aliases ===
# Load command aliases and shortcuts
source "$WAYU_DATA_DIR/aliases.zsh"

# === 7. External Tools Initialization ===
# Initialize external tools and utilities (NVM, Starship, Zoxide, etc.)
source "$WAYU_CONFIG_DIR/tools.zsh"

# === Completion Notes ===
# Additional completions are loaded from:
# - $WAYU_DATA_DIR/completions (jj, bun, etc.)
# - Tools may add their own completions during initialization

# === 8. Extra Config ===
# User-defined shell snippets (hooks, env loaders, ad-hoc settings)
if [ -f "$WAYU_CONFIG_DIR/extra.zsh" ]; then source "$WAYU_CONFIG_DIR/extra.zsh"; fi
