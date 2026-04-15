#!/usr/bin/env fish

# Wayu Shell Initialization - Main Orchestrator (Fish)
# This file loads all configuration modules in the correct order

# === 1. Core Configuration ===
# Load constants and environment variables first (they may be needed by other modules)
if test -f "$HOME/.config/wayu/constants.fish"
    source "$HOME/.config/wayu/constants.fish"
end

# === 2. PATH Configuration ===
# Set up PATH with duplicate prevention
if test -f "$HOME/.config/wayu/path.fish"
    source "$HOME/.config/wayu/path.fish"
end

# === 3. Functions Loading ===
# Load custom shell functions from the functions directory
if test -d "$HOME/.config/wayu/functions"
    for f in $HOME/.config/wayu/functions/*.fish
        if test -f "$f"
            source "$f"
        end
    end
end

# === 4. Completions Setup ===
# Fish completions are loaded from ~/.config/fish/completions/
# Add wayu completions path if exists
if test -d "$HOME/.config/wayu/completions"
    set -gx fish_complete_path "$HOME/.config/wayu/completions" $fish_complete_path
end

# === 5. Plugins Loading ===
# Load Wayu-managed plugins
if test -f "$HOME/.config/wayu/plugins.fish"
    source "$HOME/.config/wayu/plugins.fish"
end
if test -f "$HOME/.config/wayu/plugins/config.fish"
    source "$HOME/.config/wayu/plugins/config.fish"
end

# === 6. Aliases ===
# Load command aliases and shortcuts
if test -f "$HOME/.config/wayu/aliases.fish"
    source "$HOME/.config/wayu/aliases.fish"
end

# === 7. External Tools Initialization ===
# Initialize external tools and utilities (NVM, Starship, Zoxide, etc.)
if test -f "$HOME/.config/wayu/tools.fish"
    source "$HOME/.config/wayu/tools.fish"
end

# === 8. Extra Config ===
# User-defined shell snippets (hooks, env loaders, ad-hoc settings)
if test -f "$HOME/.config/wayu/extra.fish"
    source "$HOME/.config/wayu/extra.fish"
end
