#!/usr/bin/env bash

# Wayu Shell Initialization - Main Orchestrator (Bash)
# This file loads all configuration modules in the correct order

# === 1. Core Configuration ===
# Load constants and environment variables first (they may be needed by other modules)
source "$HOME/.config/wayu/constants.bash"

# === 2. PATH Configuration ===
# Set up PATH with duplicate prevention
source "$HOME/.config/wayu/path.bash"

# === 3. Functions Loading ===
# Load custom shell functions from the functions directory
if [ -d "$HOME/.config/wayu/functions" ]; then
    for f in "$HOME/.config/wayu/functions"/*; do
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
if [ -d "$HOME/.config/wayu/completions" ]; then
    for f in "$HOME/.config/wayu/completions"/*.bash-completion; do
        if [ -f "$f" ]; then
            source "$f"
        fi
    done
fi

# === 5. Plugins Loading ===
# Load Wayu-managed plugins
[ -f "$HOME/.config/wayu/plugins.bash" ] && source "$HOME/.config/wayu/plugins.bash"
[ -f "$HOME/.config/wayu/plugins/config.zsh" ] && source "$HOME/.config/wayu/plugins/config.zsh"

# === 6. Aliases ===
# Load command aliases and shortcuts
source "$HOME/.config/wayu/aliases.bash"

# === 7. External Tools Initialization ===
# Initialize external tools and utilities (NVM, Starship, Zoxide, etc.)
source "$HOME/.config/wayu/tools.bash"

# === Completion Notes ===
# Additional completions are loaded from:
# - ~/.config/wayu/completions (tools may install .bash-completion files)
# - Tools may add their own completions during initialization

# === 8. Extra Config ===
# User-defined shell snippets (hooks, env loaders, ad-hoc settings)
[ -f "$HOME/.config/wayu/extra.bash" ] && source "$HOME/.config/wayu/extra.bash"
