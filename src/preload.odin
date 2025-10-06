package wayu

import "core:os"
import "core:fmt"

// Preload configuration templates for faster startup
// This reduces filesystem I/O by embedding common configuration templates

PATH_TEMPLATE :: `#!/usr/bin/env zsh

add_to_path() {
    local dir="$1"
    local position="${2:-prepend}"  # prepend or append, default is prepend

    # Check if directory exists
    if [ ! -d "$dir" ]; then
        return 1
    fi

    # Check if directory is already in PATH
    if [[ ":$PATH:" == *":$dir:"* ]]; then
        return 0
    fi

    # Add to PATH
    if [ "$position" = "append" ]; then
        export PATH="$PATH:$dir"
    else
        export PATH="$dir:$PATH"
    fi
}

export PATH=$(echo "$PATH" | awk -v RS=':' -v ORS=':' '!seen[$0]++' | sed 's/:$//')
`

ALIASES_TEMPLATE :: `#!/usr/bin/env zsh

# Shell Aliases Configuration
# This file contains all command aliases and shortcuts
`

CONSTANTS_TEMPLATE :: `#!/usr/bin/env zsh

# Environment Constants and Configuration Variables
# This file centralizes all constant definitions and environment variables
`

INIT_TEMPLATE :: `#!/usr/bin/env zsh

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
if [ -d "$HOME/.config/wayu/functions" ]; then
    for f in "$HOME/.config/wayu/functions"/*; do
        if [ -f "$f" ]; then
            source "$f"
        fi
    done
fi

# === 4. Completions Setup ===
# Add custom completions directory to fpath
fpath=(~/.config/wayu/completions $fpath)

# Initialize completion system
autoload -U add-zsh-hook compinit
compinit

# === 5. Plugins Loading ===
# Load Wayu plugins
[ -f "$HOME/.config/wayu/plugins/autocomplete/init.zsh" ] && source "$HOME/.config/wayu/plugins/autocomplete/init.zsh"

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
`

TOOLS_TEMPLATE :: `#!/usr/bin/env zsh

# External Tool Initialization
# This file handles the setup and initialization of external tools and utilities

# Add your tool initializations below. Examples:

# === NVM (Node Version Manager) Setup ===
# Uncomment and adjust path if using NVM
# export NVM_DIR="$HOME/.nvm"
# [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
# [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# === Starship Prompt ===
# Uncomment if using Starship
# eval "$(starship init zsh)"

# === Zoxide - Smarter cd ===
# Uncomment if using Zoxide
# eval "$(zoxide init zsh)"

# === Other Tools ===
# Add your other tool initializations here
`

// Common configuration directory paths
CONFIG_PATHS :: []string{
	"/usr/local/bin",
	"/usr/bin",
	"/bin",
	"/usr/sbin",
	"/sbin",
	"/opt/homebrew/bin",
	"/opt/homebrew/sbin",
	"$HOME/go/bin",
	"$HOME/.local/bin",
	"$HOME/.cargo/bin",
}

// Helper to initialize config files with templates if they don't exist
init_config_file :: proc(file_path: string, template: string) -> bool {
	// Check if file already exists
	if os.exists(file_path) {
		return true
	}

	debug("Creating config file: %s", file_path)

	write_ok := os.write_entire_file(file_path, transmute([]byte)template)
	if !write_ok {
		debug("Failed to create config file: %s", file_path)
		return false
	}

	debug("Created config file: %s", file_path)
	return true
}

// Initialize all config files
init_config_files :: proc() {
	config_dir := fmt.aprintf("%s", WAYU_CONFIG)
	defer delete(config_dir)

	path_file := fmt.aprintf("%s/%s", WAYU_CONFIG, PATH_FILE)
	defer delete(path_file)
	init_config_file(path_file, PATH_TEMPLATE)

	alias_file := fmt.aprintf("%s/%s", WAYU_CONFIG, ALIAS_FILE)
	defer delete(alias_file)
	init_config_file(alias_file, ALIASES_TEMPLATE)

	constants_file := fmt.aprintf("%s/%s", WAYU_CONFIG, CONSTANTS_FILE)
	defer delete(constants_file)
	init_config_file(constants_file, CONSTANTS_TEMPLATE)
}

// Fast path lookup for common paths
is_common_path :: proc(path: string) -> bool {
	for common_path in CONFIG_PATHS {
		if path == common_path {
			return true
		}
	}
	return false
}