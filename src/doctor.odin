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
import "core:path/filepath"

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
handle_doctor_command :: proc(fix_mode: bool, json_output: bool) {
	// Initialize arena on first use
	ensure_arena_initialized()

	// Use arena for all allocations in this scope
	arena_alloc := get_doctor_allocator()
	
	// Run all checks (first pass)
	results := make([dynamic]CheckResult, allocator = arena_alloc)
	context.allocator = arena_alloc
	run_all_checks(&results)

	// JSON output mode
	if json_output {
		print_doctor_json(results[:])
		return
	}

	// Normal output - first pass
	print_header("wayu Doctor - System Health Check", "🔬")
	fmt.println()
	print_doctor_results(results[:])

	// Fix mode: attempt to fix issues, then re-run checks
	fix_attempts: []FixAttempt
	if fix_mode {
		fmt.println()
		print_section("Auto-fix", "🔧")
		fix_attempts = attempt_auto_fixes(results[:], arena_alloc)
		fmt.println()
		
		// Re-run checks to show updated status
		print_section("Re-checking", "🔄")
		fmt.println()
		
		// Clear previous results and run again
		clear(&results)
		run_all_checks(&results)
		print_doctor_results(results[:])
	}

	// Summary with current results and fix attempts
	print_doctor_summary(results[:], fix_mode, fix_attempts)
}

// Run all diagnostic checks
run_all_checks :: proc(results: ^[dynamic]CheckResult) {
	check_wayu_installation(results)
	check_shell_config(results)
	check_path_entries(results)
	check_plugins(results)
	check_backups(results)
	check_toml_config(results)
	check_turbo_export(results)
	check_dependencies(results)
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
print_doctor_summary :: proc(results: []CheckResult, fix_mode: bool = false, fix_attempts: []FixAttempt = {}) {
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

	// Proper singular/plural formatting
	warning_word := "warning"
	if warning_count != 1 {
		warning_word = "warnings"
	}
	error_word := "error"
	if error_count != 1 {
		error_word = "errors"
	}
	info_word := "info"
	if info_count != 1 {
		info_word = "infos"
	}

	fmt.printfln("  %s%d OK%s  %s%d %s%s  %s%d %s%s  %d %s",
		get_success(), ok_count, RESET,
		get_warning(), warning_count, warning_word, RESET,
		get_error(), error_count, error_word, RESET,
		info_count, info_word)
	fmt.println()

	if error_count > 0 {
		error_label := "error"
		if error_count != 1 {
			error_label = "errors"
		}
		fmt.printfln("  %s✗ Found %d %s that need attention%s", get_error(), error_count, error_label, RESET)
	}

	if warning_count > 0 {
		warning_label := "warning"
		if warning_count != 1 {
			warning_label = "warnings"
		}
		fmt.printfln("  %s⚠ Found %d %s to review%s", get_warning(), warning_count, warning_label, RESET)
	}

	if fixable_count > 0 && !fix_mode {
		fixable_label := "issue"
		if fixable_count != 1 {
			fixable_label = "issues"
		}
		fmt.printfln("  %s🔧 %d %s can be auto-fixed%s", get_primary(), fixable_count, fixable_label, RESET)
		fmt.println()
		fmt.println("  Run with --fix to attempt automatic fixes:")
		fmt.println("    wayu doctor --fix")
	}

	// Show fix results after attempting fixes
	if fix_mode && len(fix_attempts) > 0 {
		success_count := 0
		failed_count := 0
		for attempt in fix_attempts {
			if attempt.success {
				success_count += 1
			} else {
				failed_count += 1
			}
		}
		
		if failed_count > 0 {
			fail_word := "fix"
			if failed_count != 1 {
				fail_word = "fixes"
			}
			fmt.printfln("  %s⚠ %d %s failed and require manual action%s", 
				get_warning(), failed_count, fail_word, RESET)
			fmt.println()
			fmt.println("  Manual fixes needed:")
			for attempt in fix_attempts {
				if !attempt.success {
					fmt.printfln("    • %s: %s", attempt.name, attempt.message)
				}
			}
		}
		
		if success_count > 0 {
			success_word := "fix"
			if success_count != 1 {
				success_word = "fixes"
			}
			fmt.printfln("  %s✓ %d %s applied successfully%s", 
				get_success(), success_count, success_word, RESET)
		}
	}

	if error_count == 0 && warning_count == 0 {
		fmt.printfln("  %s✓ All checks passed!%s", get_success(), RESET)
	}

	fmt.println()
}

// Fix attempt result
FixAttempt :: struct {
	name:    string,
	success: bool,
	message: string,
}

// Attempt to auto-fix issues - returns list of fix attempts
attempt_auto_fixes :: proc(results: []CheckResult, arena_alloc: mem.Allocator) -> []FixAttempt {
	attempts := make([dynamic]FixAttempt, allocator = arena_alloc)
	
	for result in results {
		if !result.fixable {
			continue
		}

		switch result.name {
		case "wayu installation":
			fmt.printfln("  %s• Installing wayu to /usr/local/bin...%s", get_primary(), RESET)
			
			if install_wayu_binary() {
				fmt.printfln("    %s✓ Installed successfully%s", get_success(), RESET)
				append(&attempts, FixAttempt{
					name    = result.name,
					success = true,
					message = "Installed to /usr/local/bin",
				})
			} else {
				fmt.printfln("    %s✗ Installation failed (may need sudo)%s", get_error(), RESET)
				fmt.printfln("    Run: sudo ./build_it install")
				append(&attempts, FixAttempt{
					name    = result.name,
					success = false,
					message = "Requires manual fix: sudo ./build_it install",
				})
			}

		case "PATH entries":
			fmt.printfln("  %s• Cleaning PATH entries...%s", get_primary(), RESET)
			
			entries := read_config_entries(&PATH_SPEC)
			defer cleanup_entries(&entries)
			
			removed_missing := 0
			for entry in entries {
				expanded := expand_env_vars(entry.name)
				defer delete(expanded)
				if !os.exists(expanded) {
					ok, _ := remove_config_entry(&PATH_SPEC, entry.name)
					if ok {
						removed_missing += 1
					}
				}
			}
			
			fmt.printfln("    %s✓ Removed %d missing PATH entries%s", 
				get_success(), removed_missing, RESET)
			
			append(&attempts, FixAttempt{
				name    = result.name,
				success = true,
				message = fmt.aprintf("Removed %d missing entries", removed_missing, allocator = arena_alloc),
			})
			
			if removed_missing > 0 {
				fmt.printfln("    %sRun 'wayu path dedup --yes' to remove duplicates%s", 
					get_muted(), RESET)
			}

		case "turbo export":
			fmt.printfln("  %s• Checking turbo export...%s", get_primary(), RESET)
			// Check if we need to generate or if shell config needs updating
			if strings.contains(result.message, "not generated") {
				handle_export_command(.LIST, {})
				fmt.printfln("    %s✓ Turbo export generated%s", get_success(), RESET)
				append(&attempts, FixAttempt{
					name    = result.name,
					success = true,
					message = "Turbo export generated",
				})
			} else {
				fmt.printfln("    %s✗ Shell config needs manual update%s", get_error(), RESET)
				
				// Get shell config file name
				shell_rc := "~/.zshrc"
				if DETECTED_SHELL == .BASH {
					shell_rc = "~/.bashrc"
				}
				
				fmt.printfln("    %s1. Edit your %s and change:%s", get_muted(), shell_rc, RESET)
				fmt.printfln("       FROM: source \"$HOME/.config/wayu/init.zsh\"")
				fmt.printfln("       TO:   source \"$HOME/.config/wayu/turbo.zsh\"")
				fmt.printfln("    %s2. Reload your shell: source %s%s", get_muted(), shell_rc, RESET)
				
				append(&attempts, FixAttempt{
					name    = result.name,
					success = false,
					message = fmt.aprintf("Edit %s: change init.zsh to turbo.zsh", shell_rc, allocator = arena_alloc),
				})
			}

		case:
			fmt.printfln("  %s• Cannot auto-fix: %s%s", get_muted(), result.name, RESET)
		}
	}
	
	return attempts[:]
}

// Import libc for system call
import "core:c/libc"

// Install wayu binary to /usr/local/bin using symlink
install_wayu_binary :: proc() -> bool {
	// Find current wayu binary
	current_path := ""
	if os.exists("./wayu") {
		current_path = "./wayu"
	} else if os.exists("./bin/wayu") {
		current_path = "./bin/wayu"
	} else {
		return false
	}

	// Get absolute path of current binary using arena allocator
	arena_alloc := get_doctor_allocator()
	abs_path, abs_err := filepath.abs(current_path, arena_alloc)
	if abs_err != nil {
		return false
	}
	
	dest_path := "/usr/local/bin/wayu"
	
	// Remove existing file/symlink if exists (best effort, ignore errors)
	os.remove(dest_path)
	
	// Create symlink using system ln -sf command
	// Using -f to force overwrite if exists
	cmd := fmt.tprintf("ln -sf \"%s\" \"%s\"", abs_path, dest_path)
	cmd_cstr := strings.clone_to_cstring(cmd, context.temp_allocator)
	result := libc.system(cmd_cstr)
	
	return result == 0
}

import os2 "core:os"

// Print doctor results as JSON
print_doctor_json :: proc(results: []CheckResult) {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	strings.write_string(&builder, "{\n")
	strings.write_string(&builder, `  "checks": [`)
	strings.write_string(&builder, "\n")
	
	for result, i in results {
		status_str := ""
		switch result.status {
		case .OK:      status_str = "ok"
		case .WARNING: status_str = "warning"
		case .ERROR:   status_str = "error"
		case .INFO:    status_str = "info"
		}
		
		comma := ","
		if i == len(results) - 1 {
			comma = ""
		}
		
		// Build the JSON object manually
		strings.write_string(&builder, `    {`)
		fmt.sbprintf(&builder, `"name": "%s", "status": "%s", "message": "`, result.name, status_str)
		
		// Escape the message content
		for c in result.message {
			if c == '"' {
				strings.write_string(&builder, "\\\"")
			} else if c == '\\' {
				strings.write_string(&builder, "\\\\")
			} else {
				strings.write_rune(&builder, c)
			}
		}
		
		fmt.sbprintf(&builder, `", "fixable": %v}`, result.fixable)
		strings.write_string(&builder, comma)
		strings.write_string(&builder, "\n")
	}
	
	strings.write_string(&builder, "  ],\n")
	
	// Count summary
	ok_count := 0
	warning_count := 0
	error_count := 0
	info_count := 0
	fixable_count := 0
	
	for result in results {
		switch result.status {
		case .OK:      ok_count += 1
		case .WARNING: warning_count += 1
		case .ERROR:   error_count += 1
		case .INFO:    info_count += 1
		}
		if result.fixable {
			fixable_count += 1
		}
	}
	
	strings.write_string(&builder, `  "summary": {`)
	fmt.sbprintf(&builder, `"ok": %d, "warnings": %d, "errors": %d, "info": %d, "fixable": %d`, 
		ok_count, warning_count, error_count, info_count, fixable_count)
	strings.write_string(&builder, "}\n")
	strings.write_string(&builder, "}\n")
	
	// Output the built string
	fmt.print(strings.to_string(builder))
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
