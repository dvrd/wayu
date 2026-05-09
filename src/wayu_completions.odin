// wayu_completions.odin - Auto-generate completions for wayu itself
//
// This module generates Zsh completion scripts for wayu commands,
// enabling tab-completion for the CLI.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"

// Completion script template for Zsh
WAYU_COMPLETION_TEMPLATE :: `#compdef wayu

# wayu completion script - Auto-generated
# Regenerate with: wayu completions generate

_wayu_commands() {
    local commands
    commands=(
        'path:Manage PATH entries'
        'alias:Manage shell aliases'
        'constants:Manage environment constants'
        'search:Fuzzy search across all configs'
        'find:Fuzzy search alias'
        'f:Fuzzy search short alias'
        'completions:Manage Zsh completion scripts'
        'backup:Manage configuration backups'
        'plugin:Manage shell plugins'
        'init:Initialize wayu configuration'
        'migrate:Migrate between shells'
        'config:Open extra config in EDITOR'
        'export:Generate turbo export file'
        'toml:TOML configuration management'
        'version:Show version'
        'help:Show help'
    )
    _describe -t commands 'wayu command' commands
}

_wayu_path_actions() {
    local actions
    actions=(
        'add:Add a PATH entry'
        'remove:Remove a PATH entry'
        'rm:Remove path entry'
        'list:List PATH entries'
        'ls:List path entries'
        'get:Get PATH by name'
        'clean:Remove missing directories'
        'dedup:Remove duplicates'
        'help:Show help'
    )
    _describe -t actions 'path action' actions
}

_wayu_alias_actions() {
    local actions
    actions=(
        'add:Add an alias'
        'remove:Remove an alias'
        'rm:Remove alias'
        'list:List aliases'
        'ls:List alias'
        'get:Get alias value'
        'help:Show help'
    )
    _describe -t actions 'alias action' actions
}

_wayu_constants_actions() {
    local actions
    actions=(
        'add:Add a constant'
        'remove:Remove a constant'
        'rm:Remove constant'
        'list:List constants'
        'ls:List constants'
        'get:Get constant value'
        'help:Show help'
    )
    _describe -t actions 'constants action' actions
}

_wayu_plugin_actions() {
    local actions
    actions=(
        'add:Install a plugin'
        'remove:Remove a plugin'
        'list:List installed plugins'
        'search:Search registry'
        'enable:Enable plugin'
        'disable:Disable plugin'
        'priority:Set plugin priority'
        'check:Check for updates'
        'update:Update plugins'
        'help:Show help'
    )
    _describe -t actions 'plugin action' actions
}

_wayu_backup_actions() {
    local actions
    actions=(
        'list:List backups'
        'restore:Restore from backup'
        'help:Show help'
    )
    _describe -t actions 'backup action' actions
}

_wayu_completions_actions() {
    local actions
    actions=(
        'add:Add completion script'
        'list:List completions'
        'help:Show help'
    )
    _describe -t actions 'completions action' actions
}

_wayu_export_actions() {
    local actions
    actions=(
        'turbo:Generate turbo file'
        'eval:Output for eval'
        'list:Show formats'
        'help:Show help'
    )
    _describe -t actions 'export action' actions
}

_wayu_toml_actions() {
    local actions
    actions=(
        'validate:Validate TOML config'
        'convert:Convert to TOML'
        'apply:Apply TOML config'
        'help:Show help'
    )
    _describe -t actions 'toml action' actions
}

# Main completion function
_wayu() {
    local curcontext="$curcontext" state line
    typeset -A opt_args

    _arguments -C \
        '(-h --help)'{-h,--help}'[Show help]' \
        '(-v --version)'{-v,--version}'[Show version]' \
        '(-n --dry-run)'{-n,--dry-run}'[Preview changes]' \
        '(-y --yes)'{-y,--yes}'[Skip confirmation]' \
        '--tui[Launch TUI mode]' \
        '--shell[Specify shell]:shell:(zsh bash)' \
        '1: :_wayu_commands' \
        '2: :->action' \
        '*:: :->args'

    case "$state" in
        action)
            case "$line[1]" in
                path) _wayu_path_actions ;;
                alias) _wayu_alias_actions ;;
                constants|const) _wayu_constants_actions ;;
                plugin) _wayu_plugin_actions ;;
                backup) _wayu_backup_actions ;;
                completions) _wayu_completions_actions ;;
                export) _wayu_export_actions ;;
                toml) _wayu_toml_actions ;;
            esac
            ;;
        args)
            case "$line[1]" in
                path)
                    if [[ "$line[2]" == "add" ]]; then
                        _path_files -/
                    fi
                    ;;
                completions)
                    if [[ "$line[2]" == "add" ]]; then
                        _files
                    fi
                    ;;
            esac
            ;;
    esac
}

compdef _wayu wayu
`

// Fish completion template
WAYU_COMPLETION_FISH :: `#!/usr/bin/env fish

# wayu fish completion script - Auto-generated
# Regenerate with: wayu completions fish

# Main commands
set -l commands path alias constants search find f completions backup plugin init migrate config export toml version help build scan

# Top-level completion (only when no subcommand has been entered yet)
complete -c wayu -f
complete -c wayu -n "not __fish_seen_subcommand_from $commands" -a "$commands" -d "Commands"

# Path command completions
complete -c wayu -n "__fish_seen_subcommand_from path" -f
complete -c wayu -n "__fish_seen_subcommand_from path" -a "add remove rm list ls get clean dedup help"

# Alias command completions
complete -c wayu -n "__fish_seen_subcommand_from alias" -f
complete -c wayu -n "__fish_seen_subcommand_from alias" -a "add remove rm list ls get help"

# Constants command completions
complete -c wayu -n "__fish_seen_subcommand_from constants" -f
complete -c wayu -n "__fish_seen_subcommand_from constants" -a "add remove rm list ls get help"

# Completions command
complete -c wayu -n "__fish_seen_subcommand_from completions" -f
complete -c wayu -n "__fish_seen_subcommand_from completions" -a "list ls add bash fish zsh help"

# Plugin command completions
complete -c wayu -n "__fish_seen_subcommand_from plugin" -f
complete -c wayu -n "__fish_seen_subcommand_from plugin" -a "add remove list search enable disable priority check update help"

# Build command completions
complete -c wayu -n "__fish_seen_subcommand_from build" -f
complete -c wayu -n "__fish_seen_subcommand_from build" -a "profile turbo eval help"

# Config command completions
complete -c wayu -n "__fish_seen_subcommand_from config" -f
complete -c wayu -n "__fish_seen_subcommand_from config" -a "scan edit extend help"

# Export command completions
complete -c wayu -n "__fish_seen_subcommand_from export" -f
complete -c wayu -n "__fish_seen_subcommand_from export" -a "turbo eval list help"

# Backup command completions
complete -c wayu -n "__fish_seen_subcommand_from backup" -f
complete -c wayu -n "__fish_seen_subcommand_from backup" -a "list restore help"

# Toml command completions
complete -c wayu -n "__fish_seen_subcommand_from toml" -f
complete -c wayu -n "__fish_seen_subcommand_from toml" -a "validate help"

# Migrate command completions
complete -c wayu -n "__fish_seen_subcommand_from migrate" -f
complete -c wayu -n "__fish_seen_subcommand_from migrate" -a "help"

# Global flags
complete -c wayu -s h -l help -d "Show help"
complete -c wayu -s v -l version -d "Show version"
complete -c wayu -l dry-run -d "Preview changes without writing"
complete -c wayu -s y -l yes -d "Skip confirmation prompts"
complete -c wayu -l tui -d "Launch interactive TUI mode"
complete -c wayu -l shell -x -a "zsh bash fish" -d "Specify shell type"
complete -c wayu -l no-color -d "Disable colored output"
`

// Bash completion template
WAYU_COMPLETION_BASH :: `#!/usr/bin/env bash

# wayu bash completion script - Auto-generated
# Regenerate with: wayu completions bash

_wayu_completion() {
    local cur prev words cword
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Main commands
    local commands="path alias constants search find f completions backup plugin init migrate config export toml version help build scan"

    # If we are completing the first word, list main commands
    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=($(compgen -W "${commands}" -- "${cur}"))
        return
    fi

    # Handle subcommands based on the main command
    case "${COMP_WORDS[1]}" in
        path|alias|constants|plugin|backup)
            local actions="add remove rm list ls get help"
            COMPREPLY=($(compgen -W "${actions}" -- "${cur}"))
            ;;
        completions)
            local actions="list ls add bash fish zsh help"
            COMPREPLY=($(compgen -W "${actions}" -- "${cur}"))
            ;;
        export)
            local actions="turbo eval list help"
            COMPREPLY=($(compgen -W "${actions}" -- "${cur}"))
            ;;
        toml)
            local actions="validate help"
            COMPREPLY=($(compgen -W "${actions}" -- "${cur}"))
            ;;
        build)
            local actions="profile turbo eval help"
            COMPREPLY=($(compgen -W "${actions}" -- "${cur}"))
            ;;
        config|scan)
            local actions="fix edit extend help"
            COMPREPLY=($(compgen -W "${actions}" -- "${cur}"))
            ;;
        *)
            ;;
    esac
}

complete -F _wayu_completion wayu
`

// Generate completions for wayu itself
handle_completions_generate :: proc() {
	print_header("Generating wayu completions", "🎯")
	fmt.println()

	// Determine completions directory
	completions_dir := fmt.aprintf("%s/completions", g_ctx.wayu_config)
	defer delete(completions_dir)

	// Ensure directory exists
	if !os.exists(completions_dir) {
		err := os.make_directory(completions_dir)
		if err != nil {
			print_error("Failed to create completions directory: %v", err)
			os.exit(EXIT_CANTCREAT)
		}
	}

	// Write zsh completion file
	completion_path := fmt.aprintf("%s/_wayu", completions_dir)
	defer delete(completion_path)

	write_ok := safe_write_file(completion_path, transmute([]byte)(string(WAYU_COMPLETION_TEMPLATE)))
	if !write_ok {
		print_error("Failed to write completion file")
		os.exit(EXIT_IOERR)
	}

	print_success("Generated: %s", completion_path)

	// Write bash completion file
	bash_completion_path := fmt.aprintf("%s/wayu.bash", completions_dir)
	defer delete(bash_completion_path)

	write_ok = safe_write_file(bash_completion_path, transmute([]byte)(string(WAYU_COMPLETION_BASH)))
	if !write_ok {
		print_error("Failed to write bash completion file")
		os.exit(EXIT_IOERR)
	}

	print_success("Generated: %s", bash_completion_path)

	// Write fish completion file
	fish_completion_path := fmt.aprintf("%s/wayu.fish", completions_dir)
	defer delete(fish_completion_path)

	write_ok = safe_write_file(fish_completion_path, transmute([]byte)(string(WAYU_COMPLETION_FISH)))
	if !write_ok {
		print_error("Failed to write fish completion file")
		os.exit(EXIT_IOERR)
	}

	print_success("Generated: %s", fish_completion_path)
	fmt.println()

	// Instructions
	print_section("Setup Instructions", EMOJI_INFO)
	fmt.println("The completion scripts have been generated. To enable them:")
	fmt.println()
	fmt.println("Zsh - Option 1 - Add to fpath (recommended):")
	fmt.printfln("  fpath=(%s $fpath)", completions_dir)
	fmt.println("  compinit")
	fmt.println()
	fmt.println("Zsh - Option 2 - Source directly in .zshrc:")
	fmt.printfln("  source %s", completion_path)
	fmt.println()
	fmt.println("Bash - Source in .bashrc:")
	fmt.printfln("  source %s", bash_completion_path)
	fmt.println()
	fmt.println("Fish - Symlink into completions dir:")
	fmt.printfln("  ln -sf %s ~/.config/fish/completions/wayu.fish", fish_completion_path)
	fmt.println()
	fmt.println("Then restart your shell or run:")
	fmt.println("  exec $SHELL")
	fmt.println()
	print_success("Tab completion now available: wayu <TAB>")
}

// Generate bash completions for wayu
handle_completions_bash :: proc() {
	fmt.println(WAYU_COMPLETION_BASH)
}

// Generate fish completions for wayu
handle_completions_fish :: proc() {
	fmt.println(WAYU_COMPLETION_FISH)
}

// Generate zsh completions for wayu
handle_completions_zsh :: proc() {
	fmt.println(WAYU_COMPLETION_TEMPLATE)
}

// Extended completions handler with generate action.
// All regular actions delegate to the main completions handler.
handle_completions_command_extended :: proc(action: Action, args: []string) {
	#partial switch action {
	case .ADD, .REMOVE, .RESTORE, .CLEAN, .DEDUP, .UNKNOWN:
		handle_completions_command(action, args)
	case .LIST:
		for arg in args {
			if arg == "--generate" || arg == "-g" || arg == "generate" {
				handle_completions_generate()
				return
			}
		}
		handle_completions_command(.LIST, args)
	case .HELP:
		print_completions_help_extended()
	case .UPDATE:
		handle_completions_generate()
	case .CHECK:  // bash
		handle_completions_bash()
	case .GET:    // fish
		handle_completions_fish()
	case .TURBO:  // zsh
		handle_completions_zsh()
	case:
		handle_completions_command(action, args)
	}
}

// Print extended completions help with generate option
print_completions_help_extended :: proc() {
	fmt.println()
	fmt.printfln("%swayu completions - Manage shell completions%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.printfln("  wayu completions list              List installed completions")
	fmt.printfln("  wayu completions generate          Generate wayu self-completions")
	fmt.printfln("  wayu completions add <name> <path> Add completion script")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  Manage Zsh completion scripts for enhanced tab-completion.")
	fmt.println()
	fmt.printfln("%sSELF-COMPLETIONS:%s", get_primary(), RESET)
	fmt.println("  wayu can generate its own completion script for tab completion.")
	fmt.println("  Run 'wayu completions generate' and follow the setup instructions.")
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  wayu completions generate")
	fmt.println("  # Then add to .zshrc: fpath=(~/.config/wayu/completions $fpath)")
	fmt.println("  wayu completions add jj /path/to/_jj")
}

// List existing completions (existing function wrapper)
handle_completions_list :: proc() {
	// Call original completions list
	handle_completions_command(.LIST, nil)
}
COMPLETIONS_FILE :: "completions"

// Returns the on-disk filename a completion should have for the current shell.
//
// If `name` already carries a conventional prefix/extension, keep it as-is
// — the user might be porting a completion file across shells and knows
// what they want. Otherwise apply the shell-specific convention:
//
//   zsh  → `_name`               (autoloaded via fpath + compinit)
//   bash → `name.bash-completion` (loop-sourced by init-core.bash)
//   fish → `name.fish`           (autoloaded via fish_complete_path)
completion_filename_for_shell :: proc(name: string, shell: ShellType) -> string {
	// Already in a recognized shell-specific form — respect it.
	if strings.has_prefix(name, "_") ||
	   strings.has_suffix(name, ".fish") ||
	   strings.has_suffix(name, ".bash") ||
	   strings.has_suffix(name, ".bash-completion") {
		return strings.clone(name)
	}

	switch shell {
	case .FISH:
		return fmt.aprintf("%s.fish", name)
	case .BASH:
		return fmt.aprintf("%s.bash-completion", name)
	case .ZSH, .UNKNOWN:
		return fmt.aprintf("_%s", name)
	}
	return strings.clone(name)
}

// Returns true if a directory entry looks like a completion file
// (any supported shell). Used by list/cleanup paths.
is_completion_file :: proc(filename: string) -> bool {
	if strings.contains(filename, ".backup.") do return false
	return strings.has_prefix(filename, "_") ||
	       strings.has_suffix(filename, ".fish") ||
	       strings.has_suffix(filename, ".bash") ||
	       strings.has_suffix(filename, ".bash-completion")
}

// Given a user-supplied name (e.g. "jj"), return the first matching completion
// file that actually exists in `dir`, trying every shell convention. Returns
// empty string if nothing matched. Caller owns the returned string.
find_existing_completion :: proc(dir, name: string) -> string {
	candidates := [?]string {
		name,
		fmt.tprintf("_%s", name),
		fmt.tprintf("%s.fish", name),
		fmt.tprintf("%s.bash", name),
		fmt.tprintf("%s.bash-completion", name),
	}
	for cand in candidates {
		full := fmt.aprintf("%s/%s", dir, cand)
		if os.exists(full) {
			return full
		}
		delete(full)
	}
	return ""
}

// Handle completions command
handle_completions_command :: proc(action: Action, args: []string) {
	#partial switch action {
	case .ADD:
		if len(args) < 2 {
			print_error_simple("Usage: wayu completions add <name> <source-file>")
			fmt.println("Example: wayu completions add jj /path/to/_jj")
			os.exit(EXIT_USAGE)
		}
		add_completion(args[0], args[1])
	case .REMOVE:
		if len(args) == 0 {
			print_error("Missing required argument: completion name")
			fmt.println()
			fmt.println("Usage: wayu completions rm <name>")
			fmt.println()
			fmt.println("Example:")
			fmt.println("  wayu completions rm jj")
			fmt.println()
			fmt.printfln("%sHint:%s For interactive selection, use: %swayu --tui%s",
				get_muted(), RESET, get_primary(), RESET)
			os.exit(EXIT_USAGE)
		}
		remove_completion(args[0])
	case .LIST:
		list_completions()
	case .GET:
		fmt.eprintln("ERROR: get action not supported for completions command")
		fmt.println("The get action only applies to plugins")
		os.exit(EXIT_USAGE)
	case .RESTORE:
		// RESTORE action is handled by backup command, not completions command
		fmt.eprintln("ERROR: restore action not supported for completions command")
		fmt.println("Use: wayu backup restore completions")
		os.exit(EXIT_USAGE)
	case .CLEAN:
		fmt.eprintln("ERROR: clean action not supported for completions command")
		fmt.println("The clean action only applies to path entries")
		os.exit(EXIT_USAGE)
	case .DEDUP:
		fmt.eprintln("ERROR: dedup action not supported for completions command")
		fmt.println("The dedup action only applies to path entries")
		os.exit(EXIT_USAGE)
	case .HELP:
		print_completions_help()
	case .UNKNOWN:
		fmt.eprintln("Unknown completions action")
		print_completions_help()
		os.exit(EXIT_USAGE)
	}
}

// Add completion from source file
add_completion :: proc(name: string, source_path: string) {
	// Validate source file exists
	if !os.exists(source_path) {
		print_error_with_context(.FILE_NOT_FOUND, source_path)
		os.exit(EXIT_NOINPUT)
	}

	// Normalize name with shell-appropriate convention (zsh `_foo`,
	// bash `foo.bash-completion`, fish `foo.fish`).
	completion_name := completion_filename_for_shell(name, g_ctx.shell)
	defer delete(completion_name)

	// Read source file
	content, read_ok := safe_read_file(source_path)
	if !read_ok {
		os.exit(EXIT_IOERR)
	}
	defer delete(content)

	// Destination directory
	completions_dir := fmt.aprintf("%s/completions", g_ctx.wayu_config)
	defer delete(completions_dir)

	// Ensure completions directory exists
	if !os.exists(completions_dir) {
		print_error_with_context(.CONFIG_NOT_INITIALIZED, g_ctx.wayu_config)
		os.exit(EXIT_CONFIG)
	}

	dest_path := fmt.aprintf("%s/%s", completions_dir, completion_name)
	defer delete(dest_path)

	// Check if already exists
	if os.exists(dest_path) {
		fmt.printfln("%sWarning:%s Completion '%s' already exists. Overwriting.",
			WARNING, RESET, completion_name)
	}

	// Dry-run mode check
	if g_ctx.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould copy to completions directory:%s", BRIGHT_CYAN, RESET)
		fmt.printfln("  %s -> %s", source_path, dest_path)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Create backup before modifying
	if !create_backup_cli(dest_path) {
		os.exit(EXIT_IOERR)
	}

	// Write to destination
	write_ok := safe_write_file(dest_path, content)
	if !write_ok {
		os.exit(EXIT_IOERR)
	}

	// Cleanup old backups (keep last 5)
	cleanup_old_backups(dest_path, 5)

	print_success("Added completion: %s", completion_name)
	init_file := get_config_file_with_fallback("init", g_ctx.shell)
	defer delete(init_file)
	fmt.printfln("\n%sNext steps:%s", BRIGHT_CYAN, RESET)
	fmt.printfln("  source %s", init_file)
	fmt.printfln("  or restart your shell")
}

// Remove completion file
remove_completion :: proc(name: string) {
	// Build directory path
	completions_dir := fmt.aprintf("%s/completions", g_ctx.wayu_config)
	defer delete(completions_dir)

	// Try shell-appropriate form first, then fall back to any other matching
	// convention so users don't need to remember underscores vs extensions.
	file_path := find_existing_completion(completions_dir, name)
	defer if file_path != "" do delete(file_path)

	if file_path == "" {
		print_error_simple("Completion not found: %s", name)
		fmt.printfln("\nRun %swayu completions list%s to see available completions",
			MUTED, RESET)
		os.exit(EXIT_NOINPUT)
	}

	// Extract just the filename for status messages.
	completion_name := file_path
	if slash := strings.last_index_byte(file_path, '/'); slash >= 0 {
		completion_name = file_path[slash + 1:]
	}

	// Dry-run mode check
	if g_ctx.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould remove completion file:%s", BRIGHT_CYAN, RESET)
		fmt.printfln("  %s", file_path)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Create backup before removing
	if !create_backup_cli(file_path) {
		os.exit(EXIT_IOERR)
	}

	// Remove file
	err := os.remove(file_path)
	if err != nil {
		print_error_simple("Failed to remove completion: %s", completion_name)
		os.exit(EXIT_IOERR)
	}

	// Cleanup old backups (keep last 5)
	cleanup_old_backups(file_path, 5)

	print_success("Removed completion: %s", completion_name)
}

// TUI-only: Interactive removal using fuzzy finder
// This function is ONLY called from TUI bridge, never from CLI
remove_completion_interactive :: proc() {
	items := extract_completion_items()
	defer {
		for item in items {
			delete(item)
		}
		delete(items)
	}

	if len(items) == 0 {
		print_warning("No completions found to remove")
		return
	}

	prompt_text := "Select completion to remove (Ctrl+C to cancel):"
	if g_ctx.dry_run {
		prompt_text = "Select completion to remove (DRY RUN - no changes will be made):"
	}

	prompt := fmt.aprintf(prompt_text)
	defer delete(prompt)

	selected, ok := interactive_fuzzy_select(items, prompt)
	if !ok {
		print_info("Operation cancelled")
		return
	}

	// Clone before parent is freed
	selected_copy := strings.clone(selected)
	defer delete(selected_copy)

	remove_completion(selected_copy)
}

// List all completions with metadata
list_completions :: proc() {
	// Check if wayu is initialized first
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	completions_dir := fmt.aprintf("%s/completions", g_ctx.wayu_config)
	defer delete(completions_dir)

	// Check directory exists
	if !os.exists(completions_dir) {
		print_error_with_context(.CONFIG_NOT_INITIALIZED, g_ctx.wayu_config)
		os.exit(EXIT_CONFIG)
	}

	// Read directory
	dir_handle, err := os.open(completions_dir)
	if err != nil {
		print_error_simple("Failed to open completions directory")
		os.exit(EXIT_IOERR)
	}
	defer os.close(dir_handle)

	file_infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil {
		print_error_simple("Failed to read completions directory")
		os.exit(EXIT_IOERR)
	}
	defer os.file_info_slice_delete(file_infos, context.allocator)

	// Filter completion files
	completion_files := make([dynamic]os.File_Info)
	defer delete(completion_files)

	for info in file_infos {
		if info.type == .Directory do continue
		if !is_completion_file(info.name) do continue
		append(&completion_files, info)
	}

	// Print header
	print_header("Shell Completions")
	fmt.println()

	if len(completion_files) == 0 {
		print_info("No completions installed")
		fmt.printfln("\nAdd completions with: %swayu completions add <name> <source-file>%s",
			MUTED, RESET)
		return
	}

	// Print each completion
	for info, i in completion_files {
		// Read first line for description
		file_path := fmt.aprintf("%s/%s", completions_dir, info.name)
		defer delete(file_path)

		first_line := ""
		content, read_err := os.read_entire_file(file_path, context.allocator)
		if read_err == nil {
			defer delete(content)
			// Use temp allocator for lines array since it's only needed during this iteration
			lines := strings.split(string(content), "\n", context.temp_allocator)
			// No need to defer delete - temp allocator manages this
			if len(lines) > 0 {
				first_line = strings.trim_space(lines[0])
				if len(first_line) > 60 {
					truncated := fmt.aprintf("%s...", first_line[:60])
					defer delete(truncated)
					first_line = truncated
				}
			}
		}

		// Print completion info
		fmt.printf("  %s%s%d.%s ", MUTED, BOLD, i+1, RESET)
		fmt.printf("%s%s%s", PRIMARY, info.name, RESET)

		// Size
		size_kb := f32(info.size) / 1024.0
		fmt.printf(" %s(%.1f KB)%s", MUTED, size_kb, RESET)

		fmt.println()

		if len(first_line) > 0 {
			fmt.printf("     %s%s%s\n", MUTED, first_line, RESET)
		}
	}

	fmt.printfln("\n%sTotal:%s %d completion(s)", BRIGHT_CYAN, RESET, len(completion_files))
}

// Help for completions command
print_completions_help :: proc() {
	// Title
	fmt.printf("\n%s%swayu completions - Manage shell completions%s\n\n", BOLD, get_primary(), RESET)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu completions add <name> <source-file>    Add completion")
	fmt.println("  wayu completions remove [name]               Remove completion (alias: rm)")
	fmt.println("  wayu completions list                        List all completions (alias: ls)")
	fmt.println("  wayu completions help                        Show this help")

	// Examples section
	fmt.printf("\n%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %s# Add jujutsu completion%s\n", get_muted(), RESET)
	fmt.printf("  %swayu completions add jj /path/to/_jj%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# List all completions%s\n", get_muted(), RESET)
	fmt.printf("  %swayu completions list%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Remove completion interactively%s\n", get_muted(), RESET)
	fmt.printf("  %swayu completions rm%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Remove specific completion%s\n", get_muted(), RESET)
	fmt.printf("  %swayu completions rm jj%s\n", get_muted(), RESET)

	// Notes section
	fmt.printf("\n%s%sNOTES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %s• Completion files are stored in ~/.config/wayu/completions/%s\n", get_muted(), RESET)
	fmt.printf("  %s• Naming follows the active shell: zsh `_name`, bash `name.bash-completion`, fish `name.fish`%s\n", get_muted(), RESET)
	fmt.printf("  %s• If the input already has a recognized form (_foo, foo.fish, ...) it is kept as-is%s\n", get_muted(), RESET)
	fmt.printf("  %s• Restart your shell or re-source the wayu init file after adding%s\n", get_muted(), RESET)
	fmt.println()
}