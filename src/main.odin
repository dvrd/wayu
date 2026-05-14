package wayu
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"
import "core:strconv"
import "core:log"
import "core:mem"
import "core:sys/posix"
import "core:time"
// Semantic versioning - update with each release.
// VERSION here is the single source of truth; docs (AGENTS.md, README)
// should not hardcode a version number that can drift.
VERSION :: "4.1.1"

// AppContext bundles all mutable program state.
// Created once in main() and referenced as `wayu.*` throughout the codebase.
// XDG layout: config (~/.config/wayu) for user-edited files,
//             data (~/.local/share/wayu) for generated/runtime files.
AppContext :: struct {
	home:           string,
	config:         string,  // ~/.config/wayu (user-edited files)
	data:           string,  // ~/.local/share/wayu (generated/runtime files)
	shell:          ShellType,
	shell_ext:      string,
	path_file:      string,
	alias_file:     string,
	constants_file: string,
	init_file:      string,
	tools_file:     string,
	dry_run:        bool,
	yes_flag:       bool,
	json_output:    bool,
	source_filter:  string,
	tui_mode:       bool,
	temp_arena:     ^mem.Arena,
}

// Global context — populated once by init_app_context().
wayu: AppContext

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
	BUILD,      // Compile wayu.toml to optimized shell config
	EXPORT,     // High-performance turbo export
	TOML,       // TOML configuration management
	DOCTOR,     // Health check and diagnostics
	TEMPLATE,   // Configuration presets
	HOOKS,      // Pre/post action hooks
	RELOAD,     // File watcher for hot reload
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

init_app_context :: proc(ctx: ^AppContext) {
	heap := runtime.heap_allocator()

	ctx.home = os.get_env("HOME", heap)

	config_dir_override := os.get_env("WAYU_CONFIG_DIR", heap)
	if config_dir_override != "" {
		ctx.config = config_dir_override
		// When overridden (e.g. tests), data lives alongside config
		ctx.data = config_dir_override
	} else {
		ctx.config = fmt.aprintf("%s/.config/wayu", ctx.home, allocator = heap)
		data_dir_override := os.get_env("WAYU_DATA_DIR", heap)
		if data_dir_override != "" {
			ctx.data = data_dir_override
		} else {
			ctx.data = fmt.aprintf("%s/.local/share/wayu", ctx.home, allocator = heap)
		}
	}

	ctx.shell = detect_shell()
	ctx.shell_ext = get_shell_extension(ctx.shell)
	ctx.path_file = fmt.aprintf("path.%s", ctx.shell_ext, allocator = heap)
	ctx.alias_file = fmt.aprintf("aliases.%s", ctx.shell_ext, allocator = heap)
	ctx.constants_file = fmt.aprintf("constants.%s", ctx.shell_ext, allocator = heap)
	ctx.init_file = fmt.aprintf("init.%s", ctx.shell_ext, allocator = heap)
	ctx.tools_file = fmt.aprintf("tools.%s", ctx.shell_ext, allocator = heap)
}

// Legacy shim — tests call this, so keep the name but populate wayu.
// Idempotent: skips if config or data are already set (avoids overwriting test overrides).
init_shell_globals :: proc() {
	if len(wayu.config) > 0 || len(wayu.data) > 0 do return
	init_app_context(&wayu)
}

// Create a directory and all parent directories (like mkdir -p).
make_directory_all :: proc(path: string) -> (err: os.Error) {
	// Try creating directly first (fast path for when parents exist)
	if make_err := os.make_directory(path); make_err == nil do return nil

	// Build parent path and create parents recursively
	last_slash := strings.last_index(path, "/")
	if last_slash > 1 {
		parent := path[:last_slash]
		if !os.exists(parent) {
			if err = make_directory_all(parent); err != nil {
				return
			}
		}
	}
	return os.make_directory(path)
}

// Shared TUI launch helper — used by both no-args and --tui paths
tui_launch :: proc() {
	wayu.tui_mode = true
	defer wayu.tui_mode = false

	tui_run()
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

  wayu.temp_arena = &temp_arena

  context.temp_allocator = mem.arena_allocator(&temp_arena)

  context.logger = log.create_console_logger(.Debug, { .Level, .Terminal_Color })
  defer log.destroy_console_logger(context.logger)

	// Clean up temp arena at the very end (before arena backing is freed)
	// This defer executes after all other defers in this scope
	defer if wayu.temp_arena != nil do free_all(context.temp_allocator)

	// Check for --no-color flag BEFORE initializing color system
	// This ensures the flag takes precedence over environment variables
	no_color_flag := false
	for arg in os.args[1:] {
		if arg == "--no-color" || arg == "--no-colour" {
			no_color_flag = true
			break
		}
	}

	// Initialize color system (PRP-09 Phase 1)
	init_colors()

	// Override with --no-color if present (takes precedence over NO_COLOR env)
	if no_color_flag {
		CURRENT_COLOR_PROFILE = .ASCII
		// Reinitialize ANSI codes for ASCII mode
		RESET = ""
		BOLD = ""
		DIM = ""
		ITALIC = ""
		UNDERLINE = ""
	}

	init_shell_globals()
	// Note: the legacy `init_config_files()` startup call was removed on
	// 2026-04-24 (code review L4). It did 4 `os.exists` syscalls on every CLI
	// invocation to auto-create empty path/aliases/constants/extra legacy
	// shell files, which are shadowed by wayu.toml anyway. Use explicit
	// `wayu init` (which still calls init_shell_configs) for first-time
	// bootstrap. The main TOML flow calls `ensure_wayu_toml_exists()` on
	// demand, so `wayu path add /foo` on a fresh install still works.

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

	// Hard-break guard: any command that touches wayu.toml refuses to run
	// while the file still uses the obsolete [[paths]]/[[aliases]]/[[constants]]
	// schema. The few commands that either don't read the toml (VERSION/HELP)
	// or are the recovery path itself (MIGRATE) skip this check.
	needs_modern_toml := true
	#partial switch parsed.command {
	case .VERSION, .HELP, .MIGRATE, .UNKNOWN:
		// pure non-toml commands and the recovery path itself
		needs_modern_toml = false
	case .DOCTOR:
		// doctor explicitly reports the legacy-schema issue itself
		// (check_toml_config), and we want it to surface other findings too.
		needs_modern_toml = false
	}
	if needs_modern_toml {
		toml_guard_path := fmt.aprintf("%s/wayu.toml", wayu.config)
		defer delete(toml_guard_path)
		enforce_modern_wayu_toml_or_exit(toml_guard_path)
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
		if parsed.action == .HELP {
			print_init_help()
		} else {
			handle_init_command()
		}
	case .MIGRATE:
		handle_migrate_command(parsed.args)
	case .CONFIG:
		handle_config_extra_command(parsed.action, parsed.args)
	case .BUILD:
		handle_build_command(parsed.action)
	case .EXPORT:
		handle_export_command(parsed.action, parsed.args)
	case .TOML:
		handle_toml_command(parsed.action)
	case .DOCTOR:
		handle_doctor_command(parsed.doctor_fix, parsed.doctor_json, parsed.doctor_profile, parsed.doctor_optimize)
	case .TEMPLATE:
		handle_template_command(parsed.action, parsed.args)
	case .HOOKS:
		handle_hooks_command(parsed.action, parsed.args)
	case .RELOAD:
		// Parse reload action from args
		action := "start"
		if len(parsed.args) > 0 {
			action = parsed.args[0]
		}
		handle_watch_command(action, parsed.args[1:] if len(parsed.args) > 1 else nil)
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



handle_init_command :: proc() {
	print_header("Initializing Wayu Configuration", "🚀")
	fmt.println()

	// Use shell from wayu (set by detect_shell or --shell flag)
	shell := wayu.shell

	// Validate shell compatibility
	shell_valid, shell_msg := validate_shell_compatibility(shell)
	if !shell_valid {
		print_error_simple("%s", shell_msg)
		os.exit(EXIT_CONFIG)
	}

	ext := get_shell_extension(shell)

	print_info("Using shell: %s (config files will use .%s extension)", get_shell_name(shell), ext)
	fmt.println()

	config_dir := fmt.aprintf("%s", wayu.config)
	defer delete(config_dir)
	data_dir := fmt.aprintf("%s", wayu.data)
	defer delete(data_dir)

	// Create config directory (~/.config/wayu)
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

	// Create data directory (~/.local/share/wayu)
	if !os.exists(data_dir) {
		spinner := new_spinner(.Dots)
		spinner_text(&spinner, "Creating data directory")
		spinner_start(&spinner)

		// Create parent directories if needed (e.g. .local/share/ may not exist in test envs)
		err := make_directory_all(data_dir)

		spinner_stop(&spinner)

		if err != nil {
			print_error_simple("Error creating data directory: %v", err)
			os.exit(EXIT_CANTCREAT)
		}
		print_success("Created directory: %s", data_dir)
	} else {
		print_info("Directory already exists: %s", data_dir)
	}

	// Create subdirectories (in data dir — generated/runtime files)
	subdirs := []string{"functions", "completions", "plugins"}
	created_subdirs := 0

	for subdir in subdirs {
		subdir_path := fmt.aprintf("%s/%s", wayu.data, subdir)
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

	// Generate optimized init files with dynamic [env] exports
	print_info("Generating optimized shell init files...")
	generate_optimized_init_all()
	fmt.println()

	// Update shell RC file
	update_shell_rc(shell, ext)
}

init_shell_configs :: proc(shell: ShellType, ext: string) {
	created_files := 0

	config_files := []struct {
		name:     string,
		template: proc(ShellType) -> string,
		dir:      string,  // which base directory to use
	}{
		{"path", get_path_template, wayu.data},
		{"aliases", get_aliases_template, wayu.data},
		{"constants", get_constants_template, wayu.data},
		{"init", get_init_template, wayu.data},
		{"tools", get_tools_template, wayu.config},
		{"extra", get_extra_template, wayu.config},
	}

	for config in config_files {
		config_file := fmt.aprintf("%s/%s.%s", config.dir, config.name, ext)
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
	alias_sources_file := fmt.aprintf("%s/%s", wayu.config, ALIAS_SOURCES_FILE)
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

	// Create wayu.toml scaffold if it doesn't exist
	toml_file := fmt.aprintf("%s/wayu.toml", wayu.config)
	defer delete(toml_file)

	if !os.exists(toml_file) {
		spinner := new_spinner(.Line)
		spinner_text(&spinner, "Creating wayu.toml scaffold")
		spinner_start(&spinner)

		shell_name := get_shell_name(shell)
		toml_scaffold := fmt.aprintf(`[shell]
type = "%s"

[aliases]

[env]
`, shell_name)
		defer delete(toml_scaffold)

		success := init_config_file(toml_file, toml_scaffold)
		spinner_stop(&spinner)
		if success {
			print_success("Created config file: %s", toml_file)
		} else {
			print_error_simple("Failed to create config file: %s", toml_file)
		}
	} else {
		print_info("Config file already exists: %s", toml_file)
	}
}

update_shell_rc :: proc(shell: ShellType, ext: string) {
	rc_file_path := get_rc_file_path(shell)
	defer delete(rc_file_path)

	init_file := fmt.aprintf("%s/init.%s", wayu.data, ext)
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

	// Ask user if they want to update (only if stdin is a TTY)
	shell_name := get_shell_name(shell)
	fmt.printfln("\nWayu setup is complete!")

	// Only prompt if stdin is a TTY (interactive mode)
	if !os.is_tty(os.stdin) {
		fmt.printfln("\nTo manually initialize wayu, add this line to your %s:", rc_file_path)
		fmt.printfln("  source %s", init_file)
		return
	}

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
	fmt.printfln("Shell configuration management tool")
}

print_init_help :: proc() {
	fmt.println("wayu init - Initialize wayu configuration directory")
	fmt.println()
	fmt.println("USAGE:")
	fmt.println("  wayu init")
	fmt.println()
	fmt.println("DESCRIPTION:")
	fmt.println("  Creates ~/.config/wayu and ~/.local/share/wayu with shell-specific config files (path, aliases,")
	fmt.println("  constants, init, tools, extra) and subdirectories (functions, completions,")
	fmt.println("  plugins). Detects the current shell and generates wayu.toml scaffolding.")
	fmt.println("  Safe to re-run — existing files are preserved.")
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
	print_item("", "constants", "Manage environment constants (aliases: const, env)", EMOJI_CONSTANT)
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
	print_item("", "config", "Manage configuration files (edit, extend, scan)", EMOJI_INFO)
	print_item("", "reload", "Watch config files and regenerate static output (aliases: watch, hot-reload)", "\U0001F440")
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
	fmt.printf("  # Edit ~/.config/wayu/wayu.toml  # Edit declarative config\n")
	fmt.println()
	fmt.printf("  # Configuration files:\n")
	fmt.printf("  wayu config edit                 # Edit wayu.toml (declarative)\n")
	fmt.printf("  wayu config extend               # Edit extra.zsh (scripts)\n")
	fmt.printf("  wayu config scan                 # Detect scripts in .zshrc\n")
	fmt.printf("  wayu config                      # Same as 'config edit'\n")
	fmt.println()
	fmt.printf("  # Diagnostics:\n")
	fmt.printf("  wayu doctor                      # Health check all configs\n")
	fmt.printf("  wayu doctor --fix                # Auto-fix issues\n")
	fmt.println()
	fmt.printf("  # Templates:\n")
	fmt.printf("  wayu template list               # List config presets\n")
	fmt.printf("  wayu template apply developer    # Apply developer preset\n")
	fmt.println()
	fmt.printf("  # Hooks:\n")
	fmt.printf("  wayu hooks                       # Show configured hooks\n")
	fmt.printf("  wayu hooks edit                  # Edit hooks config\n")
	fmt.println()
	fmt.printf("  # Hot reload (auto-regenerate on file change):\n")
	fmt.printf("  wayu reload                      # Start watcher (Ctrl+C to stop)\n")
	fmt.printf("  wayu reload status               # Check if watcher is running\n")
	fmt.printf("  wayu reload regenerate           # One-shot regeneration\n")
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

// handle_build_command - Compile wayu.toml to optimized shell config
handle_build_command :: proc(action: Action) {
	// Show help for unknown actions or explicit help request
	if action == .HELP || action == .UNKNOWN {
		print_build_help()
		return
	}
	
	turbo_mode := action == .TURBO
	eval_mode := action == .EVAL
	profile_mode := action == .CHECK
	
	if profile_mode {
		profile_startup_performance()
		return
	}
	
	if turbo_mode {
		handle_export_command(.TURBO, {})
		return
	}
	
	if eval_mode {
		generate_eval_output_optimized()
		return
	}
	
	// Standard build - use the optimized code generator
	print_header("Building Shell Configuration", "🔧")
	fmt.println()
	
	// Check for wayu.toml
	toml_path := fmt.aprintf("%s/wayu.toml", wayu.config)
	defer delete(toml_path)
	
	if !os.exists(toml_path) {
		print_info("No wayu.toml found. Using existing shell configs.")
		fmt.println()
		fmt.println("To create wayu.toml:")
		fmt.printfln("  %swayu toml convert%s", get_primary(), RESET)
		return
	}
	
	// For now, delegate to the export/turbo system
	// In the future, this will use the adaptive optimizer
	fmt.println("Compiling configuration...")
	fmt.println()
	fmt.println("For now, using turbo export:")
	handle_export_command(.TURBO, {})
}
// Golden file directory
GOLDEN_DIR :: "tests/golden"

// Run component test mode
run_component_testing :: proc(component_name: string, args: []string, snapshot: bool, verify: bool) {
	// Parse component type
	component_type, ok := parse_component_type(component_name)
	if !ok {
		fmt.eprintfln("ERROR: Unknown component type: %s", component_name)
		fmt.eprintln("\nAvailable components:")
		fmt.eprintln("  - box")
		fmt.eprintln("  - list-item")
		fmt.eprintln("  - header")
		fmt.eprintln("  - footer")
		fmt.eprintln("  - scroll-indicator")
		fmt.eprintln("  - empty-state")
		os.exit(EXIT_USAGE)
	}

	// Parse component arguments
	component_args := parse_component_args(args)
	defer component_args_destroy(&component_args)

	// Render component
	output := render_component(component_type, component_args)
	defer delete(output)

	// Handle different modes
	if snapshot {
		// Save golden file
		success := save_golden(component_name, component_args, output)
		if !success {
			os.exit(EXIT_IOERR)
		}
	} else if verify {
		// Test against golden file
		success := compare_golden(component_name, component_args, output)
		if !success {
			os.exit(EXIT_GENERAL)
		}
	} else {
		// Just print output
		fmt.print(output)
	}
}

// Save golden file
save_golden :: proc(component: string, args: ComponentArgs, output: string) -> bool {
	// Ensure directory exists
	os.make_directory(GOLDEN_DIR)

	// Build golden file path
	filename := fmt.aprintf("%s/%s_%dx%d.txt",
		GOLDEN_DIR, component, args.width, args.height)
	defer delete(filename)

	// Write golden file
	write_err := os.write_entire_file(filename, transmute([]byte)output)
	if write_err != nil {
		fmt.eprintfln("ERROR: Failed to write golden file: %s", filename)
		return false
	}

	fmt.printfln("✓ Saved golden file: %s", filename)
	return true
}

// Compare output against golden file
compare_golden :: proc(component: string, args: ComponentArgs, output: string) -> bool {
	// Build golden file path
	filename := fmt.aprintf("%s/%s_%dx%d.txt",
		GOLDEN_DIR, component, args.width, args.height)
	defer delete(filename)

	// Check if golden file exists
	if !os.exists(filename) {
		fmt.eprintfln("ERROR: Golden file not found: %s", filename)
		fmt.eprintfln("Create it with: wayu -c=%s width=%d height=%d --snapshot",
			component, args.width, args.height)
		return false
	}

	// Read golden file
	golden_data, read_err := os.read_entire_file(filename, context.allocator)
	if read_err != nil {
		fmt.eprintfln("ERROR: Failed to read golden file: %s", filename)
		return false
	}
	defer delete(golden_data)

	golden_str := string(golden_data)

	// Compare
	if output != golden_str {
		fmt.eprintfln("✗ MISMATCH: %s", filename)
		fmt.eprintln("\nExpected:")
		fmt.eprintln(golden_str)
		fmt.eprintln("\nGot:")
		fmt.eprintln(output)
		return false
	}

	fmt.printfln("✓ MATCH: %s", filename)
	return true
}
