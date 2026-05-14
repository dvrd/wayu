// config_command.odin - Implementation of `wayu config {extend,edit,scan}`
//
// Extracted from main.odin (2026-04-24) per code review L1. Owns the full
// `wayu config` command family:
//   - `config extend`     → edit extra.<shell> for custom init scripts
//   - `config edit`       → edit wayu.toml (declarative config)
//   - `config scan`       → detect inline scripts in .zshrc
//   - `config scan --fix` → migrate those inline scripts into extra.<shell>
//
// Includes the underlying editor-launcher helpers (edit_extra_config,
// edit_toml_config), the scan/migrate block-detection helper, and the
// family's usage text.

package wayu

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

handle_config_extra_command :: proc(action: Action, args: []string) {
	#partial switch action {
	case .ADD: // extend (extra.zsh)
		extra_file := fmt.aprintf("%s/extra.%s", wayu.config, wayu.shell_ext)
		defer delete(extra_file)
		edit_extra_config(extra_file)
	case .UPDATE: // edit (wayu.toml)
		toml_file := fmt.aprintf("%s/wayu.toml", wayu.config)
		defer delete(toml_file)
		edit_toml_config(toml_file)
	case .CHECK: // scan/detect
		has_fix, has_dry_run, has_yes := extract_scan_flags(args)
		if has_fix {
			scan_and_migrate_scripts(has_dry_run, has_yes)
		} else {
			scan_zshrc_for_scripts()
		}
	case .HELP:
		print_config_usage()
	case:
		// Default: show help
		print_config_usage()
	}
}

// Parse command line args to find --fix flag. `--dry-run` and `--yes` are
// consumed by the global arg parser (DRY_RUN / YES_FLAG globals), so we
// honour those too to preserve `wayu config scan --fix --dry-run` behaviour.
extract_scan_flags :: proc(args: []string) -> (bool, bool, bool) {
	has_fix := false
	has_dry_run := wayu.dry_run   // mirror the global flag
	has_yes := wayu.yes_flag       // mirror the global flag

	for arg in args {
		if arg == "--fix" {
			has_fix = true
		}
		if arg == "--dry-run" || arg == "-n" {
			has_dry_run = true
		}
		if arg == "--yes" || arg == "-y" {
			has_yes = true
		}
	}

	return has_fix, has_dry_run, has_yes
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
# Declarative shell configuration. See https://github.com/kakurega/wayu

[settings]
shell = "zsh"

# [paths]
# odin     = "/Users/you/dev/oss/Odin"
# local_bin = "/usr/local/bin"

# [aliases]
# ll = "ls -la"
# gs = "git status"

# [env]
# EDITOR = "nvim"
# LANG   = "en_US.UTF-8"
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

// Patterns used by both scan procs. Lines that contain any of these substrings
// are treated as the start of an inline-script block that should live in
// extra.<shell> rather than the user's RC file. See `detect_zshrc_script_blocks`.
ZSHRC_SCRIPT_PATTERNS := []string{
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

// Load .zshrc and partition it into contiguous "script blocks" heuristically.
// A block starts at the first non-comment/non-blank line matching one of
// ZSHRC_SCRIPT_PATTERNS and extends until the next blank line or comment line.
//
// Errors are reported via print_error_simple + os.exit — callers do not need
// to handle I/O failure locally. On success, the caller OWNS the returned
// blocks and must free them via cleanup_zshrc_blocks.
detect_zshrc_script_blocks :: proc(zshrc_path: string) -> (blocks: [dynamic][dynamic]string, content_data: []byte) {
	if !os.exists(zshrc_path) {
		print_error_simple(".zshrc not found: %s", zshrc_path)
		os.exit(EXIT_NOINPUT)
	}

	content, read_ok := safe_read_file(zshrc_path)
	if !read_ok {
		print_error_simple("Failed to read .zshrc")
		os.exit(EXIT_IOERR)
	}

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	blocks = make([dynamic][dynamic]string)

	current_block: [dynamic]string
	in_block := false

	flush_block :: proc(blocks: ^[dynamic][dynamic]string, current: ^[dynamic]string) {
		if len(current^) == 0 do return
		block_copy := make([dynamic]string)
		append(&block_copy, ..current^[:])
		append(blocks, block_copy)
		clear(current)
	}

	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") {
			if in_block {
				flush_block(&blocks, &current_block)
				in_block = false
			}
			continue
		}

		if !in_block {
			for pattern in ZSHRC_SCRIPT_PATTERNS {
				if strings.contains(trimmed, pattern) {
					in_block = true
					append(&current_block, line)
					break
				}
			}
		} else {
			append(&current_block, line)
		}
	}

	// Flush trailing block if the file ended mid-block.
	if in_block {
		flush_block(&blocks, &current_block)
	}
	delete(current_block)

	content_data = content
	return
}

// Free the result of detect_zshrc_script_blocks. Safe to call regardless of
// whether the block slice ended up empty.
cleanup_zshrc_blocks :: proc(blocks: [dynamic][dynamic]string, content: []byte) {
	for block in blocks {
		delete(block)
	}
	delete(blocks)
	delete(content)
}

// Scan .zshrc for inline scripts that should move to extra.zsh
scan_zshrc_for_scripts :: proc() {
	zshrc_file := fmt.aprintf("%s/.zshrc", os.get_env("HOME", context.temp_allocator))
	defer delete(zshrc_file)

	detected_blocks, content := detect_zshrc_script_blocks(zshrc_file)
	defer cleanup_zshrc_blocks(detected_blocks, content)

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
	fmt.printfln("Or run %swayu config scan --fix%s to auto-migrate", get_primary(), RESET)
}

// Scan and optionally migrate scripts from .zshrc to extra.zsh
scan_and_migrate_scripts :: proc(dry_run: bool, force_yes: bool) {
	zshrc_file := fmt.aprintf("%s/.zshrc", os.get_env("HOME", context.temp_allocator))
	defer delete(zshrc_file)

	detected_blocks, content := detect_zshrc_script_blocks(zshrc_file)
	defer cleanup_zshrc_blocks(detected_blocks, content)

	if len(detected_blocks) == 0 {
		print_success("No inline scripts detected in .zshrc")
		return
	}

	// Show what would be imported
	print_header("Detected Inline Scripts for Import", "🔍")
	fmt.printfln("Found %d potential script blocks in .zshrc:", len(detected_blocks))
	fmt.println()

	for block, i in detected_blocks {
		fmt.printfln("%sBlock %d:%s", get_primary(), i + 1, RESET)
		for line in block {
			fmt.printfln("  %s", line)
		}
		fmt.println()
	}

	// Check extra.zsh
	extra_file := fmt.aprintf("%s/extra.%s", wayu.config, wayu.shell_ext)
	defer delete(extra_file)

	if dry_run {
		print_info("Dry-run mode: would append %d blocks to extra.%s", len(detected_blocks), wayu.shell_ext)
		fmt.println()
		fmt.printfln("Run %swayu config scan --fix --yes%s to actually migrate", get_primary(), RESET)
		return
	}

	if !force_yes {
		fmt.printfln("This will append %d blocks to %s", len(detected_blocks), extra_file)
		fmt.println("Pass --yes to confirm")
		os.exit(EXIT_USAGE)
	}

	// Create backup first
	backup_path, ok := create_backup(extra_file)
	defer if ok do delete(backup_path)

	// Append to extra.zsh
	extra_exists := os.exists(extra_file)

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	// Read existing content if file exists
	if extra_exists {
		existing, read_ok := safe_read_file(extra_file)
		if read_ok {
			strings.write_string(&builder, string(existing))
			delete(existing)
			if !strings.has_suffix(string(existing), "\n") {
				strings.write_string(&builder, "\n")
			}
		}
	}

	// Append header
	strings.write_string(&builder, "\n# === Scripts imported by 'wayu config scan --fix' ===\n")
	strings.write_string(&builder, fmt.aprintf("# Imported on: %v\n", time.now()))
	strings.write_string(&builder, "\n")

	// Append all blocks
	for block in detected_blocks {
		for line in block {
			strings.write_string(&builder, line)
			strings.write_string(&builder, "\n")
		}
		strings.write_string(&builder, "\n")
	}

	// Write file
	migration_content := strings.to_string(builder)
	write_ok := safe_write_file(extra_file, transmute([]byte)(migration_content))

	if write_ok {
		print_success("Migrated %d blocks to %s", len(detected_blocks), extra_file)
		print_info("Original scripts remain in .zshrc - review extra.%s and remove them manually", wayu.shell_ext)
	} else {
		print_error_simple("Failed to write %s", extra_file)
		os.exit(EXIT_IOERR)
	}
}

print_config_usage :: proc() {
	fmt.println()
	fmt.printfln("%swayu config - Manage configuration files%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.printfln("  wayu config              Default: Edit wayu.toml (declarative config)")
	fmt.printfln("  wayu config extend       Edit extra.zsh (custom shell scripts)")
	fmt.printfln("  wayu config edit         Edit wayu.toml (declarative config)")
	fmt.printfln("  wayu config scan         Scan .zshrc for inline scripts")
	fmt.println()
	fmt.printfln("%sAVAILABLE ACTIONS:%s", get_primary(), RESET)
	fmt.println("  extend                   Add/edit extra.zsh file")
	fmt.println("  edit                     Edit wayu.toml file")
	fmt.println("  scan                     Detect scripts in .zshrc for migration")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  wayu.toml: Declarative configuration (PATH, aliases, constants)")
	fmt.println("  extra.zsh: Shell scripts that run at end of initialization")
	fmt.println("             Use for conda init, tool evals, custom functions, etc.")
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  # Edit declarative config (default)")
	fmt.println("  wayu config")
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

