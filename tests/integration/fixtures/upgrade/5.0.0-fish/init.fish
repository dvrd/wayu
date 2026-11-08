#!/usr/bin/env fish

# Wayu Shell Initialization - Main Orchestrator (Fish)
# This file loads all configuration modules in the correct order

# Determine config directory (supports WAYU_CONFIG_DIR override for testing)
set -gx WAYU_CONFIG_DIR (test -n "$WAYU_CONFIG_DIR"; and echo "$WAYU_CONFIG_DIR"; or echo "$HOME/.config/wayu")
set -gx WAYU_DATA_DIR (test -n "$WAYU_DATA_DIR"; and echo "$WAYU_DATA_DIR"; or echo "$HOME/.config/wayu")
# === Fast path: compiled core from wayu.toml ===
# After wayu v3.10 wayu.toml is the source of truth. When core.fish
# exists we source it exclusively — the legacy individual files below
# stay empty and would just be no-ops anyway.
if test -f "$WAYU_DATA_DIR/core.fish"
    source "$WAYU_DATA_DIR/core.fish"
    if test -f "$WAYU_CONFIG_DIR/extra.fish"
        source "$WAYU_CONFIG_DIR/extra.fish"
    end
    if test -f "$WAYU_CONFIG_DIR/tools.fish"
        source "$WAYU_CONFIG_DIR/tools.fish"
    end
    return 0
end

# === Legacy fallback (pre-wayu.toml era) ===

# === 1. Core Configuration ===
# Load constants and environment variables first (they may be needed by other modules)
source "$WAYU_DATA_DIR/constants.fish"

# === 2. PATH Configuration ===
# Set up PATH with duplicate prevention
source "$WAYU_DATA_DIR/path.fish"

# === 3. Functions Loading ===
# Load custom shell functions from the functions directory
if test -d "$WAYU_CONFIG_DIR/functions"
    for f in $WAYU_CONFIG_DIR/functions/*.fish
        if test -f "$f"
            source "$f"
        end
    end
end

# === 4. Completions Setup ===
# Fish completions are loaded from ~/.config/fish/completions/
# Add wayu completions path if exists
if test -d "$WAYU_DATA_DIR/completions"
    set -gx fish_complete_path "$WAYU_DATA_DIR/completions" $fish_complete_path
end

# === 5. Plugins Loading ===
# Load Wayu-managed plugins
if test -f "$WAYU_DATA_DIR/plugins.fish"
    source "$WAYU_DATA_DIR/plugins.fish"
end
if test -f "$WAYU_DATA_DIR/plugins/config.fish"
    source "$WAYU_DATA_DIR/plugins/config.fish"
end

# === 6. Aliases ===
# Load command aliases and shortcuts
source "$WAYU_DATA_DIR/aliases.fish"

# === 7. External Tools Initialization ===
# Initialize external tools and utilities (NVM, Starship, Zoxide, etc.)
source "$WAYU_CONFIG_DIR/tools.fish"

# === 8. Extra Config ===
# User-defined shell snippets (hooks, env loaders, ad-hoc settings)
if test -f "$WAYU_CONFIG_DIR/extra.fish"
    source "$WAYU_CONFIG_DIR/extra.fish"
end
