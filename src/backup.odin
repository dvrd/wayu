// backup.odin - Automatic backup system for config files

package wayu

import "core:os"
import "core:fmt"
import "core:time"
import "core:strings"
import "core:slice"
import "core:strconv"

// Backup metadata
BackupInfo :: struct {
	original_file: string,
	backup_file:   string,
	timestamp:     time.Time,
	size:          i64,
	seq:           int, // collision suffix (-N) for same-microsecond backups
}

// Create backup of file with timestamp in backup/ directory
create_backup :: proc(file_path: string) -> (backup_path: string, ok: bool) {
	// Ensure global config paths are initialized (idempotent — safe to call multiple times)
	init_shell_globals()
	debug("Creating backup for: %s", file_path)

	// Don't create backup of backup files
	if strings.contains(file_path, ".backup.") {
		debug("File is already a backup, skipping: %s", file_path)
		return "", true
	}

	if !os.exists(file_path) {
		// File doesn't exist yet — no backup needed, not an error.
		// Return false so callers can distinguish "no backup made" from "backup succeeded".
		debug("File doesn't exist, no backup needed")
		return "", false
	}

	// Read original file
	content, read_ok := safe_read_file(file_path)
	if !read_ok {
		debug("Failed to read original file for backup")
		return "", false
	}
	defer delete(content)

	// Create backup directory if it doesn't exist
	backup_dir := fmt.aprintf("%s/backup", wayu.data)
	defer delete(backup_dir)

	// Backups hold full wayu.toml copies, [env] secrets included: the
	// directory is 0700 and every backup 0600 (OKAMI-206).
	if !os.exists(backup_dir) {
		err := os.make_directory(backup_dir, SECRET_DIR_PERMS)
		if err != nil {
			debug("Failed to create backup directory: %s", backup_dir)
			return "", false
		}
		debug("Created backup directory: %s", backup_dir)
	} else {
		tighten_backup_dir_modes(backup_dir)
	}

	// Extract base filename from path
	base_name := get_base_name(file_path)

	// Generate backup filename with human-readable date format plus
	// microseconds. Second resolution alone let two backups taken within the
	// same second (migrate / doctor --fix write once per entry) overwrite
	// each other, losing the pristine pre-operation copy. The file is also
	// created exclusively (O_EXCL) with a `-N` suffix on collision, so an
	// existing backup is never clobbered.
	//
	// Format: basename.backup.YYYY-MM-DD_HH-MM-SS.UUUUUU[-N]
	now := time.now()
	year, month, day := time.date(now)
	hour, min, sec, nanos := time.precise_clock_from_time(now)

	stem := fmt.aprintf("%s/%s.backup.%04d-%02d-%02d_%02d-%02d-%02d.%06d",
		backup_dir, base_name, year, int(month), day, hour, min, sec, nanos / 1000)
	defer delete(stem)

	MAX_BACKUP_SEQ :: 1000
	for seq in 0..<MAX_BACKUP_SEQ {
		candidate := seq == 0 ? strings.clone(stem) : fmt.aprintf("%s-%d", stem, seq)

		f, open_err := os.open(candidate, {.Write, .Create, .Excl}, SECRET_FILE_PERMS)
		if open_err != nil {
			delete(candidate)
			if open_err == os.General_Error.Exist { continue }
			debug("Failed to create backup file: %v", open_err)
			return "", false
		}

		debug("Creating backup file: %s", candidate)
		n, write_err := os.write(f, content)
		close_err := os.close(f)
		if write_err != nil || close_err != nil || n != len(content) {
			os.remove(candidate)
			delete(candidate)
			debug("Failed to write backup file")
			return "", false
		}

		debug("Backup created successfully")
		return candidate, true
	}

	debug("Could not find a free backup filename for %s", base_name)
	return "", false
}

// Repair modes left by older wayu versions (backup dir 0755, backups 0644):
// chmod the dir to 0700 and any group/other-accessible entry to 0600.
// Best-effort and cheap — the dir holds at most a few files per config.
@(private = "file")
tighten_backup_dir_modes :: proc(backup_dir: string) {
	OPEN_BITS :: os.Permissions{.Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other}

	if info, err := os.stat(backup_dir, context.temp_allocator); err == nil && info.mode & OPEN_BITS != {} {
		if os.chmod(backup_dir, SECRET_DIR_PERMS) != nil {
			debug("Could not chmod backup dir %s", backup_dir)
		}
	}

	dir_handle, open_err := os.open(backup_dir)
	if open_err != nil { return }
	defer os.close(dir_handle)

	infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil { return }
	defer os.file_info_slice_delete(infos, context.allocator)

	for info in infos {
		if info.type != .Regular || info.mode & OPEN_BITS == {} { continue }
		restrict_file_mode(info.fullpath)
	}
}

// CLI version - fails immediately without prompt
// Used by all CLI commands to ensure non-interactive behavior.
// Returns true when the backup was created or the file didn't exist yet (no-op).
// Returns false only when the file existed but the backup failed.
create_backup_cli :: proc(file_path: string) -> bool {
	file_existed := os.exists(file_path)

	backup_path, ok := create_backup(file_path)
	defer if ok do delete(backup_path)

	if !ok && file_existed {
		// File was present but backup failed — abort to prevent data loss.
		if !wayu.tui_mode {
			print_error("Failed to create backup for %s", file_path)
			fmt.println("Aborting operation to prevent data loss.")
		}
		return false
	}

	return true
}

// TUI version — returns false on backup failure without blocking on stdin.
// In TUI raw mode os.read(stdin) would deadlock, so we rely on the caller
// (the TUI notification bar) to surface the error to the user.
create_backup_tui :: proc(file_path: string, auto_backup := true) -> bool {
	if !auto_backup {
		return true
	}

	file_existed := os.exists(file_path)

	backup_path, ok := create_backup(file_path)
	defer if ok do delete(backup_path)

	if !ok && file_existed {
		// Suppress stdout noise in TUI mode; the notification bar handles messaging.
		if !wayu.tui_mode {
			print_warning("Failed to create backup for %s", file_path)
		}
		return false
	}

	return true
}

// Restore `file_path` from its most recent backup.
//
// Safety contract:
//   * the backup content is validated before anything is written (for
//     wayu.toml: toml_content_is_sane), so a corrupt backup can't replace a
//     working config;
//   * the CURRENT file is backed up first, so a restore is itself undoable;
//   * after restoring wayu.toml the generated shell init is regenerated so
//     the shell actually sees the restored state.
// The --yes confirmation gate lives in the CLI handler (restore_config_backup).
restore_from_backup :: proc(file_path: string) -> bool {
	debug("Attempting to restore from backup: %s", file_path)

	backups := list_backups_for_file(file_path)
	defer {
		for backup in backups {
			delete(backup.original_file)
			delete(backup.backup_file)
		}
		delete(backups)
	}

	// Dry-run mode check
	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould restore from backup:%s", BRIGHT_CYAN, RESET)
		fmt.printfln("  File:   %s", file_path)
		if len(backups) > 0 {
			fmt.printfln("  Backup: %s", backups[0].backup_file)
		} else {
			fmt.printfln("  Backup: (none found — restore would fail)")
		}
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return true
	}

	if len(backups) == 0 {
		print_error_simple("No backups found for: %s", file_path)
		return false
	}

	// Get most recent backup BEFORE we back up the current file (which
	// would otherwise become the newest backup).
	latest := backups[0]
	debug("Restoring from: %s", latest.backup_file)

	content, read_ok := safe_read_file(latest.backup_file)
	if !read_ok {
		return false
	}
	defer delete(content)

	is_wayu_toml := get_base_name(file_path) == WAYU_TOML
	if is_wayu_toml && !toml_content_is_sane(string(content)) {
		print_error_simple("Backup %s is not valid TOML — refusing to restore it", latest.backup_file)
		return false
	}

	// Back up the current state so the restore can be undone.
	if os.exists(file_path) {
		pre_path, pre_ok := create_backup(file_path)
		if !pre_ok {
			print_error_simple("Could not back up current %s — aborting restore", file_path)
			return false
		}
		debug("Backed up current state to: %s", pre_path)
		delete(pre_path)
	}

	if !safe_write_file(file_path, content) {
		return false
	}

	// Only regenerate when restoring the live config (not an arbitrary
	// file that happens to be named wayu.toml).
	live_toml := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	defer delete(live_toml)
	if file_path == live_toml {
		regenerate_init_core_silently()
	}

	print_success("Restored from backup: %s", latest.backup_file)
	return true
}

// List all backups for a file from backup/ directory
list_backups_for_file :: proc(file_path: string) -> []BackupInfo {
	// Search in backup/ directory instead of alongside original file
	dir := fmt.aprintf("%s/backup", wayu.data)
	defer delete(dir)

	base := get_base_name(file_path)
	pattern := fmt.aprintf("%s.backup.", base)
	defer delete(pattern)

	dir_handle, err := os.open(dir)
	if err != nil {
		return {}
	}
	defer os.close(dir_handle)

	file_infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil {
		return {}
	}
	defer os.file_info_slice_delete(file_infos, context.allocator)

	backups := make([dynamic]BackupInfo)
	defer delete(backups)

	for info in file_infos {
		if strings.has_prefix(info.name, pattern) && info.type != os.File_Type.Directory {
			full_path := fmt.aprintf("%s/%s", dir, info.name)

			// Extract timestamp (+ collision sequence) from filename
			timestamp, seq := parse_backup_suffix(info.name[len(pattern):])

			backup := BackupInfo{
				original_file = strings.clone(file_path),
				backup_file   = full_path,
				timestamp     = timestamp,
				size          = info.size,
				seq           = seq,
			}
			append(&backups, backup)
		}
	}

	// Sort most recent first: timestamp, then collision sequence, then name
	// (deterministic tie-break).
	slice.sort_by(backups[:], proc(a, b: BackupInfo) -> bool {
		d := time.diff(a.timestamp, b.timestamp)
		if d != 0 { return d < 0 }
		if a.seq != b.seq { return a.seq > b.seq }
		return a.backup_file > b.backup_file
	})

	result := make([]BackupInfo, len(backups))
	for i in 0..<len(backups) {
		result[i] = backups[i]
	}
	return result
}

// Parse timestamp from backup filename suffix.
// Accepts (newest first):
//   YYYY-MM-DD_HH-MM-SS.UUUUUU[-N]   (sub-second + collision sequence)
//   YYYY-MM-DD_HH-MM-SS              (pre-4.5 second resolution)
//   <unix seconds>[...]              (legacy)
parse_timestamp :: proc(timestamp_str: string) -> time.Time {
	t, _ := parse_backup_suffix(timestamp_str)
	return t
}

parse_backup_suffix :: proc(timestamp_str: string) -> (t: time.Time, seq: int) {
	if len(timestamp_str) >= 19 && timestamp_str[4] == '-' && timestamp_str[7] == '-' && timestamp_str[10] == '_' {
		// Timestamp components are all ASCII digits by construction; if
		// parse fails (corrupted filename) we fall through to the legacy
		// Unix-timestamp path below — not the component-zero path — so
		// parse errors can't silently produce a "year 0" timestamp.
		year,  year_ok  := strconv.parse_int(timestamp_str[0:4])
		month, month_ok := strconv.parse_int(timestamp_str[5:7])
		day,   day_ok   := strconv.parse_int(timestamp_str[8:10])
		hour,  hour_ok  := strconv.parse_int(timestamp_str[11:13])
		min,   min_ok   := strconv.parse_int(timestamp_str[14:16])
		sec,   sec_ok   := strconv.parse_int(timestamp_str[17:19])

		if year_ok && month_ok && day_ok && hour_ok && min_ok && sec_ok {
			rest := timestamp_str[19:]
			nanos := 0
			if len(rest) > 0 && rest[0] == '.' {
				// Fractional seconds: up to 9 digits, scaled to nanoseconds.
				i := 1
				digits := 0
				for i < len(rest) && rest[i] >= '0' && rest[i] <= '9' {
					if digits < 9 {
						nanos = nanos * 10 + int(rest[i] - '0')
						digits += 1
					}
					i += 1
				}
				for _ in digits..<9 { nanos *= 10 }
				rest = rest[i:]
			}
			if len(rest) > 1 && rest[0] == '-' {
				if n, n_ok := strconv.parse_int(rest[1:]); n_ok { seq = n }
			}
			parsed, ok := time.datetime_to_time(year, month, day, hour, min, sec, nanos)
			if ok { return parsed, seq }
		}
		// fall through on parse failure
	}

	// Fallback: parse old Unix timestamp format for backwards compatibility.
	// Accepts a leading run of digits; stops at the first non-digit so the
	// ".bak" suffix and extension are tolerated.
	end := 0
	for end < len(timestamp_str) && timestamp_str[end] >= '0' && timestamp_str[end] <= '9' {
		end += 1
	}
	if end == 0 {
		return time.unix(0, 0), 0
	}
	timestamp_int, _ := strconv.parse_i64(timestamp_str[:end])
	return time.unix(timestamp_int, 0), 0
}

// Clean up old backups (keep last N)
cleanup_old_backups :: proc(file_path: string, keep_count: int = 5) -> int {
	debug("Cleaning up old backups for: %s (keep %d)", file_path, keep_count)

	// Dry-run mode check
	if wayu.dry_run {
		backups := list_backups_for_file(file_path)
		defer {
			for backup in backups {
				delete(backup.original_file)
				delete(backup.backup_file)
			}
			delete(backups)
		}

		if len(backups) > keep_count {
			print_info("DRY RUN: Would remove %d old backup(s)", len(backups) - keep_count)
		}
		return 0
	}

	backups := list_backups_for_file(file_path)
	defer {
		for backup in backups {
			delete(backup.original_file)
			delete(backup.backup_file)
		}
		delete(backups)
	}

	if len(backups) <= keep_count {
		debug("No cleanup needed, %d backups <= %d limit", len(backups), keep_count)
		return 0
	}

	// Remove oldest backups
	removed_count := 0
	for i in keep_count..<len(backups) {
		debug("Removing old backup: %s", backups[i].backup_file)
		err := os.remove(backups[i].backup_file)
		if err == nil {
			removed_count += 1
		}
	}

	debug("Cleaned up %d old backups", removed_count)
	return removed_count
}

// List all backups with pretty printing
print_backup_list :: proc(file_path: string) {
	backups := list_backups_for_file(file_path)
	defer {
		for backup in backups {
			delete(backup.original_file)
			delete(backup.backup_file)
		}
		delete(backups)
	}

	if len(backups) == 0 {
		print_info("No backups found for: %s", file_path)
		return
	}

	file_name := get_base_name(file_path)
	print_header(fmt.aprintf("Backups for %s", file_name))
	fmt.println()

	for backup, i in backups {
		// Format time in readable format
		time_str := format_backup_time(backup.timestamp)

		// Format size
		size_kb := f32(backup.size) / 1024.0

		fmt.printf("  %s%s%d.%s ", MUTED, BOLD, i+1, RESET)
		backup_name := get_base_name(backup.backup_file)
		fmt.printf("%s%s%s ", PRIMARY, backup_name, RESET)
		fmt.printf("%s(%.1f KB)%s", MUTED, size_kb, RESET)
		fmt.println()
		fmt.printf("     %s%s%s\n", MUTED, time_str, RESET)
	}

	fmt.printfln("\n%sTotal:%s %d backup(s)", BRIGHT_CYAN, RESET, len(backups))
}

// Helper functions for file path manipulation
get_directory_path :: proc(file_path: string) -> string {
	last_slash := strings.last_index(file_path, "/")
	if last_slash == -1 {
		return "."
	}
	return file_path[:last_slash]
}

get_base_name :: proc(file_path: string) -> string {
	last_slash := strings.last_index(file_path, "/")
	if last_slash == -1 {
		return file_path
	}
	return file_path[last_slash + 1:]
}

// Format backup timestamp for display
format_backup_time :: proc(timestamp: time.Time) -> string {
	// Simple format: YYYY-MM-DD HH:MM:SS
	year, month, day := time.date(timestamp)
	hour, min, sec := time.clock(timestamp)

	return fmt.aprintf("%04d-%02d-%02d %02d:%02d:%02d",
		year, int(month), day, hour, min, sec)
}

// Handle backup command
handle_backup_command :: proc(action: Action, args: []string) {
	#partial switch action {
	case .LIST:
		if wayu.json_output {
			print_all_backups_json()
			return
		}
		if len(args) == 0 {
			list_all_backups()
		} else {
			list_backups_for_config(args[0])
		}
	case .RESTORE:
		if len(args) == 0 {
			print_error_simple("Usage: wayu backup restore <config-type>")
			fmt.println("Example: wayu backup restore path")
			os.exit(EXIT_USAGE)
		}
		restore_config_backup(args[0])
	case .REMOVE:
		if len(args) == 0 {
			cleanup_all_old_backups()
		} else {
			cleanup_config_backups(args[0])
		}
	case .GET:
		fmt.eprintln("ERROR: get action not supported for backup command")
		fmt.println("The get action only applies to plugins")
		os.exit(EXIT_USAGE)
	case .HELP:
		print_backup_help()
	case .UNKNOWN:
		fmt.eprintln("Unknown backup action")
		print_backup_help()
		os.exit(EXIT_USAGE)
	case .ADD:
		print_error_simple("Backups are created automatically when modifying files")
		fmt.println("Use 'wayu backup list' to see existing backups")
		os.exit(EXIT_USAGE)
	case .CLEAN:
		fmt.eprintln("ERROR: clean action not supported for backup command")
		fmt.println("The clean action only applies to path entries")
		os.exit(EXIT_USAGE)
	case .DEDUP:
		fmt.eprintln("ERROR: dedup action not supported for backup command")
		fmt.println("The dedup action only applies to path entries")
		os.exit(EXIT_USAGE)
	}
}

// Emit the same data as list_all_backups as a JSON document.
// Shape: { "backups": [ {"file": "<config>", "count": N, "entries": [ ... ]}, ... ] }
print_all_backups_json :: proc() {
	config_files := []string{
		fmt.aprintf("%s/%s", wayu.config, WAYU_TOML),
	}
	defer {
		for f in config_files { delete(f) }
	}

	fmt.println("{")
	fmt.println(`  "backups": [`)

	first_file := true
	for config_file in config_files {
		file_name := get_base_name(config_file)
		backups := list_backups_for_file(config_file)
		defer {
			for b in backups {
				delete(b.original_file)
				delete(b.backup_file)
			}
			delete(backups)
		}

		if !first_file { fmt.println(",") }
		first_file = false

		// `{` is a struct-verb opener in Odin's fmt — emit via %c.
		file_name_j := json_escape(file_name)
		defer delete(file_name_j)
		fmt.printf("    %c\"file\": \"%s\", \"count\": %d, \"entries\": [", '{', file_name_j, len(backups))
		if len(backups) == 0 {
			fmt.print("]")
			fmt.print('}')
			continue
		}
		fmt.println()

		for backup, i in backups {
			time_str := format_backup_time(backup.timestamp)
			defer delete(time_str)
			if i > 0 { fmt.println(",") }
			// Paths come from $HOME and may contain `"`, `\` or control
			// characters — escape so the document stays valid JSON.
			path_j := json_escape(backup.backup_file)
			defer delete(path_j)
			fmt.printf("      %c\"timestamp\": \"%s\", \"size_bytes\": %d, \"path\": \"%s\"%c",
				'{', time_str, backup.size, path_j, '}')
		}
		fmt.println()
		fmt.print("    ]")
		fmt.print('}')
	}

	fmt.println()
	fmt.println("  ]")
	fmt.println("}")
}

// List backups for all config files
list_all_backups :: proc() {
	config_files := []string{
		fmt.aprintf("%s/%s", wayu.config, WAYU_TOML),
	}
	defer {
		for file in config_files {
			delete(file)
		}
	}

	print_header("All Configuration Backups")
	fmt.println()

	total_backups := 0
	for config_file in config_files {
		file_name := get_base_name(config_file)
		backups := list_backups_for_file(config_file)

		if len(backups) > 0 {
			fmt.printfln("%s%s%s (%d backup(s)):", BRIGHT_CYAN, file_name, RESET, len(backups))

			for backup, i in backups {
				time_str := format_backup_time(backup.timestamp)
				size_kb := f32(backup.size) / 1024.0

				fmt.printf("  %s%d.%s ", MUTED, i+1, RESET)
				fmt.printf("%s(%.1f KB)%s ", MUTED, size_kb, RESET)
				fmt.printf("%s%s%s\n", MUTED, time_str, RESET)
			}
			fmt.println()
			total_backups += len(backups)
		}

		// Clean up backup info
		for backup in backups {
			delete(backup.original_file)
			delete(backup.backup_file)
		}
		delete(backups)
	}

	if total_backups == 0 {
		print_info("No backups found")
		fmt.println("Backups are created automatically when you modify configuration files.")
	} else {
		fmt.printfln("%sTotal:%s %d backup(s) across all files", BRIGHT_CYAN, RESET, total_backups)
	}
}

// List backups for specific config type
list_backups_for_config :: proc(config_type: string) {
	config_file := get_config_file_path(config_type)
	if config_file == "" {
		print_error_simple("Unknown config type: %s", config_type)
		fmt.println("Valid types: path, alias, constants")
		os.exit(EXIT_DATAERR)
	}
	defer delete(config_file)

	print_backup_list(config_file)
}

// Restore backup for specific config type
restore_config_backup :: proc(config_type: string) {
	config_file := get_config_file_path(config_type)
	if config_file == "" {
		print_error_simple("Unknown config type: %s", config_type)
		fmt.println("Valid types: path, alias, constants")
		os.exit(EXIT_DATAERR)
	}
	defer delete(config_file)

	// path/alias/constants all live in the single wayu.toml, so restoring
	// any of them reverts the WHOLE file. Make that explicit.
	shared_note :: "wayu.toml holds paths, aliases AND constants — restoring reverts the entire file, not just %s entries."

	if wayu.dry_run {
		fmt.printfln("%sNote:%s " + shared_note, BRIGHT_YELLOW, RESET, config_type)
		restore_from_backup(config_file)
		return
	}

	if !wayu.yes_flag {
		backups := list_backups_for_file(config_file)
		print_error("This operation requires confirmation.")
		fmt.println()
		fmt.printfln(shared_note, config_type)
		if len(backups) > 0 {
			fmt.printfln("Would restore %s from: %s", get_base_name(config_file), backups[0].backup_file)
			fmt.println("The current wayu.toml will be backed up first.")
		} else {
			fmt.printfln("No backups found for %s.", get_base_name(config_file))
		}
		for b in backups {
			delete(b.original_file)
			delete(b.backup_file)
		}
		delete(backups)
		fmt.println()
		fmt.printfln("Add --yes flag to proceed:")
		fmt.printfln("  wayu backup restore %s --yes", config_type)
		os.exit(EXIT_USAGE)
	}

	fmt.printfln("%sNote:%s " + shared_note, BRIGHT_YELLOW, RESET, config_type)
	if !restore_from_backup(config_file) {
		os.exit(EXIT_IOERR)
	}
}

// Clean up old backups for all config files
cleanup_all_old_backups :: proc() {
	config_files := []string{
		fmt.aprintf("%s/%s", wayu.config, WAYU_TOML),
	}
	defer {
		for file in config_files {
			delete(file)
		}
	}

	// First, count how many backups will be removed
	total_to_remove := 0
	for config_file in config_files {
		backups := list_backups_for_file(config_file)
		if len(backups) > 5 {
			total_to_remove += len(backups) - 5
		}
		// Cleanup backup info
		for backup in backups {
			delete(backup.original_file)
			delete(backup.backup_file)
		}
		delete(backups)
	}

	if total_to_remove == 0 {
		print_info("No old backups to clean up")
		return
	}

	// Dry-run mode check
	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		print_warning("Would remove %d old backup(s):", total_to_remove)
		for config_file in config_files {
			backups := list_backups_for_file(config_file)
			defer {
				for backup in backups {
					delete(backup.original_file)
					delete(backup.backup_file)
				}
				delete(backups)
			}
			if len(backups) > 5 {
				file_name := get_base_name(config_file)
				fmt.printfln("  %s: %d backup(s)", file_name, len(backups) - 5)
			}
		}
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Check for --yes flag (required for confirmation)
	if !wayu.yes_flag {
		print_error("This operation requires confirmation.")
		fmt.println()
		fmt.printfln("Found %d old backup(s) to remove:", total_to_remove)
		for config_file in config_files {
			backups := list_backups_for_file(config_file)
			defer {
				for backup in backups {
					delete(backup.original_file)
					delete(backup.backup_file)
				}
				delete(backups)
			}
			if len(backups) > 5 {
				file_name := get_base_name(config_file)
				fmt.printfln("  - %s: %d backup(s)", file_name, len(backups) - 5)
			}
		}
		fmt.println()
		fmt.printfln("Add --yes flag to proceed:")
		fmt.printfln("  wayu backup rm --yes")
		os.exit(EXIT_USAGE)
	}

	// Proceed with removal
	total_removed := 0
	for config_file in config_files {
		removed := cleanup_old_backups(config_file, 5)
		total_removed += removed
	}

	if total_removed > 0 {
		print_success("Cleaned up %d old backup(s)", total_removed)
	} else {
		print_info("No old backups to clean up")
	}
}

// Clean up old backups for specific config type
cleanup_config_backups :: proc(config_type: string) {
	config_file := get_config_file_path(config_type)
	if config_file == "" {
		print_error_simple("Unknown config type: %s", config_type)
		fmt.println("Valid types: path, alias, constants")
		os.exit(EXIT_DATAERR)
	}
	defer delete(config_file)

	// First, count how many backups will be removed
	backups := list_backups_for_file(config_file)
	defer {
		for backup in backups {
			delete(backup.original_file)
			delete(backup.backup_file)
		}
		delete(backups)
	}

	if len(backups) <= 5 {
		print_info("No old backups to clean up for %s", config_type)
		return
	}

	to_remove := len(backups) - 5

	// Dry-run mode check
	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		print_warning("Would remove %d old backup(s) for %s:", to_remove, config_type)
		for i in 5..<len(backups) {
			backup_name := get_base_name(backups[i].backup_file)
			fmt.printfln("  - %s", backup_name)
		}
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Check for --yes flag (required for confirmation)
	if !wayu.yes_flag {
		print_error("This operation requires confirmation.")
		fmt.println()
		fmt.printfln("Found %d old backup(s) to remove for %s:", to_remove, config_type)
		for i in 5..<len(backups) {
			backup_name := get_base_name(backups[i].backup_file)
			fmt.printfln("  - %s", backup_name)
		}
		fmt.println()
		fmt.printfln("Add --yes flag to proceed:")
		fmt.printfln("  wayu backup rm %s --yes", config_type)
		os.exit(EXIT_USAGE)
	}

	removed := cleanup_old_backups(config_file, 5)
	if removed > 0 {
		print_success("Cleaned up %d old backup(s) for %s", removed, config_type)
	} else {
		print_info("No old backups to clean up for %s", config_type)
	}
}

// Get config file path for backup operations
get_config_file_path :: proc(config_type: string) -> string {
	// wayu.toml is now the single source of truth for path/alias/constants,
	// so every config-type argument resolves to it. The distinction survives
	// only for CLI compatibility.
	switch config_type {
	case "path", "alias", "constants", "toml":
		return fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	case:
		return ""
	}
}

// Help for backup command
print_backup_help :: proc() {
	// Title
	fmt.printf("\n%s%swayu backup - Manage configuration backups%s\n\n", BOLD, get_primary(), RESET)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu backup list [config-type]     List all backups (or for specific config)")
	fmt.println("  wayu backup restore <config-type> --yes  Restore from most recent backup")
	fmt.println("  wayu backup remove [config-type]   Clean up old backups (alias: rm)")
	fmt.println("  wayu backup help                   Show this help")

	// Config types section
	fmt.printf("\n%s%sCONFIG TYPES:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  path, alias, constants, toml")
	fmt.println("             All map to the single wayu.toml file — a restore")
	fmt.println("             reverts the WHOLE wayu.toml, not just one section")

	// Examples section
	fmt.printf("\n%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %s# List all backups%s\n", get_muted(), RESET)
	fmt.printf("  %swayu backup list%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# List path backups only%s\n", get_muted(), RESET)
	fmt.printf("  %swayu backup list path%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Restore path configuration from backup%s\n", get_muted(), RESET)
	fmt.printf("  %swayu backup restore path --yes%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Clean up old backups%s\n", get_muted(), RESET)
	fmt.printf("  %swayu backup rm%s\n", get_muted(), RESET)

	// Notes section
	fmt.printf("\n%s%sNOTES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %s• Backups are created automatically before modifications%s\n", get_muted(), RESET)
	fmt.printf("  %s• Only the last 5 backups are kept per file%s\n", get_muted(), RESET)
	fmt.printf("  %s• Backup files are stored in ~/.config/wayu/backup/%s\n", get_muted(), RESET)
	fmt.printf("  %s• Restore uses the most recent backup and backs up the current file first%s\n", get_muted(), RESET)
	fmt.println()
}