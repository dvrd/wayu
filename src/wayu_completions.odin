// wayu_completions.odin - Auto-generate completions for wayu itself
//
// This module generates zsh, bash and fish completion scripts for wayu,
// enabling tab-completion for the CLI.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"

// One row per top-level command. wayu's own zsh, bash and fish completions
// are all generated from this table, so they can't drift apart (OKAMI-234:
// the three hand-written scripts each missed different commands).
// `names[0]` is the canonical name; the rest are parser aliases. `actions`
// are "word:description" (doctor lists its flags). tests/unit/
// test_completions.odin checks every dispatchable Command has a row, every
// name parses to that Command, and every name appears in all three scripts.
WayuCommandSpec :: struct {
	command: Command,
	names:   []string,
	desc:    string,
	actions: []string,
}

WAYU_COMMAND_SPECS := [?]WayuCommandSpec{
	{.PATH, {"path"}, "Manage PATH entries", {
		"add:Add a PATH entry", "remove:Remove a PATH entry", "rm:Remove a PATH entry",
		"list:List PATH entries", "ls:List PATH entries", "get:Get a PATH entry",
		"clean:Remove missing directories", "dedup:Remove duplicates", "help:Show help"}},
	{.ALIAS, {"alias"}, "Manage shell aliases", {
		"add:Add an alias", "remove:Remove an alias", "rm:Remove an alias",
		"list:List aliases", "ls:List aliases", "get:Get alias value", "help:Show help"}},
	{.CONSTANTS, {"constants", "const", "env"}, "Manage environment constants", {
		"add:Add a constant", "remove:Remove a constant", "rm:Remove a constant",
		"list:List constants", "ls:List constants", "get:Get constant value", "help:Show help",
		"--reveal:Show secret values unmasked in list"}},
	{.SEARCH, {"search", "find", "f"}, "Fuzzy search across all configs", {}},
	{.COMPLETIONS, {"completions"}, "Manage shell completion scripts", {
		"add:Add a completion script", "remove:Remove a completion", "rm:Remove a completion",
		"list:List completions", "ls:List completions", "generate:Generate wayu's own completions",
		"bash:Print bash completion for wayu", "fish:Print fish completion for wayu",
		"zsh:Print zsh completion for wayu", "help:Show help"}},
	{.BACKUP, {"backup"}, "Manage configuration backups", {
		"list:List backups", "ls:List backups", "restore:Restore from backup",
		"remove:Clean up old backups", "rm:Clean up old backups", "help:Show help"}},
	{.PLUGIN, {"plugin"}, "Manage shell plugins", {
		"add:Install a plugin", "remove:Remove a plugin", "rm:Remove a plugin",
		"list:List installed plugins", "ls:List installed plugins", "get:Show plugin info",
		"search:Browse popular plugins", "enable:Enable a plugin", "disable:Disable a plugin",
		"priority:Set plugin load priority", "check:Check for updates", "update:Update plugins",
		"help:Show help"}},
	{.INIT, {"init"}, "Initialize wayu configuration", {"help:Show help"}},
	{.MIGRATE, {"migrate"}, "Migrate shell config to wayu.toml", {"help:Show help"}},
	{.CONFIG, {"config"}, "Manage configuration files", {
		"edit:Open extra config in $EDITOR", "extend:Append to extra config",
		"scan:Detect shell config", "help:Show help"}},
	{.BUILD, {"build"}, "Compile wayu.toml into shell init files", {
		"eval:Regenerate and print shell code", "turbo:Generate turbo file",
		"profile:Profile startup", "clean:Clear the [tools] evalcache", "help:Show help"}},
	{.EXPORT, {"export"}, "Generate turbo export file", {
		"turbo:Generate turbo file", "eval:Output for eval", "list:Show formats",
		"ls:Show formats", "help:Show help"}},
	{.TOML, {"toml"}, "TOML configuration management", {
		"validate:Validate wayu.toml", "convert:Convert to TOML", "show:Show config",
		"keys:List keys", "help:Show help", "--reveal:Show secret values unmasked in show"}},
	{.DOCTOR, {"doctor"}, "Health check and diagnostics", {
		"--fix:Repair what can be repaired", "--json:Machine-readable output",
		"--profile:Profile shell startup", "--optimize:Suggest optimizations", "--help:Show help"}},
	{.TEMPLATE, {"template"}, "Configuration presets", {
		"list:List templates", "ls:List templates", "apply:Apply a template", "help:Show help"}},
	{.HOOKS, {"hooks"}, "Pre/post action hooks", {
		"list:List hooks", "ls:List hooks", "edit:Edit hooks", "help:Show help"}},
	{.FUNCTION, {"function", "functions", "func", "fn"}, "Manage custom shell functions", {
		"add:Create a function in $EDITOR", "edit:Edit a function", "new:Create a function",
		"list:List functions", "ls:List functions", "remove:Delete a function",
		"rm:Delete a function", "delete:Delete a function", "help:Show help"}},
	{.RELOAD, {"reload", "watch", "hot-reload"}, "Watch config files and regenerate init files", {}},
	{.VERSION, {"version"}, "Show version", {}},
	{.HELP, {"help"}, "Show help", {}},
}

// Word before the first ':' of an "action:description" entry.
@(private = "file")
completion_word :: proc(entry: string) -> string {
	if i := strings.index_byte(entry, ':'); i >= 0 { return entry[:i] }
	return entry
}

@(private = "file")
completion_desc :: proc(entry: string) -> string {
	if i := strings.index_byte(entry, ':'); i >= 0 { return entry[i+1:] }
	return ""
}

// zsh completion for wayu (an fpath `_wayu` file). Allocated; caller deletes.
generate_wayu_completion_zsh :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	q :: proc(s: string) -> string { return shell_single_quote(s, context.temp_allocator) }

	strings.write_string(&b, "#compdef wayu\n\n")
	strings.write_string(&b, "# wayu completion script - Auto-generated\n")
	strings.write_string(&b, "# Regenerate with: wayu completions generate\n\n")

	strings.write_string(&b, "_wayu_commands() {\n    local -a commands\n    commands=(\n")
	for spec in WAYU_COMMAND_SPECS {
		for name in spec.names {
			fmt.sbprintf(&b, "        %s\n", q(fmt.tprintf("%s:%s", name, spec.desc)))
		}
	}
	strings.write_string(&b, "    )\n    _describe -t commands 'wayu command' commands\n}\n\n")

	strings.write_string(&b, "_wayu_actions() {\n    local -a actions\n    case \"$1\" in\n")
	for spec in WAYU_COMMAND_SPECS {
		if len(spec.actions) == 0 { continue }
		strings.write_string(&b, "        ")
		strings.write_string(&b, strings.join(spec.names, "|", context.temp_allocator))
		strings.write_string(&b, ") actions=(")
		for a in spec.actions {
			strings.write_byte(&b, ' ')
			strings.write_string(&b, q(a))
		}
		strings.write_string(&b, " ) ;;\n")
	}
	strings.write_string(&b, "    esac\n    (( ${#actions} )) && _describe -t actions \"$1 action\" actions\n}\n\n")

	strings.write_string(&b, `# Main completion function
_wayu() {
    local curcontext="$curcontext" state line
    typeset -A opt_args

    _arguments -C \
        '(-h --help)'{-h,--help}'[Show help]' \
        '(-v --version)'{-v,--version}'[Show version]' \
        '(-n --dry-run)'{-n,--dry-run}'[Preview changes]' \
        '(-y --yes)'{-y,--yes}'[Skip confirmation]' \
        '--no-color[Disable colored output]' \
        '--tui[Launch TUI mode]' \
        '--shell[Specify shell]:shell:(zsh bash fish)' \
        '1: :_wayu_commands' \
        '2: :->action' \
        '*:: :->args'

    case "$state" in
        action)
            _wayu_actions "$line[1]"
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

# Standard #compdef dispatch: when compinit autoloads this file as the
# _wayu function, run the completer immediately (otherwise the very first
# TAB only defines functions and completes nothing). When the file is
# sourced directly, register it with compdef instead.
if [[ $zsh_eval_context[-1] == loadautofunc ]]; then
    _wayu "$@"
else
    compdef _wayu wayu
fi
`)
	return strings.to_string(b)
}

// bash completion for wayu (sourced by core.bash from completions/wayu.bash).
generate_wayu_completion_bash :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "#!/usr/bin/env bash\n\n")
	strings.write_string(&b, "# wayu bash completion script - Auto-generated\n")
	strings.write_string(&b, "# Regenerate with: wayu completions generate\n\n")
	strings.write_string(&b, "_wayu_completion() {\n")
	strings.write_string(&b, "    local cur=\"${COMP_WORDS[COMP_CWORD]}\" words=\"\"\n")
	strings.write_string(&b, "    COMPREPLY=()\n")
	strings.write_string(&b, "    if [ \"$COMP_CWORD\" -eq 1 ]; then\n        words=\"")
	first := true
	for spec in WAYU_COMMAND_SPECS {
		for name in spec.names {
			if !first { strings.write_byte(&b, ' ') }
			strings.write_string(&b, name)
			first = false
		}
	}
	strings.write_string(&b, " --help --version --dry-run --yes --no-color --tui --shell\"\n")
	strings.write_string(&b, "    elif [ \"$COMP_CWORD\" -eq 2 ]; then\n        case \"${COMP_WORDS[1]}\" in\n")
	for spec in WAYU_COMMAND_SPECS {
		if len(spec.actions) == 0 { continue }
		strings.write_string(&b, "            ")
		strings.write_string(&b, strings.join(spec.names, "|", context.temp_allocator))
		strings.write_string(&b, ") words=\"")
		for a, i in spec.actions {
			if i > 0 { strings.write_byte(&b, ' ') }
			strings.write_string(&b, completion_word(a))
		}
		strings.write_string(&b, "\" ;;\n")
	}
	strings.write_string(&b, `        esac
    else
        case "${COMP_WORDS[1]} ${COMP_WORDS[2]}" in
            "path add") COMPREPLY=($(compgen -d -- "$cur")); return 0 ;;
            "completions add") COMPREPLY=($(compgen -f -- "$cur")); return 0 ;;
        esac
    fi
    COMPREPLY=($(compgen -W "$words" -- "$cur"))
}

complete -F _wayu_completion wayu
`)
	return strings.to_string(b)
}

// fish completion for wayu (completions/wayu.fish).
generate_wayu_completion_fish :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "#!/usr/bin/env fish\n\n")
	strings.write_string(&b, "# wayu fish completion script - Auto-generated\n")
	strings.write_string(&b, "# Regenerate with: wayu completions generate\n\n")

	strings.write_string(&b, "set -l commands")
	for spec in WAYU_COMMAND_SPECS {
		for name in spec.names { fmt.sbprintf(&b, " %s", name) }
	}
	strings.write_string(&b, "\n\n# Top-level completion (only when no subcommand has been entered yet)\n")
	strings.write_string(&b, "complete -c wayu -f\n")
	for spec in WAYU_COMMAND_SPECS {
		for name in spec.names {
			fmt.sbprintf(&b, "complete -c wayu -n \"not __fish_seen_subcommand_from $commands\" -a %s -d %s\n",
				name, escape_fish_string(spec.desc, context.temp_allocator))
		}
	}
	for spec in WAYU_COMMAND_SPECS {
		if len(spec.actions) == 0 { continue }
		cond := fmt.tprintf("__fish_seen_subcommand_from %s", strings.join(spec.names, " ", context.temp_allocator))
		fmt.sbprintf(&b, "\n# %s\n", spec.names[0])
		for a in spec.actions {
			fmt.sbprintf(&b, "complete -c wayu -n %s -a %s -d %s\n",
				escape_fish_string(cond, context.temp_allocator),
				escape_fish_string(completion_word(a), context.temp_allocator),
				escape_fish_string(completion_desc(a), context.temp_allocator))
		}
	}
	strings.write_string(&b, `
# Global flags
complete -c wayu -s h -l help -d "Show help"
complete -c wayu -s v -l version -d "Show version"
complete -c wayu -s n -l dry-run -d "Preview changes without writing"
complete -c wayu -s y -l yes -d "Skip confirmation prompts"
complete -c wayu -l tui -d "Launch interactive TUI mode"
complete -c wayu -l shell -x -a "zsh bash fish" -d "Specify shell type"
complete -c wayu -l no-color -d "Disable colored output"
`)
	return strings.to_string(b)
}

// Generate completions for wayu itself
handle_completions_generate :: proc() {
	print_header("Generating wayu completions", "🎯")
	fmt.println()

	// Determine completions directory
	completions_dir := fmt.aprintf("%s/completions", wayu.data)
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

	zsh_script := generate_wayu_completion_zsh()
	defer delete(zsh_script)
	write_ok := safe_write_file(completion_path, transmute([]byte)zsh_script)
	if !write_ok {
		print_error("Failed to write completion file")
		os.exit(EXIT_IOERR)
	}

	print_success("Generated: %s", completion_path)

	// Write bash completion file
	bash_completion_path := fmt.aprintf("%s/wayu.bash", completions_dir)
	defer delete(bash_completion_path)

	bash_script := generate_wayu_completion_bash()
	defer delete(bash_script)
	write_ok = safe_write_file(bash_completion_path, transmute([]byte)bash_script)
	if !write_ok {
		print_error("Failed to write bash completion file")
		os.exit(EXIT_IOERR)
	}

	print_success("Generated: %s", bash_completion_path)

	// Write fish completion file
	fish_completion_path := fmt.aprintf("%s/wayu.fish", completions_dir)
	defer delete(fish_completion_path)

	fish_script := generate_wayu_completion_fish()
	defer delete(fish_script)
	write_ok = safe_write_file(fish_completion_path, transmute([]byte)fish_script)
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
	s := generate_wayu_completion_bash()
	defer delete(s)
	fmt.print(s)
}

// Generate fish completions for wayu
handle_completions_fish :: proc() {
	s := generate_wayu_completion_fish()
	defer delete(s)
	fmt.print(s)
}

// Generate zsh completions for wayu
handle_completions_zsh :: proc() {
	s := generate_wayu_completion_zsh()
	defer delete(s)
	fmt.print(s)
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
//   bash → `name.bash-completion` (loop-sourced by core.bash)
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
	completion_name := completion_filename_for_shell(name, wayu.shell)
	defer delete(completion_name)

	// Read source file
	content, read_ok := safe_read_file(source_path)
	if !read_ok {
		os.exit(EXIT_IOERR)
	}
	defer delete(content)

	// Destination directory
	completions_dir := fmt.aprintf("%s/completions", wayu.data)
	defer delete(completions_dir)

	// Ensure completions directory exists
	if !os.exists(completions_dir) {
		print_error_with_context(.CONFIG_NOT_INITIALIZED, wayu.config)
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
	if wayu.dry_run {
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
	init_file := get_config_file_with_fallback("init", wayu.shell)
	defer delete(init_file)
	fmt.printfln("\n%sNext steps:%s", BRIGHT_CYAN, RESET)
	fmt.printfln("  source %s", init_file)
	fmt.printfln("  or restart your shell")
}

// Remove completion file
remove_completion :: proc(name: string) {
	// Build directory path
	completions_dir := fmt.aprintf("%s/completions", wayu.data)
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
	if wayu.dry_run {
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
	if wayu.dry_run {
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

	completions_dir := fmt.aprintf("%s/completions", wayu.data)
	defer delete(completions_dir)

	// Check directory exists
	if !os.exists(completions_dir) {
		print_error_with_context(.CONFIG_NOT_INITIALIZED, wayu.config)
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