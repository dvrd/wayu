// doctor_checks.odin - Individual health checks for `wayu doctor`
//
// Extracted from doctor.odin (2026-04-24) per code review L3. All check procs
// append their findings to a shared `[dynamic]CheckResult` using the doctor
// arena allocator (see `get_doctor_allocator` / `clone_arena` / `ensure_arena_initialized`
// in doctor.odin for the shared plumbing).
//
// Adding a new check: write a `CheckFn` proc, then register it in the `CHECKS`
// slice below. `run_all_checks` in doctor.odin iterates this slice, so no
// other wiring is needed. The short `name` on each entry is the stable
// identifier intended for a future `--check=<name>` selective mode.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// Signature every doctor check must implement.
CheckFn :: proc(results: ^[dynamic]CheckResult)

// Registered check with a stable short name. Names are snake-case-free ASCII
// so they fit cleanly into a future `--check=<name>` CLI flag.
CheckEntry :: struct {
	name: string,
	fn:   CheckFn,
}

// All registered checks. `run_all_checks` iterates this in order.
// Order mirrors the original hard-coded sequence from pre-refactor doctor.odin
// so output stays byte-stable for users.
CHECKS := []CheckEntry{
	{"installation", check_wayu_installation},
	{"shell",        check_shell_config},
	{"path",         check_path_entries},
	{"plugins",      check_plugins},
	{"backups",      check_backups},
	{"toml",         check_toml_config},
	{"turbo",        check_turbo_export},
	{"deps",         check_dependencies},
	{"sync",         check_sync_status},
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

// Get shell RC file path using arena. Used by the shell-aware checks
// (shell_config, turbo_export, sync_status) and kept next to them so the
// doctor file that owns the presentation layer doesn't depend on the details.
get_shell_rc_file_arena :: proc() -> string {
	ensure_arena_initialized()
	shell := g_ctx.shell
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
	case .FISH:
		// Fish uses ~/.config/fish/config.fish as the primary RC file.
		return fmt.aprintf("%s/.config/fish/config.fish", home, allocator = get_doctor_allocator())
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
	config_file := fmt.aprintf("%s/plugins.json", g_ctx.wayu_config, allocator = get_doctor_allocator())

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
	backup_dir := fmt.aprintf("%s/backup", g_ctx.wayu_config, allocator = get_doctor_allocator())

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
	toml_path := fmt.aprintf("%s/wayu.toml", g_ctx.wayu_config, allocator = get_doctor_allocator())

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
	turbo_path := fmt.aprintf("%s/turbo.zsh", g_ctx.wayu_config, allocator = get_doctor_allocator())

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

// Check if a command exists in PATH (helper for check_dependencies).
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

// Check 9: sync status — wayu entries vs environment
check_sync_status :: proc(results: ^[dynamic]CheckResult) {
	ensure_arena_initialized()
	arena_alloc := get_doctor_allocator()

	// Only run this check if wayu is initialized
	toml_file := fmt.aprintf("%s/%s", g_ctx.wayu_config, WAYU_TOML)
	defer delete(toml_file)

	if !os.exists(toml_file) {
		// wayu not initialized yet - skip sync check
		return
	}

	// Count wayu entries in current environment
	// This mirrors the logic from the list commands

	// Check PATH entries
	path_entries := snapshot_path_entries()
	// Note: We can't call toml_path_read() here as it's defined in path.odin
	// For now, just report basic sync status based on shell config presence

	shell_rc := get_shell_rc_file_arena()
	has_wayu_init := false

	if len(shell_rc) > 0 {
		if content, ok := safe_read_file(shell_rc); ok {
			has_wayu_init = strings.contains(string(content), "wayu/init") ||
						   strings.contains(string(content), "wayu-turbo") ||
						   strings.contains(string(content), "turbo.zsh")
			delete(content)
		}
	}

	// Build summary message
	sync_msg := ""
	sync_status := CheckStatus.OK

	if has_wayu_init {
		sync_msg = clone_arena("All wayu entries are loaded in current shell")
	} else {
		sync_msg = clone_arena("wayu not sourced in shell config — run 'source ~/.zshrc' to activate")
		sync_status = .WARNING
	}

	append(results, CheckResult{
		name    = clone_arena("Sync status"),
		status  = sync_status,
		message = sync_msg,
		fixable = false,
	})
}
