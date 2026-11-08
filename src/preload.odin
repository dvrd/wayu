package wayu

import "core:os"
import "core:fmt"

// Preload configuration templates for faster startup
// This reduces filesystem I/O by embedding common configuration templates

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

INIT_TEMPLATE_ZSH :: `#!/usr/bin/env zsh

# Wayu Shell Initialization - Main Orchestrator
# Sources core.<ext>, which wayu compiles from wayu.toml

# Directories. wayu writes this file into its data dir, so that dir is this
# file's own location (WAYU_DATA_DIR / WAYU_CONFIG_DIR given to wayu need not
# be exported to the shell). The config dir holds wayu.toml.
_wayu_d=${${(%):-%x}:a:h}
if [ -f "$_wayu_d/init.zsh" ]; then WAYU_DATA_DIR=$_wayu_d; fi
unset _wayu_d
: ${WAYU_DATA_DIR:=$HOME/.config/wayu}
if [ -z "${WAYU_CONFIG_DIR-}" ]; then
    if [ -f "$WAYU_DATA_DIR/wayu.toml" ]; then WAYU_CONFIG_DIR=$WAYU_DATA_DIR; else WAYU_CONFIG_DIR=$HOME/.config/wayu; fi
fi

# === Compiled core ===
# core.zsh is generated from wayu.toml (any wayu write, or 'wayu build') and
# sources plugins.zsh, tools.zsh and extra.zsh itself (once each).
if [ -f "$WAYU_DATA_DIR/core.zsh" ]; then
    source "$WAYU_DATA_DIR/core.zsh"
else
    echo "wayu: $WAYU_DATA_DIR/core.zsh is missing; run 'wayu build'" >&2
fi
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
# Run 'wayu build' after editing wayu.toml. The corresponding lazy loaders
# are emitted into core.zsh so they work in every interactive shell
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
INIT_TEMPLATE_BASH :: `#!/usr/bin/env bash

# Wayu Shell Initialization - Main Orchestrator (Bash)
# Sources core.<ext>, which wayu compiles from wayu.toml

# Directories. wayu writes this file into its data dir, so that dir is this
# file's own location (WAYU_DATA_DIR / WAYU_CONFIG_DIR given to wayu need not
# be exported to the shell). The config dir holds wayu.toml.
_wayu_d=${BASH_SOURCE[0]-}
case $_wayu_d in */*) _wayu_d=${_wayu_d%/*} ;; *) _wayu_d=. ;; esac
case $_wayu_d in /*) ;; *) _wayu_d=$PWD/$_wayu_d ;; esac
if [ -f "$_wayu_d/init.bash" ]; then WAYU_DATA_DIR=$_wayu_d; fi
unset _wayu_d
: ${WAYU_DATA_DIR:=$HOME/.config/wayu}
if [ -z "${WAYU_CONFIG_DIR-}" ]; then
    if [ -f "$WAYU_DATA_DIR/wayu.toml" ]; then WAYU_CONFIG_DIR=$WAYU_DATA_DIR; else WAYU_CONFIG_DIR=$HOME/.config/wayu; fi
fi

# === Compiled core ===
# core.bash is generated from wayu.toml (any wayu write, or 'wayu build') and
# sources plugins.bash, tools.bash and extra.bash itself (once each).
if [ -f "$WAYU_DATA_DIR/core.bash" ]; then
    source "$WAYU_DATA_DIR/core.bash"
else
    echo "wayu: $WAYU_DATA_DIR/core.bash is missing; run 'wayu build'" >&2
fi
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
INIT_TEMPLATE_FISH :: `#!/usr/bin/env fish

# Wayu Shell Initialization - Main Orchestrator (Fish)
# Sources core.<ext>, which wayu compiles from wayu.toml

# Directories. wayu writes this file into its data dir, so that dir is this
# file's own location (WAYU_DATA_DIR / WAYU_CONFIG_DIR given to wayu need not
# be exported to the shell). The config dir holds wayu.toml.
set -l _wayu_d (status dirname)
string match -q -- '/*' $_wayu_d; or set _wayu_d $PWD/$_wayu_d
if test -f "$_wayu_d/init.fish"
    set -gx WAYU_DATA_DIR $_wayu_d
else if test -z "$WAYU_DATA_DIR"
    set -gx WAYU_DATA_DIR $HOME/.config/wayu
end
if test -z "$WAYU_CONFIG_DIR"
    if test -f "$WAYU_DATA_DIR/wayu.toml"
        set -gx WAYU_CONFIG_DIR $WAYU_DATA_DIR
    else
        set -gx WAYU_CONFIG_DIR $HOME/.config/wayu
    end
end
# === Compiled core ===
# core.fish is generated from wayu.toml (any wayu write, or 'wayu build');
# tools.fish and extra.fish follow it.
if test -f "$WAYU_DATA_DIR/core.fish"
    source "$WAYU_DATA_DIR/core.fish"
    if test -f "$WAYU_CONFIG_DIR/tools.fish"
        source "$WAYU_CONFIG_DIR/tools.fish"
    end
    if test -f "$WAYU_CONFIG_DIR/extra.fish"
        source "$WAYU_CONFIG_DIR/extra.fish"
    end
else
    echo "wayu: $WAYU_DATA_DIR/core.fish is missing; run 'wayu build'" >&2
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

// Helper to initialize config files with templates if they don't exist
init_config_file :: proc(file_path: string, template: string) -> bool {
	// Check if file already exists
	if os.exists(file_path) {
		return true
	}

	debug("Creating config file: %s", file_path)

	// Owner-only: wayu.toml holds [env] secrets.
	write_err := os.write_entire_file(file_path, transmute([]byte)template, SECRET_FILE_PERMS)
	if write_err != nil {
		debug("Failed to create config file: %s", file_path)
		return false
	}

	debug("Created config file: %s", file_path)
	return true
}

// Template selection functions based on shell type.
//
// The getters pick one of three shell-specific templates for the current
// `ShellType`. They all share the same dispatch logic, so they delegate to
// `select_template`. `.UNKNOWN` falls back to the Bash template for POSIX-ish
// compatibility.
//
// NOTE: keep these as named procs (not inlined) so they can be used as
// function pointers — init_shell_configs stores them in a slice.

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

get_init_template :: proc(shell: ShellType) -> string {
	return select_template(shell, INIT_TEMPLATE_ZSH, INIT_TEMPLATE_BASH, INIT_TEMPLATE_FISH)
}

get_tools_template :: proc(shell: ShellType) -> string {
	return select_template(shell, TOOLS_TEMPLATE_ZSH, TOOLS_TEMPLATE_BASH, TOOLS_TEMPLATE_FISH)
}

get_extra_template :: proc(shell: ShellType) -> string {
	return select_template(shell, EXTRA_TEMPLATE_ZSH, EXTRA_TEMPLATE_BASH, EXTRA_TEMPLATE_FISH)
}
