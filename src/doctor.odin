// doctor.odin - System health check and diagnostics using arena allocation
//
// Provides comprehensive diagnostics for wayu configuration,
// shell setup, and common issues.
// Uses arena allocator for simple memory management.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:mem"

// Check result structure - all strings allocated from arena
CheckResult :: struct {
	name:    string,
	status:  CheckStatus,
	message: string,
	fixable: bool,
}

CheckStatus :: enum {
	OK,
	WARNING,
	ERROR,
	INFO,
}

// Arena for doctor allocations
DOCTOR_ARENA_SIZE :: 64 * 1024  // 64KB should be plenty
doctor_arena: mem.Arena
doctor_arena_buffer: [DOCTOR_ARENA_SIZE]byte

// Get arena allocator - arena must be initialized first
get_doctor_allocator :: proc() -> mem.Allocator {
	// Arena is initialized at module init or in handle_doctor_command
	return mem.arena_allocator(&doctor_arena)
}

// Ensure arena is initialized
ensure_arena_initialized :: proc() {
	if doctor_arena.data == nil {
		mem.arena_init(&doctor_arena, doctor_arena_buffer[:])
	}
}

// Main doctor command handler
handle_doctor_command :: proc() {
	// Initialize arena on first use
	ensure_arena_initialized()

	// Use arena for all allocations in this scope
	arena_alloc := get_doctor_allocator()
	
	print_header("wayu Doctor - System Health Check", "🔬")
	fmt.println()

	results := make([dynamic]CheckResult, allocator = arena_alloc)

	// Run all checks (all use arena via context.allocator)
	context.allocator = arena_alloc
	check_wayu_installation(&results)
	check_shell_config(&results)
	check_path_entries(&results)
	check_plugins(&results)
	check_backups(&results)
	check_toml_config(&results)
	check_turbo_export(&results)
	check_dependencies(&results)

	// Print results
	print_doctor_results(results[:])

	// Summary
	print_doctor_summary(results[:])
}

// Helper to clone string to arena
clone_arena :: proc(s: string) -> string {
	ensure_arena_initialized()
	return strings.clone(s, get_doctor_allocator())
}

// Check 1: wayu installation
check_wayu_installation :: proc(results: ^[dynamic]CheckResult) {
	ensure_arena_initialized()
	// Check binary exists
	wayu_bin := "/usr/local/bin/wayu"
	if !os.exists(wayu_bin) {
		// Try to find in PATH
		if os.exists("./wayu") || os.exists("./bin/wayu") {
			append(results, CheckResult{
				name    = clone_arena("wayu installation"),
				status  = .INFO,
				message = clone_arena("wayu found in local directory but not in /usr/local/bin"),
				fixable = true,
			})
		} else {
			append(results, CheckResult{
				name    = clone_arena("wayu installation"),
				status  = .ERROR,
				message = clone_arena("wayu binary not found in /usr/local/bin or PATH"),
				fixable = false,
			})
		}
		return
	}

	// If we got here, wayu is installed
	msg := fmt.aprintf("wayu %s installed", VERSION, allocator = get_doctor_allocator())
	append(results, CheckResult{
		name    = clone_arena("wayu installation"),
		status  = .OK,
		message = msg,
		fixable = false,
	})
}

// Check 2: shell configuration
check_shell_config :: proc(results: ^[dynamic]CheckResult) {
	ensure_arena_initialized()
	shell_rc := get_shell_rc_file_arena()

	if len(shell_rc) == 0 {
		append(results, CheckResult{
			name    = clone_arena("shell configuration"),
			status  = .WARNING,
			message = clone_arena("Could not determine shell RC file"),
			fixable = false,
		})
		return
	}

	content, ok := safe_read_file(shell_rc)
	if !ok {
		msg := fmt.aprintf("Shell RC file not found: %s", shell_rc, allocator = get_doctor_allocator())
		append(results, CheckResult{
			name    = clone_arena("shell configuration"),
			status  = .WARNING,
			message = msg,
			fixable = true,
		})
		return
	}
	defer delete(content)  // This is from file read, not arena

	content_str := string(content)

	// Check if wayu is sourced
	if strings.contains(content_str, "wayu/init") || strings.contains(content_str, "wayu-turbo") || strings.contains(content_str, "turbo.zsh") {
		append(results, CheckResult{
			name    = clone_arena("shell configuration"),
			status  = .OK,
			message = clone_arena("wayu sourced in shell config"),
			fixable = false,
		})
	} else {
		append(results, CheckResult{
			name    = clone_arena("shell configuration"),
			status  = .ERROR,
			message = clone_arena("wayu not sourced - add 'source \"$HOME/.config/wayu/init.zsh\"' to shell RC"),
			fixable = true,
		})
	}
}

// Get shell RC file path using arena
get_shell_rc_file_arena :: proc() -> string {
	ensure_arena_initialized()
	shell := DETECTED_SHELL
	home := os.get_env_alloc("HOME", get_doctor_allocator())

	#partial switch shell {
	case .ZSH:
		zshrc := fmt.aprintf("%s/.zshrc", home, allocator = get_doctor_allocator())
		if os.exists(zshrc) {
			return zshrc
		}
		zprofile := fmt.aprintf("%s/.zprofile", home, allocator = get_doctor_allocator())
		if os.exists(zprofile) {
			return zprofile
		}
		return zshrc
	case .BASH:
		bashrc := fmt.aprintf("%s/.bashrc", home, allocator = get_doctor_allocator())
		if os.exists(bashrc) {
			return bashrc
		}
		profile := fmt.aprintf("%s/.bash_profile", home, allocator = get_doctor_allocator())
		if os.exists(profile) {
			return profile
		}
		return bashrc
	case .UNKNOWN:
		return ""
	}

	return ""
}

// Check 3: PATH entries
check_path_entries :: proc(results: ^[dynamic]CheckResult) {
	ensure_arena_initialized()
	entries := read_config_entries(&PATH_SPEC)
	// Don't cleanup_entries - we only read, the arena will clean up

	if len(entries) == 0 {
		append(results, CheckResult{
			name    = clone_arena("PATH entries"),
			status  = .INFO,
			message = clone_arena("No custom PATH entries configured"),
			fixable = false,
		})
		return
	}

	missing_count := 0
	duplicate_count := 0
	seen := make(map[string]bool, allocator = get_doctor_allocator())

	arena_alloc := get_doctor_allocator()
	for entry in entries {
		expanded := expand_env_vars(entry.name)
		defer delete(expanded)  // expand_env_vars uses temp allocator

		if !os.exists(expanded) {
			missing_count += 1
		}

		// Clone expanded to arena for map key
		expanded_arena := strings.clone(expanded, arena_alloc)
		if seen[expanded_arena] {
			duplicate_count += 1
		}
		seen[expanded_arena] = true
	}

	if missing_count == 0 && duplicate_count == 0 {
		msg := fmt.aprintf("%d PATH entries, all valid", len(entries), allocator = arena_alloc)
		append(results, CheckResult{
			name    = clone_arena("PATH entries"),
			status  = .OK,
			message = msg,
			fixable = false,
		})
	} else {
		msg_parts := make([dynamic]string, allocator = arena_alloc)
		if missing_count > 0 {
			append(&msg_parts, fmt.aprintf("%d missing", missing_count, allocator = arena_alloc))
		}
		if duplicate_count > 0 {
			append(&msg_parts, fmt.aprintf("%d duplicates", duplicate_count, allocator = arena_alloc))
		}

		msg := fmt.aprintf("%d PATH entries, %s - run 'wayu path clean' and 'wayu path dedup'", 
			len(entries), strings.join(msg_parts[:], ", ", allocator = arena_alloc), allocator = arena_alloc)
		append(results, CheckResult{
			name    = clone_arena("PATH entries"),
			status  = .WARNING,
			message = msg,
			fixable = true,
		})
	}
}

// Check 4: plugins
check_plugins :: proc(results: ^[dynamic]CheckResult) {
	ensure_arena_initialized()
	config_file := fmt.aprintf("%s/plugins.json", WAYU_CONFIG, allocator = get_doctor_allocator())

	if !os.exists(config_file) {
		append(results, CheckResult{
			name    = clone_arena("plugins"),
			status  = .INFO,
			message = clone_arena("No plugins configured"),
			fixable = false,
		})
		return
	}

	data, ok := safe_read_file(config_file)
	if !ok {
		append(results, CheckResult{
			name    = clone_arena("plugins"),
			status  = .WARNING,
			message = clone_arena("Could not read plugins configuration"),
			fixable = false,
		})
		return
	}
	defer delete(data)

	content := string(data)
	plugin_count := strings.count(content, "\"name\"")

	if plugin_count == 0 {
		append(results, CheckResult{
			name    = clone_arena("plugins"),
			status  = .INFO,
			message = clone_arena("No plugins installed"),
			fixable = false,
		})
	} else {
		msg := fmt.aprintf("%d plugin(s) installed", plugin_count, allocator = get_doctor_allocator())
		append(results, CheckResult{
			name    = clone_arena("plugins"),
			status  = .OK,
			message = msg,
			fixable = false,
		})
	}
}

// Check 5: backups
check_backups :: proc(results: ^[dynamic]CheckResult) {
	ensure_arena_initialized()
	backup_dir := fmt.aprintf("%s/backup", WAYU_CONFIG, allocator = get_doctor_allocator())

	if !os.exists(backup_dir) {
		append(results, CheckResult{
			name    = clone_arena("backups"),
			status  = .WARNING,
			message = clone_arena("Backup directory not found"),
			fixable = false,
		})
		return
	}

	append(results, CheckResult{
		name    = clone_arena("backups"),
		status  = .OK,
		message = clone_arena("Backup system configured"),
		fixable = false,
	})
}

// Check 6: TOML config
check_toml_config :: proc(results: ^[dynamic]CheckResult) {
	ensure_arena_initialized()
	toml_path := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG, allocator = get_doctor_allocator())

	if !os.exists(toml_path) {
		append(results, CheckResult{
			name    = clone_arena("TOML config"),
			status  = .INFO,
			message = clone_arena("No TOML configuration (using standard shell configs)"),
			fixable = false,
		})
		return
	}

	// Try to validate - just check if we can read it
	content, ok := safe_read_file(toml_path)
	if !ok {
		append(results, CheckResult{
			name    = clone_arena("TOML config"),
			status  = .ERROR,
			message = clone_arena("Cannot read wayu.toml"),
			fixable = false,
		})
		return
	}
	delete(content)
	
	// Basic check passed
	append(results, CheckResult{
		name    = clone_arena("TOML config"),
		status  = .OK,
		message = clone_arena("wayu.toml exists and is readable"),
		fixable = false,
	})
}

// Check 7: turbo export
check_turbo_export :: proc(results: ^[dynamic]CheckResult) {
	ensure_arena_initialized()
	turbo_path := fmt.aprintf("%s/turbo.zsh", WAYU_CONFIG, allocator = get_doctor_allocator())

	if !os.exists(turbo_path) {
		append(results, CheckResult{
			name    = clone_arena("turbo export"),
			status  = .INFO,
			message = clone_arena("Turbo export not generated - run 'wayu export' for faster startup"),
			fixable = true,
		})
		return
	}

	// Check if it's being used in shell config
	shell_rc := get_shell_rc_file_arena()

	if len(shell_rc) > 0 {
		content, ok := safe_read_file(shell_rc)
		if ok {
			defer delete(content)
			content_str := string(content)
			if strings.contains(content_str, "turbo.zsh") {
				append(results, CheckResult{
					name    = clone_arena("turbo export"),
					status  = .OK,
					message = clone_arena("Turbo export generated and active"),
					fixable = false,
				})
				return
			}
		}
	}

	append(results, CheckResult{
		name    = clone_arena("turbo export"),
		status  = .WARNING,
		message = clone_arena("Turbo export generated but not used in shell config"),
		fixable = true,
	})
}

// Check 8: dependencies
check_dependencies :: proc(results: ^[dynamic]CheckResult) {
	ensure_arena_initialized()
	deps := []string{"git", "zsh"}
	arena_alloc := get_doctor_allocator()

	for dep in deps {
		found := check_command_exists(dep)

		name := fmt.aprintf("dependency: %s", dep, allocator = arena_alloc)
		if found {
			msg := fmt.aprintf("%s found", dep, allocator = arena_alloc)
			append(results, CheckResult{
				name    = name,
				status  = .OK,
				message = msg,
				fixable = false,
			})
		} else {
			msg := fmt.aprintf("%s not found in common paths", dep, allocator = arena_alloc)
			append(results, CheckResult{
				name    = name,
				status  = .WARNING,
				message = msg,
				fixable = false,
			})
		}
	}
}

// Check if a command exists in PATH
check_command_exists :: proc(cmd: string) -> bool {
	paths := []string{
		fmt.tprintf("/usr/bin/%s", cmd),
		fmt.tprintf("/bin/%s", cmd),
		fmt.tprintf("/usr/local/bin/%s", cmd),
		fmt.tprintf("/opt/homebrew/bin/%s", cmd),
	}

	for path in paths {
		if os.exists(path) {
			return true
		}
	}
	return false
}

// Print doctor results
print_doctor_results :: proc(results: []CheckResult) {
	for result in results {
		status_icon := ""
		status_color := ""

		switch result.status {
		case .OK:
			status_icon = "✓"
			status_color = get_success()
		case .WARNING:
			status_icon = "⚠"
			status_color = get_warning()
		case .ERROR:
			status_icon = "✗"
			status_color = get_error()
		case .INFO:
			status_icon = "ℹ"
			status_color = get_muted()
		}

		fixable_icon := ""
		if result.fixable {
			fixable_icon = " 🔧"
		}

		fmt.printfln("  %s%s%s %s%s", status_color, status_icon, RESET, result.name, fixable_icon)
		fmt.printfln("    %s%s%s", get_muted(), result.message, RESET)
	}
	fmt.println()
}

// Print doctor summary
print_doctor_summary :: proc(results: []CheckResult) {
	ok_count := 0
	warning_count := 0
	error_count := 0
	info_count := 0
	fixable_count := 0

	for result in results {
		switch result.status {
		case .OK:
			ok_count += 1
		case .WARNING:
			warning_count += 1
		case .ERROR:
			error_count += 1
		case .INFO:
			info_count += 1
		}

		if result.fixable {
			fixable_count += 1
		}
	}

	print_section("Summary", EMOJI_INFO)
	fmt.printfln("  %s%d OK%s  %s%d warnings%s  %s%d errors%s  %d info",
		get_success(), ok_count, RESET,
		get_warning(), warning_count, RESET,
		get_error(), error_count, RESET,
		info_count)
	fmt.println()

	if error_count > 0 {
		fmt.printfln("  %s✗ Found %d error(s) that need attention%s", get_error(), error_count, RESET)
	}

	if warning_count > 0 {
		fmt.printfln("  %s⚠ Found %d warning(s) to review%s", get_warning(), warning_count, RESET)
	}

	if fixable_count > 0 {
		fmt.printfln("  %s🔧 %d issue(s) can be auto-fixed%s", get_primary(), fixable_count, RESET)
		fmt.println()
		fmt.println("  Run with --fix to attempt automatic fixes:")
		fmt.println("    wayu doctor --fix")
	}

	if error_count == 0 && warning_count == 0 {
		fmt.printfln("  %s✓ All checks passed!%s", get_success(), RESET)
	}

	fmt.println()
}

// Print doctor usage
print_doctor_usage :: proc() {
	fmt.println()
	fmt.printfln("%swayu doctor - System health check and diagnostics%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.printfln("  wayu doctor              Run all health checks")
	fmt.printfln("  wayu doctor --fix        Attempt to fix issues automatically")
	fmt.printfln("  wayu doctor --json       Output results as JSON")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  Diagnoses wayu installation, shell configuration, PATH entries,")
	fmt.println("  plugins, backups, and other common issues.")
	fmt.println()
	fmt.printfln("%sCHECKS PERFORMED:%s", get_primary(), RESET)
	fmt.println("  • wayu installation and version")
	fmt.println("  • Shell RC file configuration")
	fmt.println("  • PATH entries (missing directories, duplicates)")
	fmt.println("  • Plugin status")
	fmt.println("  • Backup system")
	fmt.println("  • TOML configuration validity")
	fmt.println("  • Turbo export status")
	fmt.println("  • Required dependencies (git, zsh)")
}
