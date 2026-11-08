#!/usr/bin/env zsh

# Wayu Shell Initialization - Main Orchestrator
# This file loads all configuration modules in the correct order

# Determine config directory (supports WAYU_CONFIG_DIR override for testing)
: ${WAYU_CONFIG_DIR:=$g_ctx.home/.config/wayu}

# === Fast path: compiled init-core from wayu.toml ===
# After wayu v3.10 wayu.toml is the source of truth. 'wayu path/alias/
# constants add', 'wayu template apply' and 'wayu build eval' all write
# into init-core.zsh. When it exists we source it exclusively — the legacy
# individual files below stay empty and would just be no-ops anyway.
if [ -f "$WAYU_CONFIG_DIR/init-core.zsh" ]; then
    source "$WAYU_CONFIG_DIR/init-core.zsh"
    [ -f "$WAYU_CONFIG_DIR/extra.zsh" ] && source "$WAYU_CONFIG_DIR/extra.zsh"
    [ -f "$WAYU_CONFIG_DIR/tools.zsh" ] && source "$WAYU_CONFIG_DIR/tools.zsh"
    return 0 2>/dev/null || true
fi

# === Legacy fallback (pre-wayu.toml era) ===

# === 1. Core Configuration ===
# Load constants and environment variables first (they may be needed by other modules)
source "$WAYU_CONFIG_DIR/constants.zsh"

# === 2. PATH Configuration ===
# Set up PATH with duplicate prevention
source "$WAYU_CONFIG_DIR/path.zsh"

# === 3. Functions Loading ===
# Load custom shell functions from the functions directory
for f in "$WAYU_CONFIG_DIR/functions"/*(N); do
    [[ -f "$f" ]] && source "$f"
done

# === 4. Completions Setup ===
# Add custom completions directory to fpath
fpath=("$WAYU_CONFIG_DIR/completions" $fpath)

# Initialize completion system
autoload -U add-zsh-hook compinit
compinit

# === 5. Plugins Loading ===
# Load Wayu-managed plugins
[ -f "$WAYU_CONFIG_DIR/plugins.zsh" ] && source "$WAYU_CONFIG_DIR/plugins.zsh"
[ -f "$WAYU_CONFIG_DIR/plugins/config.zsh" ] && source "$WAYU_CONFIG_DIR/plugins/config.zsh"

# === 6. Aliases ===
# Load command aliases and shortcuts
source "$WAYU_CONFIG_DIR/aliases.zsh"

# === 7. External Tools Initialization ===
# Initialize external tools and utilities (NVM, Starship, Zoxide, etc.)
source "$WAYU_CONFIG_DIR/tools.zsh"

# === Completion Notes ===
# Additional completions are loaded from:
# - $WAYU_CONFIG_DIR/completions (jj, bun, etc.)
# - Tools may add their own completions during initialization

# === 8. Extra Config ===
# User-defined shell snippets (hooks, env loaders, ad-hoc settings)
[ -f "$WAYU_CONFIG_DIR/extra.zsh" ] && source "$WAYU_CONFIG_DIR/extra.zsh"
