package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"
import "core:log"
import tui "tui"

// Semantic versioning - update with each release
VERSION :: "2.0.0"

HOME : string
WAYU_CONFIG : string

// Global flags
DRY_RUN := false
DETECTED_SHELL := detect_shell()
SHELL_EXT : string

// Track if globals have been initialized
_GLOBALS_INITIALIZED := false

// Dynamic config file names based on detected shell
PATH_FILE : string
ALIAS_FILE : string
CONSTANTS_FILE : string
INIT_FILE : string
TOOLS_FILE : string

Command :: enum {
	PATH,
	ALIAS,
	CONSTANTS,
	COMPLETIONS,
	BACKUP,
	PLUGIN,
	INIT,
	MIGRATE,
	VERSION,
	HELP,
	UNKNOWN,
}

Action :: enum {
	ADD,
	REMOVE,
	LIST,
	GET,
	RESTORE,
	CLEAN,
	DEDUP,
	HELP,
	UNKNOWN,
}

ParsedArgs :: struct {
	command: Command,
	action:  Action,
	args:    []string,
	shell:   ShellType,
	tui:     bool,  // TUI mode flag

	// Component testing (PRP-13)
	component_test: bool,
	component_name: string,
	component_snapshot: bool,
	component_verify: bool,
}

init_shell_globals :: proc() {
	// Only initialize once - prevents issues with parallel test execution
	// where multiple threads try to initialize/free shared global strings
	if _GLOBALS_INITIALIZED {
		return
	}

	// Initialize HOME and WAYU_CONFIG
	// NOTE: HOME is intentionally not freed - it's a global that lives for the
	// program's lifetime and is accessed throughout the codebase. This is by design.
	HOME = os.get_env("HOME")
	WAYU_CONFIG = fmt.aprintf("%s/.config/wayu", HOME)

	SHELL_EXT = get_shell_extension(DETECTED_SHELL)
	PATH_FILE = fmt.aprintf("path.%s", SHELL_EXT)
	ALIAS_FILE = fmt.aprintf("aliases.%s", SHELL_EXT)
	CONSTANTS_FILE = fmt.aprintf("constants.%s", SHELL_EXT)
	INIT_FILE = fmt.aprintf("init.%s", SHELL_EXT)
	TOOLS_FILE = fmt.aprintf("tools.%s", SHELL_EXT)

	_GLOBALS_INITIALIZED = true
}

main :: proc() {
  context.logger = log.create_console_logger(.Debug, { .Level, .Terminal_Color })
  defer log.destroy_console_logger(context.logger)

	// Initialize color system (PRP-09 Phase 1)
	init_colors()

	init_shell_globals()
	init_config_files()

	if len(os.args) < 2 {
		print_help()
		os.exit(1)
	}

	parsed := parse_args(os.args[1:])
	defer if len(parsed.args) > 0 do delete(parsed.args)

	// Launch TUI if flag present
	if parsed.tui {
		// Set up bridge functions for TUI
		tui.tui_set_bridge_functions(
			tui_bridge_load_path,
			tui_bridge_load_alias,
			tui_bridge_load_constants,
			tui_bridge_load_backups,
			tui_bridge_delete_path,
			tui_bridge_delete_alias,
			tui_bridge_delete_constant,
			tui_bridge_cleanup_backups,
		)

		// Launch TUI
		tui.tui_run()
		return
	}

	// Component test mode (PRP-13)
	if parsed.component_test {
		run_component_test(parsed.component_name, parsed.args,
			parsed.component_snapshot, parsed.component_verify)
		return
	}

	switch parsed.command {
	case .PATH:
		handle_path_command(parsed.action, parsed.args)
	case .ALIAS:
		handle_alias_command(parsed.action, parsed.args)
	case .CONSTANTS:
		handle_constants_command(parsed.action, parsed.args)
	case .COMPLETIONS:
		handle_completions_command(parsed.action, parsed.args)
	case .BACKUP:
		handle_backup_command(parsed.action, parsed.args)
	case .PLUGIN:
		handle_plugin_command(parsed.action, parsed.args)
	case .INIT:
		handle_init_command()
	case .MIGRATE:
		handle_migrate_command(parsed.args)
	case .VERSION:
		print_version()
	case .HELP:
		print_help()
	case .UNKNOWN:
		fmt.eprintfln("Unknown command: %s", os.args[1])
		print_help()
		os.exit(1)
	}
}

parse_args :: proc(args: []string) -> ParsedArgs {
	parsed := ParsedArgs{
		shell = DETECTED_SHELL, // Default to detected shell
	}

	// Filter out flags and process them
	filtered_args := make([dynamic]string)
	defer delete(filtered_args)

	tui_flag := false
	component_test_flag := false
	component_name_str := ""
	snapshot_flag := false
	verify_flag := false

	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--dry-run" || arg == "-n" {
			DRY_RUN = true
		} else if arg == "--tui" {
			tui_flag = true
		} else if strings.has_prefix(arg, "-c=") {
			component_test_flag = true
			component_name_str = strings.trim_prefix(arg, "-c=")
		} else if arg == "--snapshot" {
			snapshot_flag = true
		} else if arg == "--test" {
			verify_flag = true
		} else if arg == "--shell" && i + 1 < len(args) {
			// Parse shell override
			shell_name := args[i + 1]
			parsed.shell = parse_shell_type(shell_name)
			// Update global shell extension for dry-run messages and file operations
			SHELL_EXT = get_shell_extension(parsed.shell)
			// Also update the file name globals
			PATH_FILE = fmt.aprintf("path.%s", SHELL_EXT)
			ALIAS_FILE = fmt.aprintf("aliases.%s", SHELL_EXT)
			CONSTANTS_FILE = fmt.aprintf("constants.%s", SHELL_EXT)
			INIT_FILE = fmt.aprintf("init.%s", SHELL_EXT)
			TOOLS_FILE = fmt.aprintf("tools.%s", SHELL_EXT)
			i += 1 // Skip the shell value
		} else {
			append(&filtered_args, arg)
		}
		i += 1
	}

	// Use filtered args for parsing
	if len(filtered_args) == 0 {
		parsed.command = .HELP
		parsed.tui = tui_flag
		parsed.component_test = component_test_flag
		parsed.component_name = component_name_str
		parsed.component_snapshot = snapshot_flag
		parsed.component_verify = verify_flag
		return parsed
	}

	// Parse command
	switch filtered_args[0] {
	case "path":
		parsed.command = .PATH
	case "alias":
		parsed.command = .ALIAS
	case "constants":
		parsed.command = .CONSTANTS
	case "completions":
		parsed.command = .COMPLETIONS
	case "backup":
		parsed.command = .BACKUP
	case "plugin":
		parsed.command = .PLUGIN
	case "init":
		parsed.command = .INIT
		parsed.tui = tui_flag
		parsed.component_test = component_test_flag
		parsed.component_name = component_name_str
		parsed.component_snapshot = snapshot_flag
		parsed.component_verify = verify_flag
		return parsed
	case "migrate":
		parsed.command = .MIGRATE
		parsed.tui = tui_flag
		parsed.component_test = component_test_flag
		parsed.component_name = component_name_str
		parsed.component_snapshot = snapshot_flag
		parsed.component_verify = verify_flag
		return parsed
	case "version", "-v", "--version":
		parsed.command = .VERSION
		parsed.tui = tui_flag
		parsed.component_test = component_test_flag
		parsed.component_name = component_name_str
		parsed.component_snapshot = snapshot_flag
		parsed.component_verify = verify_flag
		return parsed
	case "help", "-h", "--help":
		parsed.command = .HELP
		parsed.tui = tui_flag
		parsed.component_test = component_test_flag
		parsed.component_name = component_name_str
		parsed.component_snapshot = snapshot_flag
		parsed.component_verify = verify_flag
		return parsed
	case:
		parsed.command = .UNKNOWN
		parsed.tui = tui_flag
		parsed.component_test = component_test_flag
		parsed.component_name = component_name_str
		parsed.component_snapshot = snapshot_flag
		parsed.component_verify = verify_flag
		return parsed
	}

	// Parse action
	if len(filtered_args) < 2 {
		parsed.action = .LIST
		parsed.tui = tui_flag
		parsed.component_test = component_test_flag
		parsed.component_name = component_name_str
		parsed.component_snapshot = snapshot_flag
		parsed.component_verify = verify_flag
		return parsed
	}

	switch filtered_args[1] {
	case "add":
		parsed.action = .ADD
	case "remove", "rm":
		parsed.action = .REMOVE
	case "list", "ls":
		parsed.action = .LIST
	case "get":
		parsed.action = .GET
	case "restore":
		parsed.action = .RESTORE
	case "clean":
		parsed.action = .CLEAN
	case "dedup":
		parsed.action = .DEDUP
	case "help", "-h", "--help":
		parsed.action = .HELP
	case:
		parsed.action = .UNKNOWN
		parsed.tui = tui_flag
		parsed.component_test = component_test_flag
		parsed.component_name = component_name_str
		parsed.component_snapshot = snapshot_flag
		parsed.component_verify = verify_flag
		return parsed
	}

	// Parse remaining arguments
	if len(filtered_args) > 2 {
		// Allocate array for remaining args - caller must free if needed
		// Note: These are shallow copies (string references from args)
		remaining_args := make([]string, len(filtered_args) - 2)
		copy(remaining_args, filtered_args[2:])
		parsed.args = remaining_args
	}

	parsed.tui = tui_flag
	parsed.component_test = component_test_flag
	parsed.component_name = component_name_str
	parsed.component_snapshot = snapshot_flag
	parsed.component_verify = verify_flag
	return parsed
}


handle_init_command :: proc() {
	print_header("Initializing Wayu Configuration", "🚀")
	fmt.println()

	// Detect and confirm shell
	detected_shell := detect_shell()
	print_info("Detected shell: %s", get_shell_name(detected_shell))

	// Validate shell compatibility
	shell_valid, shell_msg := validate_shell_compatibility(detected_shell)
	if !shell_valid {
		print_error_simple("ERROR: %s", shell_msg)
		os.exit(1)
	}

	shell := detected_shell
	ext := get_shell_extension(shell)

	print_info("Using shell: %s (config files will use .%s extension)", get_shell_name(shell), ext)
	fmt.println()

	config_dir := fmt.aprintf("%s", WAYU_CONFIG)
	defer delete(config_dir)

	// Create main config directory with spinner
	if !os.exists(config_dir) {
		spinner := new_spinner(.Dots)
		spinner_text(&spinner, "Creating config directory")
		spinner_start(&spinner)

		err := os.make_directory(config_dir)

		spinner_stop(&spinner)

		if err != nil {
			print_error_simple("Error creating config directory: %v", err)
			os.exit(1)
		}
		print_success("Created directory: %s", config_dir)
	} else {
		print_info("Directory already exists: %s", config_dir)
	}

	// Create subdirectories with spinner
	subdirs := []string{"functions", "completions", "plugins"}
	created_subdirs := 0

	for subdir in subdirs {
		subdir_path := fmt.aprintf("%s/%s", WAYU_CONFIG, subdir)
		defer delete(subdir_path)

		if !os.exists(subdir_path) {
			spinner := new_spinner(.Arc)
			spinner_text_str := fmt.aprintf("Creating %s directory", subdir)
			defer delete(spinner_text_str)
			spinner_text(&spinner, spinner_text_str)
			spinner_start(&spinner)

			err := os.make_directory(subdir_path)

			spinner_stop(&spinner)

			if err != nil {
				print_error_simple("Error creating directory %s: %v", subdir, err)
				os.exit(1)
			}
			print_success("Created directory: %s", subdir_path)
			created_subdirs += 1
		}
	}

	if created_subdirs == 0 {
		print_info("All subdirectories already exist")
	}

	fmt.println()

	// Initialize shell-specific config files
	init_shell_configs(shell, ext)

	fmt.println()

	// Update shell RC file
	update_shell_rc(shell, ext)
}

init_shell_configs :: proc(shell: ShellType, ext: string) {
	created_files := 0

	config_files := []struct {
		name:     string,
		template: proc(ShellType) -> string,
	}{
		{"path", get_path_template},
		{"aliases", get_aliases_template},
		{"constants", get_constants_template},
		{"init", get_init_template},
		{"tools", get_tools_template},
	}

	for config in config_files {
		config_file := fmt.aprintf("%s/%s.%s", WAYU_CONFIG, config.name, ext)
		defer delete(config_file)

		if !os.exists(config_file) {
			spinner := new_spinner(.Line)
			spinner_text_str := fmt.aprintf("Creating %s.%s", config.name, ext)
			defer delete(spinner_text_str)
			spinner_text(&spinner, spinner_text_str)
			spinner_start(&spinner)

			success := init_config_file(config_file, config.template(shell))

			spinner_stop(&spinner)

			if success {
				print_success("Created config file: %s", config_file)
				created_files += 1
			} else {
				print_error_simple("Failed to create config file: %s", config_file)
			}
		} else {
			print_info("Config file already exists: %s", config_file)
		}
	}

	if created_files > 0 {
		print_success("Created %d config file(s)", created_files)
	} else {
		print_info("All config files already exist")
	}
}

update_shell_rc :: proc(shell: ShellType, ext: string) {
	rc_file_path := get_rc_file_path(shell)
	defer delete(rc_file_path)

	init_file := fmt.aprintf("%s/init.%s", WAYU_CONFIG, ext)
	defer delete(init_file)

	// Check if RC file exists
	if !os.exists(rc_file_path) {
		shell_name := get_shell_name(shell)
		fmt.printfln("\nNo %s found. Create one and add the following line:", rc_file_path)
		fmt.printfln("  source %s", init_file)
		return
	}

	// Read RC file
	data, read_ok := os.read_entire_file_from_filename(rc_file_path)
	if !read_ok {
		fmt.eprintfln("Error: Failed to read %s", rc_file_path)
		return
	}
	defer delete(data)

	content := string(data)

	// Check if wayu is already sourced
	if strings.contains(content, "wayu/init") {
		fmt.println("\n✓ Wayu is already initialized in your shell RC file")
		return
	}

	// Ask user if they want to update
	shell_name := get_shell_name(shell)
	fmt.printfln("\nWayu setup is complete!")
	fmt.printfln("Would you like to add wayu to your %s? [Y/n]: ", rc_file_path)

	input_buf: [10]byte
	n, err := os.read(os.stdin, input_buf[:])
	if err != nil {
		fmt.printfln("\nTo manually initialize wayu, add this line to your %s:", rc_file_path)
		fmt.printfln("  source %s", init_file)
		return
	}

	response := strings.trim_space(string(input_buf[:n]))

	if response == "" || response == "y" || response == "Y" {
		// Append to RC file
		new_content := fmt.aprintf("%s\n# Wayu shell configuration\nsource \"%s\"\n", content, init_file)
		defer delete(new_content)

		write_ok := os.write_entire_file(rc_file_path, transmute([]byte)new_content)
		if !write_ok {
			fmt.eprintfln("Error: Failed to write to %s", rc_file_path)
			return
		}

		fmt.printfln("✓ Successfully added wayu to %s", rc_file_path)
		fmt.printfln("Run 'source %s' or restart your shell to apply changes", rc_file_path)
	} else {
		fmt.printfln("\nTo manually initialize wayu, add this line to your %s:", rc_file_path)
		fmt.printfln("  source %s", init_file)
	}
}

print_version :: proc() {
	fmt.printfln("wayu v%s", VERSION)
	fmt.printfln("A shell configuration management CLI for Bash and ZSH")
}

print_help :: proc() {
	header_text := fmt.aprintf("wayu v%s - Shell configuration management tool\n", VERSION)
	defer delete(header_text)
	print_header(header_text, EMOJI_MOUNTAIN)

	print_section("USAGE:", EMOJI_USER)
	fmt.printf("  wayu <command> <action> [arguments]\n")
	fmt.println()

	print_section("COMMANDS:", EMOJI_COMMAND)
	print_item("", "path", "Manage PATH entries", EMOJI_PATH)
	print_item("", "alias", "Manage shell aliases", EMOJI_ALIAS)
	print_item("", "constants", "Manage environment constants", EMOJI_CONSTANT)
	print_item("", "completions", "Manage Zsh completion scripts", EMOJI_COMMAND)
	print_item("", "backup", "Manage configuration backups", EMOJI_INFO)
	print_item("", "plugin", "Manage shell plugins", EMOJI_COMMAND)
	print_item("", "init", "Initialize wayu configuration directory", EMOJI_INFO)
	print_item("", "migrate", "Migrate configuration between shells", EMOJI_INFO)
	print_item("", "version", "Show version information", EMOJI_INFO)
	print_item("", "help", "Show this help message", EMOJI_INFO)
	fmt.println()

	print_section("ACTIONS:", EMOJI_ACTION)
	print_item("", "add", "Add a new entry", EMOJI_ADD)
	print_item("", "remove, rm", "Remove an entry (interactive if no args)", EMOJI_REMOVE)
	print_item("", "list, ls", "List all entries", EMOJI_LIST)
	print_item("", "help", "Show command-specific help", EMOJI_INFO)
	fmt.println()

	print_section("FLAGS:", EMOJI_ACTION)
	print_item("", "--dry-run, -n", "Preview changes without modifying files", EMOJI_INFO)
	print_item("", "--tui", "Launch interactive Terminal UI mode", EMOJI_INFO)
	fmt.println()

	print_section("EXAMPLES:", EMOJI_CYCLIST)
	fmt.printf("  wayu path add /usr/local/bin\n")
	fmt.printf("  wayu path add                    # Uses current directory\n")
	fmt.printf("  wayu path rm                     # Interactive removal\n")
	fmt.printf("  wayu alias add ll 'ls -la'\n")
	fmt.printf("  wayu alias rm                    # Interactive removal\n")
	fmt.printf("  wayu constants add MY_VAR value\n")
	fmt.printf("  wayu constants rm                # Interactive removal\n")
	fmt.printf("  wayu completions add jj /path/to/_jj\n")
	fmt.printf("  wayu completions rm              # Interactive removal\n")
	fmt.printf("  wayu backup list                 # Show all backups\n")
	fmt.printf("  wayu backup restore path         # Restore path config\n")
	fmt.printf("  wayu plugin add syntax-highlighting  # Install plugin\n")
	fmt.printf("  wayu plugin list                 # Show installed plugins\n")
	fmt.printf("  wayu migrate --from zsh --to bash # Migrate between shells\n")
	fmt.println()
	fmt.printf("  # Preview changes with dry-run:\n")
	fmt.printf("  wayu --dry-run path add /new/path\n")
	fmt.printf("  wayu -n alias add gc 'git commit'\n")
	fmt.println()
}

handle_migrate_command :: proc(args: []string) {
	if len(args) == 0 {
		print_migrate_help()
		return
	}

	from_shell := ShellType.UNKNOWN
	to_shell := ShellType.UNKNOWN

	// Parse migration arguments
	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--from" && i + 1 < len(args) {
			from_shell = parse_shell_type(args[i + 1])
			i += 1
		} else if arg == "--to" && i + 1 < len(args) {
			to_shell = parse_shell_type(args[i + 1])
			i += 1
		} else if arg == "help" || arg == "-h" || arg == "--help" {
			print_migrate_help()
			return
		} else {
			fmt.eprintfln("Unknown migrate option: %s", arg)
			print_migrate_help()
			os.exit(1)
		}
		i += 1
	}

	// Validate arguments
	if from_shell == .UNKNOWN {
		fmt.eprintfln("Error: --from shell must be specified (bash or zsh)")
		print_migrate_help()
		os.exit(1)
	}

	if to_shell == .UNKNOWN {
		fmt.eprintfln("Error: --to shell must be specified (bash or zsh)")
		print_migrate_help()
		os.exit(1)
	}

	if from_shell == to_shell {
		fmt.eprintfln("Error: source and target shells cannot be the same")
		os.exit(1)
	}

	// Perform migration
	migrate_shell_config(from_shell, to_shell)
}

migrate_shell_config :: proc(from_shell: ShellType, to_shell: ShellType) {
	from_ext := get_shell_extension(from_shell)
	to_ext := get_shell_extension(to_shell)

	fmt.printfln("Migrating from %s to %s...", get_shell_name(from_shell), get_shell_name(to_shell))

	config_types := []string{"path", "aliases", "constants", "init", "tools"}
	migrated_count := 0

	for config_type in config_types {
		from_file := fmt.aprintf("%s/%s.%s", WAYU_CONFIG, config_type, from_ext)
		to_file := fmt.aprintf("%s/%s.%s", WAYU_CONFIG, config_type, to_ext)
		defer delete(from_file)
		defer delete(to_file)

		// Check if source file exists
		if !os.exists(from_file) {
			fmt.printfln("  Skipping %s.%s (file not found)", config_type, from_ext)
			continue
		}

		// Check if target file already exists
		if os.exists(to_file) {
			fmt.printfln("  Warning: %s.%s already exists, skipping migration", config_type, to_ext)
			continue
		}

		// Read source file
		data, read_ok := os.read_entire_file_from_filename(from_file)
		if !read_ok {
			fmt.eprintfln("  Error: Failed to read %s", from_file)
			continue
		}
		defer delete(data)

		content := string(data)

		// Convert shell-specific content
		migrated_content := convert_shell_content(content, from_shell, to_shell, config_type)
		defer delete(migrated_content)

		// Write to target file
		write_ok := os.write_entire_file(to_file, transmute([]byte)migrated_content)
		if !write_ok {
			fmt.eprintfln("  Error: Failed to write %s", to_file)
			continue
		}

		fmt.printfln("  ✓ Migrated %s.%s → %s.%s", config_type, from_ext, config_type, to_ext)
		migrated_count += 1
	}

	if migrated_count > 0 {
		fmt.printfln("\nMigration completed! Migrated %d configuration file(s).", migrated_count)
		fmt.printfln("To use the new configuration:")
		if to_shell == .BASH {
			fmt.printfln("  1. Add this line to your ~/.bashrc or ~/.bash_profile:")
			fmt.printfln("     source \"%s/init.bash\"", WAYU_CONFIG)
		} else {
			fmt.printfln("  1. Add this line to your ~/.zshrc:")
			fmt.printfln("     source \"%s/init.zsh\"", WAYU_CONFIG)
		}
		fmt.printfln("  2. Restart your shell or source the RC file")
	} else {
		fmt.printfln("\nNo files were migrated. Check that source files exist and target files don't already exist.")
	}
}

convert_shell_content :: proc(content: string, from_shell: ShellType, to_shell: ShellType, config_type: string) -> string {
	// For now, simply convert shebang and basic shell references
	// More sophisticated conversion can be added later

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	lines := strings.split_lines(content)
	defer delete(lines)

	for line, i in lines {
		converted_line := line

		// Convert shebang
		if strings.has_prefix(line, "#!/usr/bin/env") {
			if to_shell == .BASH {
				converted_line = "#!/usr/bin/env bash"
			} else {
				converted_line = "#!/usr/bin/env zsh"
			}
		}

		// Convert shell comments
		if strings.contains(line, "(ZSH)") && to_shell == .BASH {
			// Basic replacement - will improve later
			converted_line = line  // Keep original for now
		} else if strings.contains(line, "(Bash)") && to_shell == .ZSH {
			converted_line = line  // Keep original for now
		}

		// Special handling for path.* files - convert deduplication method
		if config_type == "path" {
			if from_shell == .ZSH && to_shell == .BASH {
				// Convert ZSH awk one-liner to Bash array method
				if strings.contains(line, "export PATH=$(echo \"$PATH\" | awk") {
					converted_line = "remove_path_duplicates"
				}
			} else if from_shell == .BASH && to_shell == .ZSH {
				// Convert Bash array method to ZSH awk one-liner
				if strings.trim_space(line) == "remove_path_duplicates" {
					converted_line = "# Remove duplicates from PATH (ZSH-optimized method)\nexport PATH=$(echo \"$PATH\" | awk -v RS=':' -v ORS=':' '!seen[$0]++' | sed 's/:$//')"
				}
			}
		}

		strings.write_string(&builder, converted_line)
		if i < len(lines) - 1 {
			strings.write_string(&builder, "\n")
		}
	}

	return strings.clone(strings.to_string(builder))
}

print_migrate_help :: proc() {
	// Title
	fmt.printf("\n%s%swayu migrate - Shell configuration migration%s\n\n", BOLD, get_primary(), RESET)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu migrate --from <shell> --to <shell>")

	// Options section
	fmt.printf("\n%s%sOPTIONS:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  --from <shell>       Source shell (bash or zsh)")
	fmt.println("  --to <shell>         Target shell (bash or zsh)")
	fmt.println("  help, -h, --help     Show this help message")

	// Examples section
	fmt.printf("\n%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %s# Migrate ZSH config to Bash%s\n", get_muted(), RESET)
	fmt.printf("  %swayu migrate --from zsh --to bash%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Migrate Bash config to ZSH%s\n", get_muted(), RESET)
	fmt.printf("  %swayu migrate --from bash --to zsh%s\n", get_muted(), RESET)

	// Notes section
	fmt.printf("\n%s%sNOTES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %s• Migration creates new shell-specific config files%s\n", get_muted(), RESET)
	fmt.printf("  %s• Existing target files are not overwritten%s\n", get_muted(), RESET)
	fmt.printf("  %s• Shell-specific optimizations are applied automatically%s\n", get_muted(), RESET)
	fmt.printf("  %s• You'll need to update your shell RC file after migration%s\n", get_muted(), RESET)
	fmt.println()
}
