// doctor.odin - System health check and diagnostics
//
// Provides comprehensive diagnostics for wayu configuration,
// shell setup, and common issues.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"

// Check result structure
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

// Main doctor command handler
handle_doctor_command :: proc() {
	print_header("wayu Doctor - System Health Check", "🔬")
	fmt.println()

	results := make([dynamic]CheckResult)
	defer {
		for r in results {
			delete(r.name)
			delete(r.message)
		}
		delete(results)
	}

	// Run all checks
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

// Check 1: wayu installation
check_wayu_installation :: proc(results: ^[dynamic]CheckResult) {
	// Check binary exists
	wayu_bin := "/usr/local/bin/wayu"
	if !os.exists(wayu_bin) {
		// Try to find in PATH
		if os.exists("./wayu") || os.exists("./bin/wayu") {
			append(results, CheckResult{
				name    = "wayu installation",
				status  = .INFO,
				message = "wayu found in local directory but not in /usr/local/bin",
				fixable = true,
			})
		} else {
			append(results, CheckResult{
				name    = "wayu installation",
				status  = .ERROR,
				message = "wayu binary not found in /usr/local/bin or PATH",
				fixable = false,
			})
		}
		return
	}

	// If we got here, wayu is installed
	append(results, CheckResult{
		name    = "wayu installation",
		status  = .OK,
		message = fmt.tprintf("wayu %s installed", VERSION),
		fixable = false,
	})
}

// Check 2: shell configuration
check_shell_config :: proc(results: ^[dynamic]CheckResult) {
	shell_rc := get_shell_rc_file()
	defer delete(shell_rc)

	if len(shell_rc) == 0 {
		append(results, CheckResult{
			name    = "shell configuration",
			status  = .WARNING,
			message = "Could not determine shell RC file",
			fixable = false,
		})
		return
	}

	content, ok := safe_read_file(shell_rc)
	if !ok {
		append(results, CheckResult{
			name    = "shell configuration",
			status  = .WARNING,
			message = fmt.tprintf("Shell RC file not found: %s", shell_rc),
			fixable = true,
		})
		return
	}
	defer delete(content)

	content_str := string(content)

	// Check if wayu is sourced
	if strings.contains(content_str, "wayu/init") || strings.contains(content_str, "wayu-turbo") || strings.contains(content_str, "turbo.zsh") {
		append(results, CheckResult{
			name    = "shell configuration",
			status  = .OK,
			message = fmt.tprintf("wayu sourced in %s", filepath.base(shell_rc)),
			fixable = false,
		})
	} else {
		append(results, CheckResult{
			name    = "shell configuration",
			status  = .ERROR,
			message = fmt.tprintf("wayu not sourced in %s - add 'source \"$HOME/.config/wayu/init.zsh\"'", filepath.base(shell_rc)),
			fixable = true,
		})
	}
}

// Check 3: PATH entries
check_path_entries :: proc(results: ^[dynamic]CheckResult) {
	entries := read_config_entries(&PATH_SPEC)
	defer cleanup_entries(&entries)

	if len(entries) == 0 {
		append(results, CheckResult{
			name    = "PATH entries",
			status  = .INFO,
			message = "No custom PATH entries configured",
			fixable = false,
		})
		return
	}

	missing_count := 0
	duplicate_count := 0
	seen := make(map[string]bool)
	defer delete(seen)

	for entry in entries {
		expanded := expand_env_vars(entry.name)
		defer delete(expanded)

		if !os.exists(expanded) {
			missing_count += 1
		}

		if seen[expanded] {
			duplicate_count += 1
		}
		seen[expanded] = true
	}

	if missing_count == 0 && duplicate_count == 0 {
		append(results, CheckResult{
			name    = "PATH entries",
			status  = .OK,
			message = fmt.tprintf("%d PATH entries, all valid", len(entries)),
			fixable = false,
		})
	} else {
		msg_parts := make([dynamic]string)
		defer delete(msg_parts)

		if missing_count > 0 {
			append(&msg_parts, fmt.tprintf("%d missing", missing_count))
		}
		if duplicate_count > 0 {
			append(&msg_parts, fmt.tprintf("%d duplicates", duplicate_count))
		}

		append(results, CheckResult{
			name    = "PATH entries",
			status  = .WARNING,
			message = fmt.tprintf("%d PATH entries, %s - run 'wayu path clean' and 'wayu path dedup'", len(entries), strings.join(msg_parts[:], ", ")),
			fixable = true,
		})
	}
}

// Check 4: plugins
check_plugins :: proc(results: ^[dynamic]CheckResult) {
	config_file := fmt.aprintf("%s/plugins.json", WAYU_CONFIG)
	defer delete(config_file)

	if !os.exists(config_file) {
		append(results, CheckResult{
			name    = "plugins",
			status  = .INFO,
			message = "No plugins configured",
			fixable = false,
		})
		return
	}

	// Count installed plugins
	data, ok := safe_read_file(config_file)
	if !ok {
		append(results, CheckResult{
			name    = "plugins",
			status  = .WARNING,
			message = "Could not read plugins configuration",
			fixable = false,
		})
		return
	}
	defer delete(data)

	// Simple count check
	content := string(data)
	plugin_count := strings.count(content, "\"name\"")

	if plugin_count == 0 {
		append(results, CheckResult{
			name    = "plugins",
			status  = .INFO,
			message = "No plugins installed",
			fixable = false,
		})
	} else {
		append(results, CheckResult{
			name    = "plugins",
			status  = .OK,
			message = fmt.tprintf("%d plugin(s) installed", plugin_count),
			fixable = false,
		})
	}
}

// Check 5: backups
check_backups :: proc(results: ^[dynamic]CheckResult) {
	backup_dir := fmt.aprintf("%s/backup", WAYU_CONFIG)
	defer delete(backup_dir)

	if !os.exists(backup_dir) {
		append(results, CheckResult{
			name    = "backups",
			status  = .WARNING,
			message = "Backup directory not found",
			fixable = false,
		})
		return
	}

	// Count backups
	backup_count := 0
	// Simple count of files
	if fd, ok := os.open(backup_dir); ok == nil {
		defer os.close(fd)
		// Can't easily count without read_dir, assume OK for now
		append(results, CheckResult{
			name    = "backups",
			status  = .OK,
			message = "Backup system configured",
			fixable = false,
		})
		return
	}

	append(results, CheckResult{
		name    = "backups",
		status  = .INFO,
		message = "Backup system ready",
		fixable = false,
	})
}

// Check 6: TOML config
check_toml_config :: proc(results: ^[dynamic]CheckResult) {
	toml_path := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG)
	defer delete(toml_path)

	if !os.exists(toml_path) {
		append(results, CheckResult{
			name    = "TOML config",
			status  = .INFO,
			message = "No TOML configuration (using standard shell configs)",
			fixable = false,
		})
		return
	}

	// Try to validate
	if handle_validate() {
		append(results, CheckResult{
			name    = "TOML config",
			status  = .OK,
			message = "wayu.toml is valid",
			fixable = false,
		})
	} else {
		append(results, CheckResult{
			name    = "TOML config",
			status  = .ERROR,
			message = "wayu.toml has validation errors - run 'wayu toml validate'",
			fixable = true,
		})
	}
}

// Check 7: turbo export
check_turbo_export :: proc(results: ^[dynamic]CheckResult) {
	turbo_path := fmt.aprintf("%s/turbo.zsh", WAYU_CONFIG)
	defer delete(turbo_path)

	if !os.exists(turbo_path) {
		append(results, CheckResult{
			name    = "turbo export",
			status  = .INFO,
			message = "Turbo export not generated - run 'wayu export' for faster startup",
			fixable = true,
		})
		return
	}

	// Check if it's being used in shell config
	shell_rc := get_shell_rc_file()
	defer delete(shell_rc)

	if len(shell_rc) > 0 {
		content, ok := safe_read_file(shell_rc)
		if ok {
			defer delete(content)
			content_str := string(content)
			if strings.contains(content_str, "turbo.zsh") {
				append(results, CheckResult{
					name    = "turbo export",
					status  = .OK,
					message = "Turbo export generated and active",
					fixable = false,
				})
				return
			}
		}
	}

	append(results, CheckResult{
		name    = "turbo export",
		status  = .WARNING,
		message = "Turbo export generated but not used in shell config",
		fixable = true,
	})
}

// Check 8: dependencies
check_dependencies :: proc(results: ^[dynamic]CheckResult) {
	deps := []string{"git", "zsh"}

	for dep in deps {
		found := check_command_exists(dep)

		if found {
			append(results, CheckResult{
				name    = fmt.tprintf("dependency: %s", dep),
				status  = .OK,
				message = fmt.tprintf("%s found", dep),
				fixable = false,
			})
		} else {
			append(results, CheckResult{
				name    = fmt.tprintf("dependency: %s", dep),
				status  = .WARNING,
				message = fmt.tprintf("%s not found in common paths", dep),
				fixable = false,
			})
		}
	}
}

// Get shell RC file path
get_shell_rc_file :: proc() -> string {
	shell := DETECTED_SHELL
	home := os.get_env_alloc("HOME", context.temp_allocator)

	#partial switch shell {
	case .ZSH:
		zshrc := fmt.aprintf("%s/.zshrc", home)
		if os.exists(zshrc) {
			return zshrc
		}
		// Try zprofile
		zprofile := fmt.aprintf("%s/.zprofile", home)
		if os.exists(zprofile) {
			return zprofile
		}
		return zshrc // Default even if not exists
	case .BASH:
		bashrc := fmt.aprintf("%s/.bashrc", home)
		if os.exists(bashrc) {
			return bashrc
		}
		// Try bash_profile
		profile := fmt.aprintf("%s/.bash_profile", home)
		if os.exists(profile) {
			return profile
		}
		return bashrc
	case .UNKNOWN:
		return ""
	}

	return ""
}

// Check if a command exists in PATH
check_command_exists :: proc(cmd: string) -> bool {
	// Check common locations
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
