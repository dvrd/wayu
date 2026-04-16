package wayu

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"
import "core:log"
import "core:mem"
import "core:sys/posix"
import tui "tui"

// Semantic versioning - update with each release
VERSION :: "3.10.0"

HOME : string
WAYU_CONFIG : string

// Global flags
DRY_RUN := false
YES_FLAG := false  // Skip confirmation prompts
DETECTED_SHELL : ShellType
SHELL_EXT : string

// Global temp arena for cleaning up after commands
TEMP_ARENA: ^mem.Arena

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
	CONFIG,
	EXPORT,     // High-performance turbo export
	TOML,       // TOML configuration management
	DOCTOR,     // Health check and diagnostics
	TEMPLATE,   // Configuration presets
	HOOKS,      // Pre/post action hooks
	VERSION,
	HELP,
	SEARCH,     // Global fuzzy search across all configs
	UNKNOWN,
}

Action :: enum {
	ADD,
	REMOVE,
	LIST,
	GET,
	CHECK,
	UPDATE,
	ENABLE,   // NEW - Phase 3
	DISABLE,  // NEW - Phase 3
	PRIORITY, // NEW - Phase 5
	SEARCH,
	RESTORE,
	CLEAN,
	TURBO,    // Export turbo mode
	EVAL,     // Export eval mode
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

	// Doctor options
	doctor_fix:  bool,
	doctor_json: bool,
}

init_shell_globals :: proc() {
	// Only initialize once - prevents issues with parallel test execution
	// where multiple threads try to initialize/free shared global strings
	if _GLOBALS_INITIALIZED {
		return
	}

	// Use the heap allocator for globals so they survive the test runner's
	// per-test tracking allocator cleanup. Without this, the first test to
	// call init_shell_globals allocates via the tracking allocator; when that
	// test finishes, the tracker frees the memory, leaving WAYU_CONFIG etc.
	// as dangling pointers for all subsequent tests.
	heap := runtime.heap_allocator()

	// Initialize HOME and WAYU_CONFIG
	// NOTE: These are intentionally not freed - they're globals that live for
	// the program's lifetime and are accessed throughout the codebase.
	HOME = os.get_env("HOME", heap)
	WAYU_CONFIG = fmt.aprintf("%s/.config/wayu", HOME, allocator = heap)

	// Detect shell
	DETECTED_SHELL = detect_shell()

	SHELL_EXT = get_shell_extension(DETECTED_SHELL)
	PATH_FILE = fmt.aprintf("path.%s", SHELL_EXT, allocator = heap)
	ALIAS_FILE = fmt.aprintf("aliases.%s", SHELL_EXT, allocator = heap)
	CONSTANTS_FILE = fmt.aprintf("constants.%s", SHELL_EXT, allocator = heap)
	INIT_FILE = fmt.aprintf("init.%s", SHELL_EXT, allocator = heap)
	TOOLS_FILE = fmt.aprintf("tools.%s", SHELL_EXT, allocator = heap)

	_GLOBALS_INITIALIZED = true
}

// Shared TUI launch helper — used by both no-args and --tui paths
tui_launch :: proc() {
	tui.tui_set_bridge_functions(
		tui_bridge_load_path,
		tui_bridge_load_alias,
		tui_bridge_load_constants,
		tui_bridge_load_completions,
		tui_bridge_load_backups,
		tui_bridge_delete_path,
		tui_bridge_delete_alias,
		tui_bridge_delete_constant,
		tui_bridge_cleanup_backups,
		tui_bridge_get_path_detail,
		tui_bridge_add_path,
		tui_bridge_add_alias,
		tui_bridge_add_constant,
		tui_bridge_load_plugins,
		tui_bridge_enable_plugin,
		tui_bridge_disable_plugin,
		tui_bridge_load_registry,
		tui_bridge_install_plugin,
	)

	tui.tui_run()
}

main :: proc() {
  // Set up temp arena for transient allocations (string building, intermediate operations, etc.)
  // This arena is automatically cleared, reducing memory fragmentation
  // Keep context.allocator as heap for now to maintain compatibility with existing delete() calls
  temp_arena_backing := make([]byte, 2 * 1024 * 1024)  // 2MB for temp arena
  defer delete(temp_arena_backing)

  temp_arena: mem.Arena
  mem.arena_init(&temp_arena, temp_arena_backing)
  // No need to explicitly destroy arena - just free the backing buffer

  // Make temp arena globally accessible for cleanup after commands
  TEMP_ARENA = &temp_arena

  context.temp_allocator = mem.arena_allocator(&temp_arena)

  context.logger = log.create_console_logger(.Debug, { .Level, .Terminal_Color })
  defer log.destroy_console_logger(context.logger)

	// Clean up temp arena at the very end (before arena backing is freed)
	// This defer executes after all other defers in this scope
	defer if TEMP_ARENA != nil do free_all(context.temp_allocator)

	// Initialize color system (PRP-09 Phase 1)
	init_colors()

	init_shell_globals()
	init_config_files()

	// No arguments → launch TUI (the primary interface)
	if len(os.args) < 2 {
		tui_launch()
		return
	}

	parsed := parse_args(os.args[1:])
	defer if len(parsed.args) > 0 do delete(parsed.args)

	// Launch TUI if flag present
	if parsed.tui {
		tui_launch()
		return
	}

	// Component test mode (PRP-13)
	if parsed.component_test {
		run_component_testing(parsed.component_name, parsed.args,
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
		if parsed.action == .UPDATE {
			handle_completions_generate()
		} else {
			handle_completions_command_extended(parsed.action, parsed.args)
		}
	case .BACKUP:
		handle_backup_command(parsed.action, parsed.args)
	case .PLUGIN:
		handle_plugin_command(parsed.action, parsed.args)
	case .INIT:
		handle_init_command()
	case .MIGRATE:
		handle_migrate_command(parsed.args)
	case .CONFIG:
		handle_config_extra_command(parsed.action)
	case .EXPORT:
		handle_export_command(parsed.action, parsed.args)
	case .TOML:
		handle_toml_command(parsed.action)
	case .DOCTOR:
		handle_doctor_command(parsed.doctor_fix, parsed.doctor_json)
	case .TEMPLATE:
		handle_template_command(parsed.action, parsed.args)
	case .HOOKS:
		handle_hooks_command(parsed.action, parsed.args)
	case .VERSION:
		print_version()
	case .HELP:
		print_help()
	case .SEARCH:
		handle_search_command(parsed.args)
	case .UNKNOWN:
		fmt.eprintfln("Unknown command: %s", os.args[1])
		print_help()
		os.exit(EXIT_USAGE)
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
		} else if arg == "--yes" || arg == "-y" {
			YES_FLAG = true
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
			// Update global detected shell
			DETECTED_SHELL = parsed.shell
			// Update global shell extension for dry-run messages and file operations
			SHELL_EXT = get_shell_extension(parsed.shell)
			// Free old file name globals before reassigning (they were allocated by init_shell_globals)
			delete(PATH_FILE)
			delete(ALIAS_FILE)
			delete(CONSTANTS_FILE)
			delete(INIT_FILE)
			delete(TOOLS_FILE)
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

	// Assign global flags once here — every return path below inherits them.
	parsed.tui              = tui_flag
	parsed.component_test   = component_test_flag
	parsed.component_name   = component_name_str
	parsed.component_snapshot = snapshot_flag
	parsed.component_verify = verify_flag

	// Handle component test mode early - all filtered args become component args.
	if component_test_flag {
		if len(filtered_args) > 0 {
			remaining_args := make([]string, len(filtered_args))
			copy(remaining_args, filtered_args[:])
			parsed.args = remaining_args
		}
		return parsed
	}

	if len(filtered_args) == 0 {
		parsed.command = .HELP
		return parsed
	}

	// Parse command.
	switch filtered_args[0] {
	case "path":       parsed.command = .PATH
	case "alias":      parsed.command = .ALIAS
	case "constants", "const":  parsed.command = .CONSTANTS
	case "backup":     parsed.command = .BACKUP
	case "plugin":     parsed.command = .PLUGIN
	case "init":       parsed.command = .INIT;    return parsed
	case "migrate":    parsed.command = .MIGRATE; return parsed
	case "config":
		parsed.command = .CONFIG
		// Parse config subcommand
		if len(filtered_args) > 1 {
			switch filtered_args[1] {
			case "extend", "e":
				parsed.action = .ADD  // Use ADD for extend (extra.zsh)
			case "edit":
				parsed.action = .UPDATE  // Use UPDATE for edit (wayu.toml)
			case "scan", "s", "detect":
				parsed.action = .CHECK  // Use CHECK for scan
			case "help", "-h", "--help":
				parsed.action = .HELP
			case:
				parsed.action = .UNKNOWN
			}
		} else {
			parsed.action = .HELP // Default: show help
		}
		return parsed
	case "completions":
		parsed.command = .COMPLETIONS
		if len(filtered_args) > 1 {
			switch filtered_args[1] {
			case "add":
				parsed.action = .ADD
			case "remove", "rm":
				parsed.action = .REMOVE
			case "list", "ls":
				parsed.action = .LIST
			case "generate", "gen":
				parsed.action = .UPDATE  // Use UPDATE for generate
			case "help", "-h", "--help":
				parsed.action = .HELP
			case:
				parsed.action = .UNKNOWN
			}
			if len(filtered_args) > 2 {
				parsed.args = make([]string, len(filtered_args) - 2)
				copy(parsed.args, filtered_args[2:])
			}
		} else {
			parsed.action = .LIST
		}
		return parsed
	case "export":
		parsed.command = .EXPORT
		parsed.action = .TURBO // Default action for export is turbo
		// Capture sub-action and args for export
		if len(filtered_args) > 1 {
			// First arg after "export" is the action
			action_str := filtered_args[1]
			switch action_str {
			case "turbo":
				parsed.action = .TURBO
			case "eval":
				parsed.action = .EVAL
			case "list", "ls":
				parsed.action = .LIST
			case "help", "-h", "--help":
				parsed.action = .HELP
			case:
				// Unknown action - default to turbo
				parsed.action = .TURBO
			}
			// Capture remaining args after action
			if len(filtered_args) > 2 {
				parsed.args = make([]string, len(filtered_args) - 2)
				copy(parsed.args, filtered_args[2:])
			}
		}
		return parsed
	case "toml":
		parsed.command = .TOML
		// Parse toml subcommand
		if len(filtered_args) > 1 {
			switch filtered_args[1] {
			case "validate":
				parsed.action = .CHECK
			case "convert", "apply":
				parsed.action = .UPDATE
			case "help", "-h", "--help":
				parsed.action = .HELP
			case:
				parsed.action = .UNKNOWN
			}
		} else {
			parsed.action = .LIST // Default: list/info
		}
		return parsed
	case "version", "-v", "--version": parsed.command = .VERSION; return parsed
	case "help", "-h", "--help":       parsed.command = .HELP;    return parsed
	case "doctor":
		parsed.command = .DOCTOR
		// Parse doctor flags
		for i := 1; i < len(filtered_args); i += 1 {
			switch filtered_args[i] {
			case "--fix":    parsed.doctor_fix = true
			case "--json":   parsed.doctor_json = true
			case "--help", "-h":
				print_doctor_usage()
				os.exit(0)
			}
		}
		return parsed
	case "template":
		parsed.command = .TEMPLATE
		if len(filtered_args) > 1 {
			switch filtered_args[1] {
			case "list", "ls":
				parsed.action = .LIST
			case "apply":
				parsed.action = .ADD
				if len(filtered_args) > 2 {
					parsed.args = make([]string, len(filtered_args) - 2)
					copy(parsed.args, filtered_args[2:])
				}
			case "help", "-h", "--help":
				parsed.action = .HELP
			case:
				parsed.action = .UNKNOWN
			}
		} else {
			parsed.action = .LIST
		}
		return parsed
	case "hooks":
		parsed.command = .HOOKS
		if len(filtered_args) > 1 {
			switch filtered_args[1] {
			case "list", "ls":
				parsed.action = .LIST
			case "edit":
				parsed.action = .ADD
			case "help", "-h", "--help":
				parsed.action = .HELP
			case:
				parsed.action = .UNKNOWN
			}
		} else {
			parsed.action = .LIST
		}
		return parsed
	case "search", "find", "f":
		parsed.command = .SEARCH
		// Capture query argument(s) for search
		if len(filtered_args) > 1 {
			remaining_args := make([]string, len(filtered_args) - 1)
			copy(remaining_args, filtered_args[1:])
			parsed.args = remaining_args
		}
		return parsed
	case:              parsed.command = .UNKNOWN; return parsed
	}

	// Parse action (commands that have sub-actions reach here).
	if len(filtered_args) < 2 {
		parsed.action = .LIST
		return parsed
	}

	switch filtered_args[1] {
	case "add":              parsed.action = .ADD
	case "remove", "rm":    parsed.action = .REMOVE
	case "list", "ls":      parsed.action = .LIST
	case "get":             parsed.action = .GET
	case "check":           parsed.action = .CHECK
	case "update":          parsed.action = .UPDATE
	case "enable":          parsed.action = .ENABLE
	case "disable":         parsed.action = .DISABLE
	case "priority":        parsed.action = .PRIORITY
	case "search":          parsed.action = .SEARCH
	case "restore":         parsed.action = .RESTORE
	case "clean":           parsed.action = .CLEAN
	case "dedup":           parsed.action = .DEDUP
	case "turbo":           parsed.action = .TURBO
	case "eval":            parsed.action = .EVAL
	case "help", "-h", "--help": parsed.action = .HELP
	case:                   parsed.action = .UNKNOWN; return parsed
	}

	// Remaining positional args (e.g. the path/name/value after the action).
	if len(filtered_args) > 2 {
		remaining_args := make([]string, len(filtered_args) - 2)
		copy(remaining_args, filtered_args[2:])
		parsed.args = remaining_args
	}

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
		os.exit(EXIT_CONFIG)
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
			os.exit(EXIT_CANTCREAT)
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
				os.exit(EXIT_CANTCREAT)
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
		{"extra", get_extra_template},
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

	// alias-sources.conf is shell-agnostic — create once regardless of shell
	alias_sources_file := fmt.aprintf("%s/%s", WAYU_CONFIG, ALIAS_SOURCES_FILE)
	defer delete(alias_sources_file)

	if !os.exists(alias_sources_file) {
		spinner := new_spinner(.Line)
		spinner_text(&spinner, "Creating alias-sources.conf")
		spinner_start(&spinner)
		success := init_config_file(alias_sources_file, ALIAS_SOURCES_TEMPLATE)
		spinner_stop(&spinner)
		if success {
			print_success("Created config file: %s", alias_sources_file)
		} else {
			print_error_simple("Failed to create config file: %s", alias_sources_file)
		}
	} else {
		print_info("Config file already exists: %s", alias_sources_file)
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
	data, read_err := os.read_entire_file(rc_file_path, context.allocator)
	if read_err != nil {
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

		write_err := os.write_entire_file(rc_file_path, transmute([]byte)new_content)
		if write_err != nil {
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
	fmt.printf("  wayu                    Launch interactive TUI (default)\n")
	fmt.printf("  wayu <command> <action> [arguments]\n")
	fmt.println()

	print_section("COMMANDS:", EMOJI_COMMAND)
	print_item("", "path", "Manage PATH entries", EMOJI_PATH)
	print_item("", "alias", "Manage shell aliases", EMOJI_ALIAS)
	print_item("", "constants", "Manage environment constants (alias: const)", EMOJI_CONSTANT)
	print_item("", "search, find, f", "Fuzzy search across all configurations", "🔍")
	print_item("", "toml", "TOML configuration management", "⚙️ ")
	print_item("", "doctor", "Health check and diagnostics", "🔬")
	print_item("", "template", "Configuration presets", "📋")
	print_item("", "hooks", "Pre/post action hooks", "🪝")
	print_item("", "completions", "Manage Zsh completion scripts", EMOJI_COMMAND)
	print_item("", "backup", "Manage configuration backups", EMOJI_INFO)
	print_item("", "plugin", "Manage shell plugins", EMOJI_COMMAND)
	print_item("", "init", "Initialize wayu configuration directory", EMOJI_INFO)
	print_item("", "migrate", "Migrate configuration between shells", EMOJI_INFO)
	print_item("", "config", "Manage extra config (extend, scan)", EMOJI_INFO)
	print_item("", "version", "Show version information", EMOJI_INFO)
	print_item("", "help", "Show this help message", EMOJI_INFO)
	fmt.println()

	print_section("ACTIONS:", EMOJI_ACTION)
	print_item("", "add", "Add a new entry", EMOJI_ADD)
	print_item("", "remove, rm", "Remove an entry (interactive if no args)", EMOJI_REMOVE)
	print_item("", "list, ls", "List all entries", EMOJI_LIST)
	print_item("", "check", "Check for updates (plugins only)", EMOJI_INFO)
	print_item("", "update", "Update entry (plugins only)", EMOJI_INFO)
	print_item("", "help", "Show command-specific help", EMOJI_INFO)
	fmt.println()

	print_section("FLAGS:", EMOJI_ACTION)
	print_item("", "--dry-run, -n", "Preview changes without modifying files", EMOJI_INFO)
	print_item("", "--yes, -y", "Skip confirmation prompts (for clean/dedup)", EMOJI_INFO)
	print_item("", "--tui", "Launch interactive Terminal UI mode (same as no args)", EMOJI_INFO)
	print_item("", "-c=<component>", "Test TUI component rendering (dev mode)", EMOJI_INFO)
	print_item("", "--snapshot", "Save component output as golden file", EMOJI_INFO)
	print_item("", "--test", "Test component against golden file", EMOJI_INFO)
	fmt.println()

	print_section("EXAMPLES:", EMOJI_CYCLIST)
	fmt.printf("  wayu path add /usr/local/bin\n")
	fmt.printf("  wayu alias add ll 'ls -la'\n")
	fmt.printf("  wayu constants add MY_VAR value\n")
	fmt.printf("  wayu search api                  # Search across all configs\n")
	fmt.printf("  wayu find frwrks                 # Fuzzy find by acronym\n")
	fmt.printf("  wayu f git                       # Short alias for search\n")
	fmt.printf("  wayu completions add jj /path/to/_jj\n")
	fmt.printf("  wayu backup list                 # Show all backups\n")
	fmt.printf("  wayu backup restore path         # Restore path config\n")
	fmt.printf("  wayu plugin add syntax-highlighting  # Install plugin\n")
	fmt.printf("  wayu plugin check                # Check plugins for updates\n")
	fmt.printf("  wayu plugin update plugin-name   # Update specific plugin\n")
	fmt.printf("  wayu plugin update --all         # Update all plugins\n")
	fmt.printf("  wayu migrate --from zsh --to bash # Migrate between shells\n")
	fmt.println()
	fmt.printf("  # TOML configuration (declarative mode):\n")
	fmt.printf("  wayu toml validate               # Check wayu.toml syntax\n")
	fmt.printf("  wayu toml convert                # Migrate to TOML format\n")
	fmt.printf("  # Edit ~/.config/wayu/wayu.toml  # Edit declarative config\n")
	fmt.println()
	fmt.printf("  # Configuration files:\n")
	fmt.printf("  wayu config edit                 # Edit wayu.toml (declarative)\n")
	fmt.printf("  wayu config extend               # Edit extra.zsh (scripts)\n")
	fmt.printf("  wayu config scan                 # Detect scripts in .zshrc\n")
	fmt.printf("  wayu config extend               # Same as 'config'\n")
	fmt.println()
	fmt.printf("  # Diagnostics:\n")
	fmt.printf("  wayu doctor                      # Health check all configs\n")
	fmt.printf("  wayu doctor --fix                # Auto-fix issues\n")
	fmt.println()
	fmt.printf("  # Templates:\n")
	fmt.printf("  wayu template list               # List config presets\n")
	fmt.printf("  wayu template apply developer    # Apply developer preset\n")
	fmt.printf("  wayu init --template minimal     # Initialize with preset\n")
	fmt.println()
	fmt.printf("  # Hooks:\n")
	fmt.printf("  wayu hooks                       # Show configured hooks\n")
	fmt.printf("  wayu hooks edit                  # Edit hooks config\n")
	fmt.println()
	fmt.printf("  # Preview changes with dry-run:\n")
	fmt.printf("  wayu --dry-run path add /new/path\n")
	fmt.printf("  wayu -n alias add gc 'git commit'\n")
	fmt.println()
	fmt.printf("  # Destructive operations require --yes flag:\n")
	fmt.printf("  wayu path clean --yes            # Remove missing directories\n")
	fmt.printf("  wayu path dedup --yes            # Remove duplicates\n")
	fmt.println()

	print_section("EXIT CODES:", EMOJI_INFO)
	fmt.printf("  0   Success\n")
	fmt.printf("  1   General error\n")
	fmt.printf("  64  Usage error (invalid arguments)\n")
	fmt.printf("  65  Data format error (invalid input)\n")
	fmt.printf("  66  Input file not found\n")
	fmt.printf("  73  Cannot create output file\n")
	fmt.printf("  74  I/O error (read/write failure)\n")
	fmt.printf("  77  Permission denied\n")
	fmt.printf("  78  Configuration error\n")
	fmt.println()
	fmt.printf("  %sNote:%s Running %swayu%s with no arguments opens the interactive TUI\n", BRIGHT_CYAN, RESET, BOLD, RESET)
	fmt.printf("  %sNote:%s CLI mode is fully non-interactive for scripting/automation\n", BRIGHT_CYAN, RESET)
	fmt.println()
}

handle_config_extra_command :: proc(action: Action) {
	#partial switch action {
	case .ADD: // extend (extra.zsh)
		extra_file := fmt.aprintf("%s/extra.%s", WAYU_CONFIG, SHELL_EXT)
		defer delete(extra_file)
		edit_extra_config(extra_file)
	case .UPDATE: // edit (wayu.toml)
		toml_file := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG)
		defer delete(toml_file)
		edit_toml_config(toml_file)
	case .CHECK: // scan/detect
		scan_zshrc_for_scripts()
	case .HELP:
		print_config_usage()
	case:
		// Default: show help
		print_config_usage()
	}
}

edit_extra_config :: proc(extra_file: string) {
	// Create file if doesn't exist
	if !os.exists(extra_file) {
		content := "# Extra configuration - runs at end of shell initialization\n# Add custom scripts, conda initialization, etc. here\n"
		if write_ok := os.write_entire_file_from_string(extra_file, content); write_ok != nil {
			print_error_simple("Failed to create extra config: %s", extra_file)
			os.exit(EXIT_CANTCREAT)
		}
		print_success("Created extra config: %s", extra_file)
	}

	editor: string
	if e := os.get_env("EDITOR", context.temp_allocator); len(e) > 0 {
		editor = e
	} else if e := os.get_env("VISUAL", context.temp_allocator); len(e) > 0 {
		editor = e
	} else {
		editor = "nvim"
	}

	args := []string{editor, extra_file}

	argv := make([dynamic]cstring, len(args) + 1)
	defer {
		for i in 0..<len(args) {
			delete(argv[i])
		}
		delete(argv)
	}
	for arg, i in args {
		argv[i] = strings.clone_to_cstring(arg)
	}
	argv[len(args)] = nil

	pid := posix.fork()
	if pid < 0 {
		print_error_simple("Failed to fork process")
		os.exit(EXIT_IOERR)
	}

	if pid == 0 {
		posix.execvp(argv[0], raw_data(argv[:]))
		posix._exit(1)
	}

	status: c.int = 0
	posix.waitpid(pid, &status, {})
}

edit_toml_config :: proc(toml_file: string) {
	// Create file with default content if doesn't exist
	if !os.exists(toml_file) {
		default_content := `# Wayu TOML Configuration
# This is a declarative way to manage your shell configuration
# See: https://github.com/kakurega/wayu/blob/main/TOML_GUIDE.md

[settings]
shell = "zsh"

# Example PATH entries
# [[path]]
# value = "/usr/local/bin"
# priority = 100

# Example aliases
# [[aliases]]
# name = "ll"
# command = "ls -la"

# Example constants
# [[constants]]
# name = "EDITOR"
# value = "nvim"
`
		if write_ok := os.write_entire_file_from_string(toml_file, default_content); write_ok != nil {
			print_error_simple("Failed to create wayu.toml: %s", toml_file)
			os.exit(EXIT_CANTCREAT)
		}
		print_success("Created wayu.toml: %s", toml_file)
	}

	editor: string
	if e := os.get_env("EDITOR", context.temp_allocator); len(e) > 0 {
		editor = e
	} else if e := os.get_env("VISUAL", context.temp_allocator); len(e) > 0 {
		editor = e
	} else {
		editor = "nvim"
	}

	args := []string{editor, toml_file}

	argv := make([dynamic]cstring, len(args) + 1)
	defer {
		for i in 0..<len(args) {
			delete(argv[i])
		}
		delete(argv)
	}
	for arg, i in args {
		argv[i] = strings.clone_to_cstring(arg)
	}
	argv[len(args)] = nil

	pid := posix.fork()
	if pid < 0 {
		print_error_simple("Failed to fork process")
		os.exit(EXIT_IOERR)
	}

	if pid == 0 {
		posix.execvp(argv[0], raw_data(argv[:]))
		posix._exit(1)
	}

	status: c.int = 0
	posix.waitpid(pid, &status, {})
}

// Scan .zshrc for inline scripts that should move to extra.zsh
scan_zshrc_for_scripts :: proc() {
	zshrc_file := fmt.aprintf("%s/.zshrc", os.get_env("HOME", context.temp_allocator))
	defer delete(zshrc_file)

	if !os.exists(zshrc_file) {
		print_error_simple(".zshrc not found: %s", zshrc_file)
		os.exit(EXIT_NOINPUT)
	}

	content, read_ok := safe_read_file(zshrc_file)
	if !read_ok {
		print_error_simple("Failed to read .zshrc")
		os.exit(EXIT_IOERR)
	}
	defer delete(content)

	content_str := string(content)
	
	// Patterns that indicate inline scripts (not source commands, not aliases managed by wayu)
	patterns := []string{
		"eval \"$(",
		"export PATH=",
		"alias ",
		"conda initialize",
		"nvm ",
		"pyenv ",
		"rbenv ",
		"fzf ",
		"starship ",
		"zoxide ",
		"eval $(",
		"# >>>",
		"# <<<",
	}
	
	// Find lines that match patterns
	lines := strings.split(content_str, "\n")
	defer delete(lines)
	
	detected_blocks := make([dynamic][dynamic]string)
	defer {
		for block in detected_blocks {
			delete(block)
		}
		delete(detected_blocks)
	}
	
	current_block: [dynamic]string
	in_block := false
	
	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") {
			if in_block && len(current_block) > 0 {
				// End of block
				block_copy := make([dynamic]string)
				append(&block_copy, ..current_block[:])
				append(&detected_blocks, block_copy)
				clear(&current_block)
				in_block = false
			}
			continue
		}
		
		// Check if line starts a script block
		if !in_block {
			for pattern in patterns {
				if strings.contains(trimmed, pattern) {
					in_block = true
					append(&current_block, line)
					break
				}
			}
		} else {
			// Continue block
			append(&current_block, line)
		}
	}
	
	// Add final block if exists
	if in_block && len(current_block) > 0 {
		block_copy := make([dynamic]string)
		append(&block_copy, ..current_block[:])
		append(&detected_blocks, block_copy)
	}
	delete(current_block)
	
	if len(detected_blocks) == 0 {
		print_success("No inline scripts detected in .zshrc")
		print_info("Your .zshrc is clean - all scripts properly sourced")
		return
	}
	
	print_header("Detected Inline Scripts", "🔍")
	fmt.printfln("Found %d potential script blocks in .zshrc:", len(detected_blocks))
	fmt.println()
	
	for block, i in detected_blocks {
		fmt.printfln("%sBlock %d:%s", get_primary(), i + 1, RESET)
		for line in block {
			fmt.printfln("  %s", line)
		}
		fmt.println()
	}
	
	print_info("These scripts should be moved to extra.zsh for better management")
	fmt.println()
	fmt.printfln("Run %swayu config extend%s to edit extra.zsh", get_primary(), RESET)
	fmt.printfln("Or run %swayu config scan --fix%s to auto-migrate (coming soon)", get_primary(), RESET)
}

print_config_usage :: proc() {
	fmt.println()
	fmt.printfln("%swayu config - Manage configuration files%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.printfln("  wayu config              Edit extra.zsh (custom scripts)")
	fmt.printfln("  wayu config extend       Same as 'config'")
	fmt.printfln("  wayu config edit         Edit wayu.toml (declarative config)")
	fmt.printfln("  wayu config scan         Scan .zshrc for inline scripts")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  wayu.toml: Declarative configuration (PATH, aliases, constants)")
	fmt.println("  extra.zsh: Shell scripts that run at end of initialization")
	fmt.println("             Use for conda init, tool evals, custom functions, etc.")
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  # Edit declarative config")
	fmt.println("  wayu config edit")
	fmt.println()
	fmt.println("  # Add conda initialization script")
	fmt.println("  wayu config extend")
	fmt.println("  # Then paste conda init block in the editor")
	fmt.println()
	fmt.println("  # Detect scripts that should move to extra.zsh")
	fmt.println("  wayu config scan")
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
			os.exit(EXIT_USAGE)
		}
		i += 1
	}

	// Validate arguments
	if from_shell == .UNKNOWN {
		fmt.eprintfln("Error: --from shell must be specified (bash or zsh)")
		print_migrate_help()
		os.exit(EXIT_USAGE)
	}

	if to_shell == .UNKNOWN {
		fmt.eprintfln("Error: --to shell must be specified (bash or zsh)")
		print_migrate_help()
		os.exit(EXIT_USAGE)
	}

	if from_shell == to_shell {
		fmt.eprintfln("Error: source and target shells cannot be the same")
		os.exit(EXIT_USAGE)
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
		data, read_err := os.read_entire_file(from_file, context.allocator)
		if read_err != nil {
			fmt.eprintfln("  Error: Failed to read %s", from_file)
			continue
		}
		defer delete(data)

		content := string(data)

		// Convert shell-specific content
		migrated_content := convert_shell_content(content, from_shell, to_shell, config_type)
		defer delete(migrated_content)

		// Write to target file
		write_err := os.write_entire_file(to_file, transmute([]byte)migrated_content)
		if write_err != nil {
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
