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
# Load Wayu-managed plugins
[ -f "$HOME/.config/wayu/plugins.zsh" ] && source "$HOME/.config/wayu/plugins.zsh"

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

// Bash-compatible templates
PATH_TEMPLATE_BASH :: `#!/usr/bin/env bash

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

# Remove duplicates from PATH (Bash-compatible method)
remove_path_duplicates() {
    local new_path=""
    local dir
    IFS=':' read -ra DIRS <<< "$PATH"
    for dir in "${DIRS[@]}"; do
        if [[ ":$new_path:" != *":$dir:"* ]] && [ -n "$dir" ]; then
            if [ -z "$new_path" ]; then
                new_path="$dir"
            else
                new_path="$new_path:$dir"
            fi
        fi
    done
    export PATH="$new_path"
}

remove_path_duplicates
`

ALIASES_TEMPLATE_BASH :: `#!/usr/bin/env bash

# Shell Aliases Configuration
# This file contains all command aliases and shortcuts
`

CONSTANTS_TEMPLATE_BASH :: `#!/usr/bin/env bash

# Environment Constants and Configuration Variables
# This file centralizes all constant definitions and environment variables
`

INIT_TEMPLATE_BASH :: `#!/usr/bin/env bash

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
`

TOOLS_TEMPLATE_BASH :: `#!/usr/bin/env bash

# External Tool Initialization (Bash)
# This file handles the setup and initialization of external tools and utilities

# Add your tool initializations below. Examples:

# === NVM (Node Version Manager) Setup ===
# Uncomment and adjust path if using NVM
# export NVM_DIR="$HOME/.nvm"
# [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
# [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# === Starship Prompt ===
# Uncomment if using Starship
# eval "$(starship init bash)"

# === Zoxide - Smarter cd ===
# Uncomment if using Zoxide
# eval "$(zoxide init bash)"

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

// Template selection functions based on shell type
get_path_template :: proc(shell: ShellType) -> string {
	switch shell {
	case .BASH:
		return PATH_TEMPLATE_BASH
	case .ZSH:
		return PATH_TEMPLATE
	case .UNKNOWN:
		return PATH_TEMPLATE_BASH // Default to Bash for compatibility
	}
	return PATH_TEMPLATE_BASH
}

get_aliases_template :: proc(shell: ShellType) -> string {
	switch shell {
	case .BASH:
		return ALIASES_TEMPLATE_BASH
	case .ZSH:
		return ALIASES_TEMPLATE
	case .UNKNOWN:
		return ALIASES_TEMPLATE_BASH
	}
	return ALIASES_TEMPLATE_BASH
}

get_constants_template :: proc(shell: ShellType) -> string {
	switch shell {
	case .BASH:
		return CONSTANTS_TEMPLATE_BASH
	case .ZSH:
		return CONSTANTS_TEMPLATE
	case .UNKNOWN:
		return CONSTANTS_TEMPLATE_BASH
	}
	return CONSTANTS_TEMPLATE_BASH
}

get_init_template :: proc(shell: ShellType) -> string {
	switch shell {
	case .BASH:
		return INIT_TEMPLATE_BASH
	case .ZSH:
		return INIT_TEMPLATE
	case .UNKNOWN:
		return INIT_TEMPLATE_BASH
	}
	return INIT_TEMPLATE_BASH
}

get_tools_template :: proc(shell: ShellType) -> string {
	switch shell {
	case .BASH:
		return TOOLS_TEMPLATE_BASH
	case .ZSH:
		return TOOLS_TEMPLATE
	case .UNKNOWN:
		return TOOLS_TEMPLATE_BASH
	}
	return TOOLS_TEMPLATE_BASH
}

// Initialize all config files with shell-specific templates
init_config_files :: proc() {
	shell := DETECTED_SHELL
	config_dir := fmt.aprintf("%s", WAYU_CONFIG)
	defer delete(config_dir)

	// Use fallback-aware config file creation to preserve backward compatibility
	path_file := get_config_file_with_fallback("path", shell)
	defer delete(path_file)
	// Only create if neither the preferred file nor fallback exists
	if !os.exists(path_file) {
		init_config_file(path_file, get_path_template(shell))
	}

	alias_file := get_config_file_with_fallback("aliases", shell)
	defer delete(alias_file)
	if !os.exists(alias_file) {
		init_config_file(alias_file, get_aliases_template(shell))
	}

	constants_file := get_config_file_with_fallback("constants", shell)
	defer delete(constants_file)
	if !os.exists(constants_file) {
		init_config_file(constants_file, get_constants_template(shell))
	}
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