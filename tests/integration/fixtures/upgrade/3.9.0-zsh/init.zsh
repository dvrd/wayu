#!/usr/bin/env zsh

# Wayu Shell Initialization - Main Orchestrator
# This file loads all configuration modules in the correct order

# === 1. Core Configuration ===
# Load constants and environment variables first (they may be needed by other modules)
source "$HOME/.config/wayu/constants.zsh"

# === 2. PATH Configuration ===
# Set up PATH with duplicate prevention
source "$HOME/.config/wayu/path.zsh"

# === 3. Functions Loading ===
# Load custom shell functions from the functions directory
for f in "$HOME/.config/wayu/functions"/*(N); do
    [[ -f "$f" ]] && source "$f"
done

# === 4. Completions Setup ===
# Add custom completions directory to fpath
fpath=(~/.config/wayu/completions $fpath)

# Initialize completion system
autoload -U add-zsh-hook compinit
compinit

# === 5. Plugins Loading ===
# Load Wayu-managed plugins
[ -f "$HOME/.config/wayu/plugins.zsh" ] && source "$HOME/.config/wayu/plugins.zsh"
[ -f "$HOME/.config/wayu/plugins/config.zsh" ] && source "$HOME/.config/wayu/plugins/config.zsh"

# === 6. Aliases ===
# Load command aliases and shortcuts
source "$HOME/.config/wayu/aliases.zsh"

# === 7. External Tools Initialization ===
# Initialize external tools and utilities (NVM, Starship, Zoxide, etc.)
source "$HOME/.config/wayu/tools.zsh"

# === Completion Notes ===
# Additional completions are loaded from:
# - ~/.config/wayu/completions (jj, bun, etc.)
# - Tools may add their own completions during initialization

# === 8. Extra Config ===
# User-defined shell snippets (hooks, env loaders, ad-hoc settings)
[ -f "$HOME/.config/wayu/extra.zsh" ] && source "$HOME/.config/wayu/extra.zsh"
