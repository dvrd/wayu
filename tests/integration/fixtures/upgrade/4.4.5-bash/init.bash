#!/usr/bin/env bash

# Wayu Shell Initialization - Main Orchestrator (Bash)
# This file loads all configuration modules in the correct order

# Determine directories (supports overrides for testing)
: ${WAYU_CONFIG_DIR:=$HOME/.config/wayu}
: ${WAYU_DATA_DIR:=$HOME/.config/wayu}

# === Fast path: compiled core from wayu.toml ===
# See the zsh template comment for rationale (core.bash sources
# plugins.bash and lazy.bash, which sources tools.bash/extra.bash once).
if [ -f "$WAYU_DATA_DIR/core.bash" ]; then
    source "$WAYU_DATA_DIR/core.bash"
    return 0 2>/dev/null || true
fi

# === Legacy fallback (pre-wayu.toml era) ===

# === 1. Core Configuration ===
# Load constants and environment variables first (they may be needed by other modules)
source "$WAYU_DATA_DIR/constants.bash"

# === 2. PATH Configuration ===
# Set up PATH with duplicate prevention
source "$WAYU_DATA_DIR/path.bash"

# === 3. Functions Loading ===
# Load custom shell functions from the functions directory
if [ -d "$WAYU_CONFIG_DIR/functions" ]; then
    for f in "$WAYU_CONFIG_DIR/functions"/*; do
        if [ -f "$f" ]; then
            source "$f"
        fi
    done
fi

# === 4. Bash Completion ===
# Initialize Bash programmable completion
if ! shopt -oq posix; then
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        source /usr/share/bash-completion/bash_completion
    elif [ -f /etc/bash_completion ]; then
        source /etc/bash_completion
    fi
fi

# Load custom completions
if [ -d "$WAYU_DATA_DIR/completions" ]; then
    for f in "$WAYU_DATA_DIR/completions"/*.bash-completion; do
        if [ -f "$f" ]; then
            source "$f"
        fi
    done
fi

# === 5. Plugins Loading ===
# Load Wayu-managed plugins
if [ -f "$WAYU_DATA_DIR/plugins.bash" ]; then source "$WAYU_DATA_DIR/plugins.bash"; fi

# === 6. Aliases ===
# Load command aliases and shortcuts
source "$WAYU_DATA_DIR/aliases.bash"

# === 7. External Tools Initialization ===
# Initialize external tools and utilities (NVM, Starship, Zoxide, etc.)
source "$WAYU_CONFIG_DIR/tools.bash"

# === Completion Notes ===
# Additional completions are loaded from:
# - $WAYU_DATA_DIR/completions (tools may install .bash-completion files)
# - Tools may add their own completions during initialization

# === 8. Extra Config ===
# User-defined shell snippets (hooks, env loaders, ad-hoc settings)
if [ -f "$WAYU_CONFIG_DIR/extra.bash" ]; then source "$WAYU_CONFIG_DIR/extra.bash"; fi
