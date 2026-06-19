package wayu

import "core:os"
import "core:fmt"

// Preload configuration templates for faster startup
// This reduces filesystem I/O by embedding common configuration templates

PATH_TEMPLATE_ZSH :: `#!/usr/bin/env zsh

# Centralized PATH registry
# Managed by wayu - Add entries below
# Note: add_to_path() calls from v2.x are replaced by WAYU_PATHS array entries
WAYU_PATHS=(
)

# Build PATH from registry with deduplication
for dir in "${WAYU_PATHS[@]}"; do
    # Check if directory exists
    if [ ! -d "$dir" ]; then
        continue
    fi

    # Check if directory is already in PATH
    if [[ ":$PATH:" == *":$dir:"* ]]; then
        continue
    fi

    # Add to PATH (prepend)
    export PATH="$dir:$PATH"
done

# Final deduplication pass (Zsh-compatible method)
remove_path_duplicates() {
    local new_path=""
    local dir
    local -a dirs
    dirs=(${(s/:/)PATH})
    for dir in "${dirs[@]}"; do
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

ALIASES_TEMPLATE_ZSH :: `#!/usr/bin/env zsh

# Shell Aliases Configuration
# This file contains all command aliases and shortcuts
`

// Template for alias-sources.conf — lists external alias sources shown by
// "wayu alias list". Not a shell script; plain config format.
ALIAS_SOURCES_TEMPLATE :: `# alias-sources.conf - External alias source registry
# Managed by wayu - edit manually to add external alias sources
#
# Format (one source per line):
#   dir <path> <command_template>
#
# <path>             : directory whose entries become alias names
# <command_template> : command to run; {name} is replaced with the entry name
#
# Example - fabric AI patterns:
#   dir ~/.config/fabric/patterns fabric --pattern {name}
#
`

CONSTANTS_TEMPLATE_ZSH :: `#!/usr/bin/env zsh

# Environment Constants and Configuration Variables
# This file centralizes all constant definitions and environment variables
`

INIT_TEMPLATE_ZSH :: `#!/usr/bin/env zsh

# Wayu Shell Initialization - Main Orchestrator
# This file loads all configuration modules in the correct order

# Determine directories (supports overrides for testing)
: ${WAYU_CONFIG_DIR:=$HOME/.config/wayu}
: ${WAYU_DATA_DIR:=$HOME/.local/share/wayu}

# === Fast path: compiled core from wayu.toml ===
# After wayu v3.10 wayu.toml is the source of truth. 'wayu path/alias/
# constants add', 'wayu template apply' and 'wayu build eval' all write
# into core.zsh. When it exists we source it exclusively — the legacy
# individual files below stay empty and would just be no-ops anyway.
if [ -f "$WAYU_DATA_DIR/core.zsh" ]; then
    source "$WAYU_DATA_DIR/core.zsh"
    [ -f "$WAYU_CONFIG_DIR/extra.zsh" ] && source "$WAYU_CONFIG_DIR/extra.zsh"
    [ -f "$WAYU_CONFIG_DIR/tools.zsh" ] && source "$WAYU_CONFIG_DIR/tools.zsh"
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
for f in "$WAYU_CONFIG_DIR/functions"/*(N); do
    [[ -f "$f" ]] && source "$f"
done

# === 4. Completions Setup ===
# Add custom completions directory to fpath
fpath=("$WAYU_DATA_DIR/completions" $fpath)

# Initialize completion system
autoload -U add-zsh-hook compinit
compinit

# === 5. Plugins Loading ===
# Load Wayu-managed plugins
[ -f "$WAYU_DATA_DIR/plugins.zsh" ] && source "$WAYU_DATA_DIR/plugins.zsh"
[ -f "$WAYU_DATA_DIR/plugins/config.zsh" ] && source "$WAYU_DATA_DIR/plugins/config.zsh"

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
[ -f "$WAYU_CONFIG_DIR/extra.zsh" ] && source "$WAYU_CONFIG_DIR/extra.zsh"
`

TOOLS_TEMPLATE_ZSH :: `#!/usr/bin/env zsh
#
# tools.zsh — user escape hatch for tool init not modeled by [tools] in wayu.toml.
#
# Most lazy loaders are now declarative in wayu.toml:
#
#   [tools]
#   nvm    = { kind = "nvm" }
#   conda  = { kind = "conda" }
#   zoxide = { kind = "evalcache", args = "init zsh" }
#   atuin  = { kind = "evalcache", args = "init zsh --disable-up-arrow", eager = true }
#   sdk    = { kind = "lazy", init_script = "$HOME/.sdkman/bin/sdkman-init.sh", hook_commands = ["sdk"] }
#
# Run 'wayu build eval' after editing wayu.toml. The corresponding lazy loaders
# are emitted into lazy.zsh so they work in every interactive shell
# (login, non-login, Ghostty/Zellij/tmux panes).
#
# Use this file ONLY for one-off, machine-specific tool setup that doesn't fit
# any built-in recipe. Do not eagerly source large init scripts here — they
# block prompt rendering. Wrap them in a lazy loader instead.
`

EXTRA_TEMPLATE_ZSH :: `#!/usr/bin/env zsh

# Extra Shell Configuration
# This file is for custom shell snippets that don't fit into other wayu categories.
# Anything written here is sourced at the end of init, before PATH deduplication.
#
# Common uses:
#   - Conditional hooks (chpwd, preexec, precmd)
#   - Third-party tool env loaders (cargo, bun, conda, etc.)
#   - Custom functions that don't belong in ~/.config/wayu/functions
#   - Completion fpath additions
#   - Ad-hoc exports and settings
`

// Bash-compatible templates
PATH_TEMPLATE_BASH :: `#!/usr/bin/env bash

# Centralized PATH registry
# Managed by wayu - Add entries below
WAYU_PATHS=(
)

# Build PATH from registry with deduplication
for dir in "${WAYU_PATHS[@]}"; do
    # Check if directory exists
    if [ ! -d "$dir" ]; then
        continue
    fi

    # Check if directory is already in PATH
    if [[ ":$PATH:" == *":$dir:"* ]]; then
        continue
    fi

    # Add to PATH (prepend)
    export PATH="$dir:$PATH"
done

# Final deduplication pass (Bash-compatible method)
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

# Determine directories (supports overrides for testing)
: ${WAYU_CONFIG_DIR:=$HOME/.config/wayu}
: ${WAYU_DATA_DIR:=$HOME/.local/share/wayu}

# === Fast path: compiled core from wayu.toml ===
# See the zsh template comment for rationale.
if [ -f "$WAYU_DATA_DIR/core.bash" ]; then
    source "$WAYU_DATA_DIR/core.bash"
    [ -f "$WAYU_CONFIG_DIR/extra.bash" ] && source "$WAYU_CONFIG_DIR/extra.bash"
    [ -f "$WAYU_CONFIG_DIR/tools.bash" ] && source "$WAYU_CONFIG_DIR/tools.bash"
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
[ -f "$WAYU_DATA_DIR/plugins.bash" ] && source "$WAYU_DATA_DIR/plugins.bash"
[ -f "$WAYU_DATA_DIR/plugins/config.zsh" ] && source "$WAYU_DATA_DIR/plugins/config.zsh"

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
[ -f "$WAYU_CONFIG_DIR/extra.bash" ] && source "$WAYU_CONFIG_DIR/extra.bash"
`

TOOLS_TEMPLATE_BASH :: `#!/usr/bin/env bash
#
# tools.bash — user escape hatch for tool init not modeled by [tools] in wayu.toml.
# Prefer the declarative [tools] table in wayu.toml; this file is for one-off setup.

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

EXTRA_TEMPLATE_BASH :: `#!/usr/bin/env bash

# Extra Shell Configuration
# This file is for custom shell snippets that don't fit into other wayu categories.
# Anything written here is sourced at the end of init, before PATH deduplication.
#
# Common uses:
#   - Third-party tool env loaders (cargo, bun, conda, etc.)
#   - Custom functions that don't belong in ~/.config/wayu/functions
#   - Ad-hoc exports and settings
`

// Fish shell templates
PATH_TEMPLATE_FISH :: `#!/usr/bin/env fish

# Centralized PATH registry
# Managed by wayu - Add entries below
set -gx WAYU_PATHS

# Build PATH from registry with deduplication
for dir in $WAYU_PATHS
    # Check if directory exists
    if not test -d "$dir"
        continue
    end

    # Check if directory is already in PATH
    if contains "$dir" $PATH
        continue
    end

    # Add to PATH (prepend)
    set -gx PATH "$dir" $PATH
end
`

ALIASES_TEMPLATE_FISH :: `#!/usr/bin/env fish

# Shell Aliases Configuration
# This file contains all command aliases and shortcuts
# Use 'alias' command for Fish shell
`

CONSTANTS_TEMPLATE_FISH :: `#!/usr/bin/env fish

# Environment Constants and Configuration Variables
# This file centralizes all constant definitions and environment variables
# Use 'set -gx' for exported globals in Fish
`

INIT_TEMPLATE_FISH :: `#!/usr/bin/env fish

# Wayu Shell Initialization - Main Orchestrator (Fish)
# This file loads all configuration modules in the correct order

# Determine config directory (supports WAYU_CONFIG_DIR override for testing)
set -gx WAYU_CONFIG_DIR (test -n "$WAYU_CONFIG_DIR"; and echo "$WAYU_CONFIG_DIR"; or echo "$HOME/.config/wayu")
set -gx WAYU_DATA_DIR (test -n "$WAYU_DATA_DIR"; and echo "$WAYU_DATA_DIR"; or echo "$HOME/.local/share/wayu")
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
`

TOOLS_TEMPLATE_FISH :: `#!/usr/bin/env fish

# External Tool Initialization (Fish)
# This file handles the setup and initialization of external tools and utilities

# Add your tool initializations below. Examples:

# === NVM (Node Version Manager) Setup ===
# Uncomment and adjust path if using NVM
# set -gx NVM_DIR "$HOME/.nvm"
# if test -s "$NVM_DIR/nvm.sh"
#     bass source "$NVM_DIR/nvm.sh"
# end

# === Starship Prompt ===
# Uncomment if using Starship
# starship init fish | source

# === Zoxide - Smarter cd ===
# Uncomment if using Zoxide
# zoxide init fish | source

# === Other Tools ===
# Add your other tool initializations here
`

EXTRA_TEMPLATE_FISH :: `#!/usr/bin/env fish

# Extra Shell Configuration
# This file is for custom shell snippets that don't fit into other wayu categories.
# Anything written here is sourced at the end of init.
#
# Common uses:
#   - Third-party tool env loaders (cargo, bun, conda, etc.)
#   - Custom functions that don't belong in ~/.config/wayu/functions
#   - Ad-hoc exports and settings
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

	write_err := os.write_entire_file(file_path, transmute([]byte)template)
	if write_err != nil {
		debug("Failed to create config file: %s", file_path)
		return false
	}

	debug("Created config file: %s", file_path)
	return true
}

// Template selection functions based on shell type.
//
// All six getters pick one of three shell-specific templates for the current
// `ShellType`. They all share the same dispatch logic, so they delegate to
// `select_template`. `.UNKNOWN` falls back to the Bash template for POSIX-ish
// compatibility.
//
// NOTE: keep these as named procs (not inlined) so they can be used as
// function pointers — see `main.odin:778-783` where they're stored in a slice.

select_template :: proc(shell: ShellType, zsh, bash, fish: string) -> string {
	switch shell {
	case .ZSH:
		return zsh
	case .BASH:
		return bash
	case .FISH:
		return fish
	case .UNKNOWN:
		return bash // Default to Bash for compatibility
	}
	return bash
}

get_path_template :: proc(shell: ShellType) -> string {
	return select_template(shell, PATH_TEMPLATE_ZSH, PATH_TEMPLATE_BASH, PATH_TEMPLATE_FISH)
}

get_aliases_template :: proc(shell: ShellType) -> string {
	return select_template(shell, ALIASES_TEMPLATE_ZSH, ALIASES_TEMPLATE_BASH, ALIASES_TEMPLATE_FISH)
}

get_constants_template :: proc(shell: ShellType) -> string {
	return select_template(shell, CONSTANTS_TEMPLATE_ZSH, CONSTANTS_TEMPLATE_BASH, CONSTANTS_TEMPLATE_FISH)
}

get_init_template :: proc(shell: ShellType) -> string {
	return select_template(shell, INIT_TEMPLATE_ZSH, INIT_TEMPLATE_BASH, INIT_TEMPLATE_FISH)
}

get_tools_template :: proc(shell: ShellType) -> string {
	return select_template(shell, TOOLS_TEMPLATE_ZSH, TOOLS_TEMPLATE_BASH, TOOLS_TEMPLATE_FISH)
}

get_extra_template :: proc(shell: ShellType) -> string {
	return select_template(shell, EXTRA_TEMPLATE_ZSH, EXTRA_TEMPLATE_BASH, EXTRA_TEMPLATE_FISH)
}

// Initialize all config files with shell-specific templates
init_config_files :: proc() {
	shell := wayu.shell
	config_dir := fmt.aprintf("%s", wayu.config)
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

	extra_file := get_config_file_with_fallback("extra", shell)
	defer delete(extra_file)
	if !os.exists(extra_file) {
		init_config_file(extra_file, get_extra_template(shell))
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