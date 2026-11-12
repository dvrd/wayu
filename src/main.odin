package wayu
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:strings"
// Semantic versioning - update with each release.
// VERSION here is the single source of truth; docs (AGENTS.md, README)
// should not hardcode a version number that can drift.
VERSION :: "7.0.0"

// AppContext bundles all mutable program state.
// Created once in main() and referenced as `wayu.*` throughout the codebase.
// XDG layout: config (~/.config/wayu; WAYU_CONFIG_DIR) for files the user edits,
//             data (${XDG_DATA_HOME:-~/.local/share}/wayu; WAYU_DATA_DIR) for
//             everything wayu manages: entries.json, generated/runtime files.
AppContext :: struct {
	home:           string,
	config:         string, // ~/.config/wayu (user-edited files)
	data:           string, // managed + generated files (${XDG_DATA_HOME:-~/.local/share}/wayu; WAYU_DATA_DIR)
	shell:          ShellType,
	shell_ext:      string,
	dry_run:        bool,
	yes_flag:       bool,
	json_output:    bool,
	reveal_secrets: bool, // --reveal: list views print secret-looking values unmasked
	secret_flag:    bool, // --secret: `const add` stores the value encrypted (secrets_store.odin)
	run_only_flag:  bool, // --run-only: that secret is only injected by `wayu secrets run`
	source_filter:  string,
	tui_mode:       bool,
	temp_arena:     ^virtual.Arena,
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
	CONFIG,
	BUILD, // Compile wayu.toml + entries.json into shell init files
	EXPORT, // High-performance turbo export
	TOML, // TOML configuration management
	DOCTOR, // Health check and diagnostics
	TEMPLATE, // Configuration presets
	HOOKS, // Pre/post action hooks
	FUNCTION, // Manage custom shell functions (functions/ dir)
	SCRIPT, // Manage standalone scripts (scripts/ + bin/ in the data dir)
	RELOAD, // File watcher for hot reload
	VERSION,
	HELP,
	SEARCH, // Global fuzzy search across all configs
	SECRETS, // Encrypted secret constants (secrets_store.odin)
	OPTIMIZE, // Move startup-file lines into wayu (optimize.odin)
	UNKNOWN,
}

Action :: enum {
	ADD,
	REMOVE,
	LIST,
	GET,
	CHECK,
	UPDATE,
	ENABLE, // NEW - Phase 3
	DISABLE, // NEW - Phase 3
	PRIORITY, // NEW - Phase 5
	SEARCH,
	RESTORE,
	CLEAN,
	TURBO, // Export turbo mode
	EVAL, // Export eval mode
	DEDUP,
	IMPORT, // script import
	BUILD, // script build
	RUN, // secrets run
	IDENTITY, // secrets identity
	RECIPIENT, // secrets recipient list|add|rm|rename
	ADOPT, // secrets adopt
	RECOVERY, // secrets recovery add|rm|unlock
	FPATH, // completions fpath
	HELP,
	UNKNOWN,
}

init_app_context :: proc(ctx: ^AppContext) {
	heap := runtime.heap_allocator()

	ctx.home = os.get_env("HOME", heap)

	// config: WAYU_CONFIG_DIR, else ~/.config/wayu.
	// data:   WAYU_DATA_DIR, else ${XDG_DATA_HOME:-~/.local/share}/wayu. The
	// generated init derives its data dir from its own location and
	// core.<ext> exports both overrides, so a shell sourcing it runs `wayu`
	// against the same dirs.
	config_dir_override := os.get_env("WAYU_CONFIG_DIR", heap)
	if config_dir_override != "" {
		ctx.config = config_dir_override
	} else {
		ctx.config = fmt.aprintf("%s/.config/wayu", ctx.home, allocator = heap)
	}
	data_dir_override := os.get_env("WAYU_DATA_DIR", heap)
	if data_dir_override != "" {
		ctx.data = data_dir_override
	} else {
		ctx.data = default_data_dir(ctx.home, heap)
	}

	ctx.shell = detect_shell()
	ctx.shell_ext = get_shell_extension(ctx.shell)
}

// The data dir without WAYU_DATA_DIR: $XDG_DATA_HOME/wayu when that is an
// absolute path (the XDG spec ignores relative ones), else
// ~/.local/share/wayu.
default_data_dir :: proc(home: string, allocator := context.allocator) -> string {
	xdg := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if strings.has_prefix(xdg, "/") {
		return fmt.aprintf("%s/wayu", strings.trim_right(xdg, "/"), allocator = allocator)
	}
	return fmt.aprintf("%s/.local/share/wayu", home, allocator = allocator)
}

// The line rc files use to load wayu (README, `wayu init`): finds init.<ext>
// in the data dir however it was chosen. fish has no ${X:-y}.
bootstrap_source_line :: proc(ext: string, allocator := context.temp_allocator) -> string {
	if ext == "fish" {
		return strings.clone(
			`if test -n "$WAYU_DATA_DIR"; source $WAYU_DATA_DIR/init.fish; else if test -n "$XDG_DATA_HOME"; source $XDG_DATA_HOME/wayu/init.fish; else; source ~/.local/share/wayu/init.fish; end`,
			allocator,
		)
	}
	return fmt.aprintf(
		`source "${{WAYU_DATA_DIR:-${{XDG_DATA_HOME:-$HOME/.local/share}}/wayu}}/init.%s"`,
		ext,
		allocator = allocator,
	)
}

// Why WAYU_CONFIG_DIR / WAYU_DATA_DIR cannot be used, "" when both are fine
// (or unset). A relative one is refused (OKAMI-328): wayu, the generated
// init and every shell would resolve it against their own working
// directory. (A relative XDG_DATA_HOME is ignored, as the XDG spec says; see
// default_data_dir.) Temp-allocated.
dir_override_error :: proc() -> string {
	for name in ([]string{"WAYU_CONFIG_DIR", "WAYU_DATA_DIR"}) {
		v := os.get_env(name, context.temp_allocator)
		if len(v) > 0 && !strings.has_prefix(v, "/") {
			return fmt.tprintf("%s must be an absolute path (got %q)", name, v)
		}
	}
	return ""
}

// Populate `wayu` once (tests call it too).
// Idempotent: skips if config or data are already set (avoids overwriting test overrides).
init_shell_globals :: proc() {
	if len(wayu.config) > 0 || len(wayu.data) > 0 do return
	init_app_context(&wayu)
}

// Create a wayu directory and all parent directories (like mkdir -p), 0700
// whatever the umask; an existing dir loses group/other write. Every caller
// creates a wayu config/data dir: see make_wayu_dir (atomic_io.odin).
make_directory_all :: proc(path: string) -> (err: os.Error) {
	return make_wayu_dir(path)
}

// Shared TUI launch helper — used by both no-args and --tui paths
tui_launch :: proc() {
	wayu.tui_mode = true
	defer wayu.tui_mode = false

	tui_run()
}

// Process-wide temp arena (context.temp_allocator). A package global, not a
// local of main, so wayu.temp_arena never points into a stack frame.
@(private = "file")
main_temp_arena: virtual.Arena

main :: proc() {
	// Temp arena for transient allocations (string building, quoting, etc.).
	// Growing (virtual memory, new blocks on demand): the old fixed 256 KB
	// buffer ran out on large configs and tprintf/join then returned empty
	// strings, silently skipping writes such as path_sync. The TUI frame loop
	// and the watcher free_all it per iteration; the CLI frees it at exit.
	// context.allocator stays the heap (existing delete() calls).
	if err := virtual.arena_init_growing(&main_temp_arena); err != nil {
		fmt.eprintln("wayu: cannot reserve memory for the temp arena")
		wayu_exit(EXIT_FAILURE)
	}
	defer virtual.arena_destroy(&main_temp_arena)

	wayu.temp_arena = &main_temp_arena

	context.temp_allocator = virtual.arena_allocator(&main_temp_arena)

	context.logger = log.create_console_logger(.Debug, {.Level, .Terminal_Color})
	defer log.destroy_console_logger(context.logger)

	// Clean up temp arena at the very end (before the arena is destroyed)
	// This defer executes after all other defers in this scope
	defer if wayu.temp_arena != nil do free_all(context.temp_allocator)

	// Fast-exit for --version / -v: skip all initialization.
	if len(os.args) == 2 {
		a := os.args[1]
		if a == "--version" || a == "-v" || a == "version" {
			fmt.printfln("wayu v%s", VERSION)
			fmt.println("Shell configuration management tool")
			return
		}
	}

	// Check for --no-color flag BEFORE initializing color system
	// This ensures the flag takes precedence over environment variables
	no_color_flag :=
		global_flag_present(os.args[1:], "--no-color") ||
		global_flag_present(os.args[1:], "--no-colour")

	// Initialize color system (PRP-09 Phase 1)
	init_colors()

	// Override with --no-color if present (takes precedence over NO_COLOR env)
	if no_color_flag {
		set_plain_output()
	}

	init_shell_globals()
	if msg := dir_override_error(); len(msg) > 0 {
		print_error_simple("%s", msg)
		wayu_exit(EXIT_CONFIG)
	}

	// No arguments → launch TUI (the primary interface)
	if len(os.args) < 2 {
		tui_launch()
		return
	}

	parsed := parse_args(os.args[1:])
	defer if len(parsed.args) > 0 do delete(parsed.args)

	if len(parsed.unknown_flag) > 0 {
		print_error_simple("Unknown option: %s", parsed.unknown_flag)
		fmt.eprintln("Run 'wayu help' (or 'wayu <command> --help') for the accepted options.")
		fmt.eprintln("To pass a value that starts with '-', put it after '--'.")
		wayu_exit(EXIT_USAGE)
	}
	if len(parsed.bad_flag_value) > 0 {
		print_error_simple("%s", parsed.bad_flag_value)
		wayu_exit(EXIT_USAGE)
	}
	if len(parsed.extra_arg) > 0 {
		print_error_simple("Unexpected argument: %s", parsed.extra_arg)
		fmt.eprintln("Run 'wayu <command> --help' for the accepted arguments.")
		wayu_exit(EXIT_USAGE)
	}
	if parsed.json_unsupported {
		print_error_simple(
			"--json is not supported here; it works with: %s",
			json_commands_summary(),
		)
		wayu_exit(EXIT_USAGE)
	}
	if f := parsed.ambiguous_tail_flag; len(f) > 0 {
		long := "--dry-run" if f == "-n" else "--yes"
		fmt.eprintfln(
			"%s⚠ trailing '%s' was kept as part of the value; use '%s' for the flag (put '--' before the value to silence this)%s",
			get_warning(),
			f,
			long,
			RESET,
		)
	}

	// Launch TUI if flag present
	if parsed.tui {
		tui_launch()
		return
	}

	// Component test mode (PRP-13)
	if parsed.component_test {
		run_component_testing(
			parsed.component_name,
			parsed.args,
			parsed.component_snapshot,
			parsed.component_verify,
		)
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
		} else if parsed.action == .FPATH {
			handle_completions_fpath(parsed.args)
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
			template := init_template_arg(parsed.args) // validated before any write
			handle_init_command()
			if len(template) > 0 {
				fmt.println()
				apply_template(template)
			}
		}
	case .CONFIG:
		handle_config_extra_command(parsed.action, parsed.args)
	case .BUILD:
		if parsed.action == .UNKNOWN || len(parsed.args) > 0 {
			print_error_simple(
				"Unknown build target (expected: turbo, eval, profile, clean, help)",
			)
			print_build_help()
			wayu_exit(EXIT_USAGE)
		}
		handle_build_command(parsed.action)
	case .EXPORT:
		// pre/post_export hooks wrap the actions that generate the turbo
		// file (default/turbo); help/eval/check produce no export artifact.
		// post_export only runs if generation didn't exit with an error.
		generates := parsed.action == .TURBO
		if generates do hook_pre_export()
		handle_export_command(parsed.action, parsed.args)
		if generates do hook_post_export()
	case .TOML:
		handle_toml_command(parsed.action)
	case .DOCTOR:
		handle_doctor_command(
			parsed.doctor_fix,
			parsed.doctor_json || wayu.json_output,
			parsed.doctor_profile,
			parsed.doctor_optimize,
		)
	case .TEMPLATE:
		handle_template_command(parsed.action, parsed.args)
	case .HOOKS:
		handle_hooks_command(parsed.action, parsed.args)
	case .FUNCTION:
		handle_function_command(parsed.action, parsed.args)
	case .SCRIPT:
		handle_script_command(parsed.action, parsed.args)
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
	case .SECRETS:
		handle_secrets_command(parsed.action, parsed.args)
	case .OPTIMIZE:
		handle_optimize_command(parsed.action, parsed.args)
	case .UNKNOWN:
		fmt.eprintfln("Unknown command: %s", os.args[1])
		print_help()
		wayu_exit(EXIT_USAGE)
	}
}

// Subdirectories of the data dir `wayu init` creates.
DATA_SUBDIRS :: []string{"functions", "scripts", "bin", "completions", "plugins"}

handle_init_command :: proc() {
	print_header("Initializing Wayu Configuration", "🚀")
	fmt.println()

	// Use shell from wayu (set by detect_shell or --shell flag)
	shell := wayu.shell

	// Validate shell compatibility
	shell_valid, shell_msg := validate_shell_compatibility(shell)
	if !shell_valid {
		print_error_simple("%s", shell_msg)
		wayu_exit(EXIT_CONFIG)
	}

	ext := get_shell_extension(shell)

	print_info("Using shell: %s (config files will use .%s extension)", get_shell_name(shell), ext)
	fmt.println()

	if wayu.dry_run {
		print_init_dry_run(shell, ext)
		return
	}

	config_dir := fmt.aprintf("%s", wayu.config)
	defer delete(config_dir)
	data_dir := fmt.aprintf("%s", wayu.data)
	defer delete(data_dir)

	// Create config directory (~/.config/wayu)
	if !os.exists(config_dir) {
		err := make_directory_all(config_dir) // ~/.config may not exist yet

		if err != nil {
			print_error_simple("Error creating config directory: %v", err)
			wayu_exit(EXIT_CANTCREAT)
		}
		print_success("Created directory: %s", config_dir)
	} else {
		_, _ = wayu_dir_tighten(config_dir)
		print_info("Directory already exists: %s", config_dir)
	}

	// Create data directory (defaults to ~/.local/share/wayu)
	if !os.exists(data_dir) {
		// Create parent directories if needed (may not exist in test envs)
		err := make_directory_all(data_dir)

		if err != nil {
			print_error_simple("Error creating data directory: %v", err)
			wayu_exit(EXIT_CANTCREAT)
		}
		print_success("Created directory: %s", data_dir)
	} else {
		_, _ = wayu_dir_tighten(data_dir)
		print_info("Directory already exists: %s", data_dir)
	}

	// Create subdirectories, all in the data dir: wayu manages functions/
	// (`wayu function`), scripts/ + bin/ (`wayu script`), completions/ and
	// plugins/.
	created_subdirs := 0

	for subdir in DATA_SUBDIRS {
		subdir_path := fmt.aprintf("%s/%s", wayu.data, subdir)
		defer delete(subdir_path)

		if !os.exists(subdir_path) {
			err := make_directory_all(subdir_path)

			if err != nil {
				print_error_simple("Error creating directory %s: %v", subdir, err)
				wayu_exit(EXIT_CANTCREAT)
			}
			print_success("Created directory: %s", subdir_path)
			created_subdirs += 1
		} else {
			_, _ = wayu_dir_tighten(subdir_path)
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

// `wayu init --dry-run`: list what init would create/modify, touch nothing.
print_init_dry_run :: proc(shell: ShellType, ext: string) {
	print_header("DRY RUN - No changes will be made", EMOJI_INFO)
	fmt.println()

	would :: proc(path: string, what: string) {
		if !os.exists(path) {
			fmt.printfln("  Would create %s: %s", what, path)
		}
	}
	would(wayu.config, "directory")
	would(wayu.data, "directory")
	for sub in DATA_SUBDIRS {
		would(fmt.tprintf("%s/%s", wayu.data, sub), "directory")
	}
	would(fmt.tprintf("%s/init.%s", wayu.data, ext), "file")
	for name in ([]string{"tools", "extra"}) {
		would(fmt.tprintf("%s/%s.%s", wayu.config, name, ext), "file")
	}
	would(fmt.tprintf("%s/%s", wayu.config, ALIAS_SOURCES_FILE), "file")
	would(fmt.tprintf("%s/wayu.toml", wayu.config), "file")
	fmt.printfln("  Would regenerate init files in %s", wayu.data)

	rc_file_path := get_rc_file_path(shell)
	defer delete(rc_file_path)
	if data, err := os.read_entire_file(rc_file_path, context.allocator); err == nil {
		defer delete(data)
		if !strings.contains(string(data), "wayu/init") {
			fmt.printfln(
				"  Would offer to append '%s' to %s (backup first)",
				bootstrap_source_line(ext),
				rc_file_path,
			)
		}
	}
	fmt.println()
	fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
}

init_shell_configs :: proc(shell: ShellType, ext: string) {
	created_files := 0

	config_files := []struct {
		name:     string,
		template: proc(_: ShellType) -> string,
		dir:      string, // which base directory to use
	} {
		{"init", get_init_template, wayu.data},
		{"tools", get_tools_template, wayu.config},
		{"extra", get_extra_template, wayu.config},
	}

	for config in config_files {
		config_file := fmt.aprintf("%s/%s.%s", config.dir, config.name, ext)
		defer delete(config_file)

		if !os.exists(config_file) {
			success := init_config_file(config_file, config.template(shell))

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

	// alias-sources.conf is shell-agnostic — create once regardless of shell
	alias_sources_file := fmt.aprintf("%s/%s", wayu.config, ALIAS_SOURCES_FILE)
	defer delete(alias_sources_file)

	if !os.exists(alias_sources_file) {
		success := init_config_file(alias_sources_file, ALIAS_SOURCES_TEMPLATE)
		if success {
			print_success("Created config file: %s", alias_sources_file)
			created_files += 1
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
		toml_scaffold := wayu_toml_scaffold(shell)
		defer delete(toml_scaffold)

		success := init_config_file(toml_file, toml_scaffold)
		if success {
			print_success("Created config file: %s", toml_file)
			created_files += 1
		} else {
			print_error_simple("Failed to create config file: %s", toml_file)
		}
	} else {
		print_info("Config file already exists: %s", toml_file)
	}

	// One summary after every file, counting them all (it said "Created 3"
	// after five "Created" lines, OKAMI-357).
	if created_files > 0 {
		print_success("Created %d config file(s)", created_files)
	} else {
		print_info("All config files already exist")
	}
}

update_shell_rc :: proc(shell: ShellType, ext: string) {
	rc_file_path := get_rc_file_path(shell)
	defer delete(rc_file_path)

	source_line := bootstrap_source_line(ext)

	// Check if RC file exists
	if !os.exists(rc_file_path) {
		fmt.printfln("\nNo %s found. Create one and add the following line:", rc_file_path)
		fmt.printfln("  %s", source_line)
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
	fmt.printfln("\nWayu setup is complete!")

	// Only prompt if stdin is a TTY (interactive mode)
	if !os.is_tty(os.stdin) {
		fmt.printfln("\nTo manually initialize wayu, add this line to your %s:", rc_file_path)
		fmt.printfln("  %s", source_line)
		return
	}

	fmt.printfln("Would you like to add wayu to your %s? [Y/n]: ", rc_file_path)

	input_buf: [10]byte
	n, err := os.read(os.stdin, input_buf[:])
	if err != nil {
		fmt.printfln("\nTo manually initialize wayu, add this line to your %s:", rc_file_path)
		fmt.printfln("  %s", source_line)
		return
	}

	response := strings.trim_space(string(input_buf[:n]))

	if response == "" || response == "y" || response == "Y" {
		// Append to RC file
		new_content := fmt.aprintf("%s\n# Wayu shell configuration\n%s\n", content, source_line)
		defer delete(new_content)

		// The RC file is the user's, not ours: never modify it without a
		// restorable copy.
		if !create_backup_cli(rc_file_path) {
			fmt.printfln("\nTo manually initialize wayu, add this line to your %s:", rc_file_path)
			fmt.printfln("  %s", source_line)
			return
		}

		write_err := write_file_atomic(rc_file_path, transmute([]byte)new_content)
		if write_err != nil {
			fmt.eprintfln("Error: Failed to write to %s", rc_file_path)
			return
		}

		fmt.printfln("✓ Successfully added wayu to %s", rc_file_path)
		fmt.printfln("Run 'source %s' or restart your shell to apply changes", rc_file_path)
	} else {
		fmt.printfln("\nTo manually initialize wayu, add this line to your %s:", rc_file_path)
		fmt.printfln("  %s", source_line)
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
	fmt.println("  wayu init [--template <name>]")
	fmt.println()
	fmt.println("DESCRIPTION:")
	fmt.println("  Sets wayu up for the detected shell (or --shell zsh|bash|fish).")
	fmt.println("  Config dir (~/.config/wayu, files you edit): wayu.toml, extra.<ext>,")
	fmt.println("  tools.<ext>, alias-sources.conf.")
	fmt.println("  Data dir (~/.local/share/wayu, managed by wayu): init.<ext> (source it")
	fmt.println("  from your rc file), the PATH/alias/constant entries, functions/, scripts/,")
	fmt.println("  bin/, completions/, plugins/, and the generated core.<ext>.")
	fmt.println("  Safe to re-run — existing files are preserved.")
	fmt.println()
	fmt.println("  --template <name>  Then apply a template (see 'wayu template list');")
	fmt.println("                     entries you already have are kept.")
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
	// Generated from WAYU_COMMAND_SPECS so help, dispatch and completions
	// list the same commands (OKAMI-282).
	name_width := 0
	for spec in WAYU_COMMAND_SPECS {
		name_width = max(name_width, len(strings.join(spec.names, ", ", context.temp_allocator)))
	}
	for spec in WAYU_COMMAND_SPECS {
		names := strings.join(spec.names, ", ", context.temp_allocator)
		fmt.printf(
			"  %s%s  %s\n",
			names,
			strings.repeat(" ", name_width - len(names), context.temp_allocator),
			spec.desc,
		)
	}
	fmt.println()

	print_section("ACTIONS:", EMOJI_ACTION)
	print_item("", "add", "Add a new entry", EMOJI_ADD)
	print_item("", "remove, rm", "Remove an entry", EMOJI_REMOVE)
	print_item("", "list, ls", "List all entries", EMOJI_LIST)
	print_item("", "help", "Show command-specific help ('wayu <command> help')", EMOJI_INFO)
	fmt.println()

	print_section("FLAGS:", EMOJI_ACTION)
	print_item("", "--dry-run, -n", "Preview changes without modifying files", EMOJI_INFO)
	print_item(
		"",
		"--yes, -y",
		"Confirm destructive operations (path clean/dedup, backup restore/rm, plugin rm, ...)",
		EMOJI_INFO,
	)
	print_item(
		"",
		"--full, -f",
		"Show all entries including external (same as --source all)",
		EMOJI_INFO,
	)
	print_item(
		"",
		"--source <src>",
		"List filter: wayu (default), external, inactive, all",
		EMOJI_INFO,
	)
	print_item(
		"",
		"--shell <sh>",
		"Use zsh, bash or fish instead of the detected shell",
		EMOJI_INFO,
	)
	print_item(
		"",
		"--json",
		fmt.tprintf("Machine-readable output (%s)", json_commands_summary()),
		EMOJI_INFO,
	)
	print_item(
		"",
		"--no-color",
		"No colors (also NO_COLOR=1; off when output is not a terminal)",
		EMOJI_INFO,
	)
	print_item("", "--", "End of flags: everything after is a literal argument", EMOJI_INFO)
	print_item("", "--tui", "Launch interactive Terminal UI mode (same as no args)", EMOJI_INFO)
	print_item("", "--version, -v", "Print the version", EMOJI_INFO)
	print_item("", "--help, -h", "Show help (global or per command)", EMOJI_INFO)
	print_item("", "-c=<component>", "Test TUI component rendering (dev mode)", EMOJI_INFO)
	print_item("", "--snapshot", "Save component output as golden file", EMOJI_INFO)
	print_item("", "--test", "Test component against golden file", EMOJI_INFO)
	fmt.println()

	print_section("COMMAND FLAGS:", EMOJI_ACTION)
	for spec in WAYU_COMMAND_SPECS {
		for f in spec.flags {
			if len(f.desc) == 0 {
				continue
			}
			print_item("", fmt.tprintf("%s %s", spec.names[0], f.flag), f.desc)
		}
	}
	fmt.println()

	print_section("EXAMPLES:", EMOJI_CYCLIST)
	fmt.printf("  wayu path add /usr/local/bin\n")
	fmt.printf("  wayu alias add ll 'ls -la'\n")
	fmt.printf("  wayu constants add MY_VAR value\n")
	fmt.printf("  wayu search api                  # Search across all configs\n")
	fmt.printf("  wayu find faak                   # Acronym: FIREWORKS_AI_API_KEY\n")
	fmt.printf("  wayu f git                       # Short alias for search\n")
	fmt.printf("  wayu completions add jj /path/to/_jj\n")
	fmt.printf("  wayu backup list                 # Show all backups\n")
	fmt.printf("  wayu backup restore entries --yes  # Restore the latest entries.json backup\n")
	fmt.printf("  wayu plugin add syntax-highlighting  # Install plugin\n")
	fmt.printf("  wayu plugin check                # Check plugins for updates\n")
	fmt.printf("  wayu plugin update plugin-name   # Update specific plugin\n")
	fmt.printf("  wayu plugin update --all         # Update all plugins\n")
	fmt.println()
	fmt.printf("  # TOML configuration (declarative mode):\n")
	fmt.printf("  wayu toml validate               # Check wayu.toml syntax\n")
	fmt.printf("  # Edit ~/.config/wayu/wayu.toml  # Edit declarative config\n")
	fmt.println()
	fmt.printf("  # Configuration files:\n")
	fmt.printf("  wayu config edit                 # Edit wayu.toml (declarative)\n")
	fmt.printf("  wayu config extend               # Edit extra.zsh (scripts)\n")
	fmt.printf("  wayu config scan                 # Detect scripts in .zshrc\n")
	fmt.printf("  wayu config                      # Show config help\n")
	fmt.println()
	fmt.printf("  # Diagnostics:\n")
	fmt.printf("  wayu doctor                      # Health check all configs\n")
	fmt.printf("  wayu doctor --fix --yes          # Auto-fix issues\n")
	fmt.println()
	fmt.printf("  # Templates:\n")
	fmt.printf("  wayu template list               # List config presets\n")
	fmt.printf("  wayu template apply developer    # Apply developer preset\n")
	fmt.println()
	fmt.printf("  # Scripts (any language, on PATH):\n")
	fmt.printf("  wayu script new hello --lang python  # Create, edit, build\n")
	fmt.printf("  wayu script import ~/bin/tool    # Adopt an existing script\n")
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
	fmt.printf("  # Flags are global and may appear anywhere, except: after '--', and\n")
	fmt.printf("  # in 'alias add' / 'const add' once the name and first value word were\n")
	fmt.printf("  # given — the rest of the line is the value, flags included (but a\n")
	fmt.printf("  # trailing --dry-run/--yes/--json/--no-color is still a flag).\n")
	fmt.printf("  # Unknown options are an error (exit 64).\n")
	fmt.printf("  wayu alias add gpf git push -f    # value: 'git push -f'\n")
	fmt.printf("  wayu alias add gpf git push -f --dry-run  # preview\n")
	fmt.printf("  wayu alias add g -- -n            # value: '-n'\n")
	fmt.printf("  wayu alias add hd -- helm install --dry-run  # value keeps --dry-run\n")
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
	fmt.printf("  69  Required tool not installed (script interpreter/compiler)\n")
	fmt.printf("  71  TUI could not set up the terminal\n")
	fmt.printf("  73  Cannot create output file\n")
	fmt.printf("  74  I/O error (read/write failure)\n")
	fmt.printf("  77  Permission denied\n")
	fmt.printf("  78  Configuration error\n")
	fmt.printf("  126 secrets run: command not executable\n")
	fmt.printf("  127 secrets run: command not found\n")
	fmt.println()
	fmt.printf(
		"  %sNote:%s Running %swayu%s with no arguments opens the interactive TUI\n",
		BRIGHT_CYAN,
		RESET,
		BOLD,
		RESET,
	)
	fmt.printf(
		"  %sNote:%s CLI mode is fully non-interactive for scripting/automation\n",
		BRIGHT_CYAN,
		RESET,
	)
	fmt.println()
}

// handle_build_command - Compile wayu.toml + entries.json into shell init files
handle_build_command :: proc(action: Action) {
	// Explicit help (unknown targets are rejected by main with exit 64)
	if action == .HELP || action == .UNKNOWN {
		print_build_help()
		return
	}

	turbo_mode := action == .TURBO
	profile_mode := action == .CHECK

	if profile_mode {
		profile_startup_performance()
		return
	}

	if action == .CLEAN {
		clear_evalcache()
		return
	}

	if turbo_mode {
		handle_export_command(.TURBO, {})
		return
	}


	// Standard build - use the optimized code generator
	print_header("Building Shell Configuration", "🔧")
	fmt.println()

	// Check for wayu.toml
	toml_path := fmt.aprintf("%s/wayu.toml", wayu.config)
	defer delete(toml_path)

	if !os.exists(toml_path) {
		print_error_simple("No wayu.toml found at %s. Run 'wayu init' first.", toml_path)
		wayu_exit(EXIT_CONFIG)
	}

	if !validate_tools_args() {
		wayu_exit(EXIT_CONFIG)
	}

	// [paths]/[aliases]/[env] left in wayu.toml are not read: say so on
	// every build, or a hand edit there vanishes silently (OKAMI-333).
	if content, rerr := os.read_entire_file_from_path(toml_path, context.temp_allocator);
	   rerr == nil {
		for msg in toml_moved_table_warnings(string(content)) {
			print_warning("%s", msg)
		}
	}

	// Regenerate the files init.<ext> sources (core/path_sync/lazy/...) for
	// every initialized shell, so hand edits of wayu.toml take effect (open
	// shells pick up [paths] at their next prompt via path_sync).
	// An existing turbo.<ext> is rewritten with core's content along the way.
	// Scripts whose source changed since their last build (`wayu script`),
	// first: a first built script puts <data>/bin on PATH.
	// The live PATH sync prompt hook (WAYU_PROMPT_HOOK=1) runs this build in
	// the foreground: compiling there froze the prompt (a Swift script took
	// ~10 s, OKAMI-308). It hands stale scripts to a background
	// `wayu script build` instead.
	if os.get_env("WAYU_PROMPT_HOOK", context.temp_allocator) == "1" {
		scripts_build_stale_in_background()
	} else {
		config_lock_acquire_or_exit()
		_, failed := scripts_build_stale(quiet = true)
		config_lock_release()
		if failed > 0 {
			print_warning("%d script(s) failed to build (run: wayu script build)", failed)
		}
	}

	// plugins.json is checked once: an invalid file (error printed) keeps
	// every plugins.<ext> as it is, the rest is still regenerated (PATH
	// sync keeps working), and build exits 78 (OKAMI-309).
	// Read → generate → write under the config lock (reentrant, blocking like
	// every other writer): without it a concurrent `alias add` could save
	// entries.json and regenerate between our read and our write, and our
	// stale core.<ext> would overwrite its fresh one. The background script
	// build and zcompile take the lock in their own processes after we
	// release it.
	config_lock_acquire_or_exit()
	plugins_cfg, plugins_ok := read_plugin_config_json()
	cleanup_plugin_config_json(&plugins_cfg)

	generate_optimized_init_all(plugins = plugins_ok)
	config_lock_release()
	fmt.println()
	if !plugins_ok {
		print_error_simple(
			"%s/plugins.json is invalid: plugins.<ext> not regenerated (fix the file, then run: wayu build)",
			wayu.data,
		)
		wayu_exit(EXIT_CONFIG)
	}
}
// Golden file directory
GOLDEN_DIR :: "tests/golden"

// Run component test mode
run_component_testing :: proc(
	component_name: string,
	args: []string,
	snapshot: bool,
	verify: bool,
) {
	// Parse component type
	component_type, ok := parse_component_type(component_name)
	if !ok {
		eprintfln_color("ERROR: Unknown component type: %s", component_name)
		fmt.eprintln("\nAvailable components:")
		fmt.eprintln("  - box")
		fmt.eprintln("  - list-item")
		fmt.eprintln("  - header")
		fmt.eprintln("  - footer")
		fmt.eprintln("  - scroll-indicator")
		fmt.eprintln("  - empty-state")
		wayu_exit(EXIT_USAGE)
	}

	// Parse component arguments
	component_args := parse_component_args(args)
	defer component_args_destroy(&component_args)
	if msg := component_dims_error(component_args); msg != "" {
		eprintfln_color("ERROR: %s", msg)
		wayu_exit(EXIT_USAGE)
	}

	// Render component
	output := render_component(component_type, component_args)
	defer delete(output)

	// Handle different modes
	if snapshot {
		// Save golden file
		success := save_golden(component_name, component_args, output)
		if !success {
			wayu_exit(EXIT_IOERR)
		}
	} else if verify {
		// Test against golden file
		success := compare_golden(component_name, component_args, output)
		if !success {
			wayu_exit(EXIT_GENERAL)
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
	filename := fmt.aprintf("%s/%s_%dx%d.txt", GOLDEN_DIR, component, args.width, args.height)
	defer delete(filename)

	// Write golden file
	write_err := os.write_entire_file(filename, transmute([]byte)output)
	if write_err != nil {
		eprintfln_color("ERROR: Failed to write golden file: %s", filename)
		return false
	}

	fmt.printfln("✓ Saved golden file: %s", filename)
	return true
}

// Compare output against golden file
compare_golden :: proc(component: string, args: ComponentArgs, output: string) -> bool {
	// Build golden file path
	filename := fmt.aprintf("%s/%s_%dx%d.txt", GOLDEN_DIR, component, args.width, args.height)
	defer delete(filename)

	// Check if golden file exists
	if !os.exists(filename) {
		eprintfln_color("ERROR: Golden file not found: %s", filename)
		fmt.eprintfln(
			"Create it with: wayu -c=%s width=%d height=%d --snapshot",
			component,
			args.width,
			args.height,
		)
		return false
	}

	// Read golden file
	golden_data, read_err := os.read_entire_file(filename, context.allocator)
	if read_err != nil {
		eprintfln_color("ERROR: Failed to read golden file: %s", filename)
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
