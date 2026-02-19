// backup.odin - Automatic backup system for config files

package wayu

import "core:os"
import "core:fmt"
import "core:time"
import "core:strings"
import "core:slice"

// Backup metadata
BackupInfo :: struct {
	original_file: string,
	backup_file:   string,
	timestamp:     time.Time,
	size:          i64,
}

// Create backup of file with timestamp in backup/ directory
create_backup :: proc(file_path: string) -> (backup_path: string, ok: bool) {
	debug("Creating backup for: %s", file_path)

	// Don't create backup of backup files
	if strings.contains(file_path, ".backup.") {
		debug("File is already a backup, skipping: %s", file_path)
		return "", true
	}

	if !os.exists(file_path) {
		// If file doesn't exist yet, no backup needed
		debug("File doesn't exist, no backup needed")
		return "", true
	}

	// Read original file
	content, read_ok := safe_read_file(file_path)
	if !read_ok {
		debug("Failed to read original file for backup")
		return "", false
	}
	defer delete(content)

	// Create backup directory if it doesn't exist
	backup_dir := fmt.aprintf("%s/backup", WAYU_CONFIG)
	defer delete(backup_dir)

	if !os.exists(backup_dir) {
		err := os.make_directory(backup_dir)
		if err != 0 {
			debug("Failed to create backup directory: %s", backup_dir)
			return "", false
		}
		debug("Created backup directory: %s", backup_dir)
	}

	// Extract base filename from path
	base_name := get_base_name(file_path)

	// Generate backup filename with human-readable date format
	now := time.now()
	year, month, day := time.date(now)
	hour, min, sec := time.clock(now)

	// Format: basename.backup.YYYY-MM-DD_HH-MM-SS
	backup_file := fmt.aprintf("%s/%s.backup.%04d-%02d-%02d_%02d-%02d-%02d",
		backup_dir, base_name, year, month, day, hour, min, sec)

	debug("Creating backup file: %s", backup_file)

	// Write backup
	write_ok := safe_write_file(backup_file, content)
	if !write_ok {
		delete(backup_file)
		debug("Failed to write backup file")
		return "", false
	}

	debug("Backup created successfully")
	return backup_file, true
}

// CLI version - fails immediately without prompt
// Used by all CLI commands to ensure non-interactive behavior
create_backup_cli :: proc(file_path: string) -> bool {
	backup_path, ok := create_backup(file_path)
	defer if ok do delete(backup_path)

	if !ok {
		print_error("Failed to create backup for %s", file_path)
		fmt.println("Aborting operation to prevent data loss.")
		return false
	}

	return true
}

// TUI version - prompts user on backup failure
// This function is ONLY called from TUI bridge, never from CLI
create_backup_tui :: proc(file_path: string, auto_backup := true) -> bool {
	if auto_backup {
		backup_path, ok := create_backup(file_path)
		defer if ok do delete(backup_path)

		if !ok {
			print_warning("Failed to create backup for %s", file_path)
			fmt.print("Continue anyway? [y/N]: ")

			input_buf: [10]byte
			n, err := os.read(os.stdin, input_buf[:])
			if err != 0 || n == 0 {
				return false
			}

			response := strings.trim_space(string(input_buf[:n]))
			return response == "y" || response == "Y"
		}

		return true
	}

	return true
}

// Restore from most recent backup
restore_from_backup :: proc(file_path: string) -> bool {
	debug("Attempting to restore from backup: %s", file_path)

	// Dry-run mode check
	if DRY_RUN {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould restore from backup:%s", BRIGHT_CYAN, RESET)
		fmt.printfln("  File: %s", file_path)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return true
	}

	backups := list_backups_for_file(file_path)
	defer {
		for backup in backups {
			delete(backup.original_file)
			delete(backup.backup_file)
		}
		delete(backups)
	}

	if len(backups) == 0 {
		print_error_simple("No backups found for: %s", file_path)
		return false
	}

	// Get most recent backup
	latest := backups[0]
	debug("Restoring from: %s", latest.backup_file)

	// Read backup
	content, read_ok := safe_read_file(latest.backup_file)
	if !read_ok {
		return false
	}
	defer delete(content)

	// Write to original location
	write_ok := safe_write_file(file_path, content)
	if !write_ok {
		return false
	}

	print_success("Restored from backup: %s", latest.backup_file)
	return true
}

// List all backups for a file from backup/ directory
list_backups_for_file :: proc(file_path: string) -> []BackupInfo {
	debug("Listing backups for: %s", file_path)

	// Search in backup/ directory instead of alongside original file
	dir := fmt.aprintf("%s/backup", WAYU_CONFIG)
	defer delete(dir)

	base := get_base_name(file_path)

	pattern := fmt.aprintf("%s.backup.", base)
	defer delete(pattern)

	dir_handle, err := os.open(dir)
	if err != 0 {
		debug("Failed to open directory: %s", dir)
		return {}
	}
	defer os.close(dir_handle)

	file_infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil {
		debug("Failed to read directory")
		return {}
	}
	defer os.file_info_slice_delete(file_infos, context.allocator)

	backups := make([dynamic]BackupInfo)
	defer delete(backups)

	for info in file_infos {
		if strings.has_prefix(info.name, pattern) && info.type != .Directory {
			full_path := fmt.aprintf("%s/%s", dir, info.name)

			// Extract timestamp from filename
			timestamp_str := info.name[len(pattern):]
			timestamp := parse_timestamp(timestamp_str)

			backup := BackupInfo{
				original_file = strings.clone(file_path),
				backup_file   = full_path,
				timestamp     = timestamp,
				size          = info.size,
			}
			append(&backups, backup)
		}
	}

	// Sort by timestamp (most recent first)
	slice.sort_by(backups[:], proc(a, b: BackupInfo) -> bool {
		return time.diff(a.timestamp, b.timestamp) < 0
	})

	result := make([]BackupInfo, len(backups))
	for i in 0..<len(backups) {
		result[i] = backups[i]
	}
	debug("Found %d backups", len(result))
	return result
}

// Parse timestamp from backup filename (format: YYYY-MM-DD_HH-MM-SS)
parse_timestamp :: proc(timestamp_str: string) -> time.Time {
	// Parse date format: YYYY-MM-DD_HH-MM-SS
	// Example: 2026-01-09_19-45-30

	// Try to parse new format first
	if len(timestamp_str) >= 19 && timestamp_str[4] == '-' && timestamp_str[7] == '-' && timestamp_str[10] == '_' {
		year := parse_int(timestamp_str[0:4])
		month := parse_int(timestamp_str[5:7])
		day := parse_int(timestamp_str[8:10])
		hour := parse_int(timestamp_str[11:13])
		min := parse_int(timestamp_str[14:16])
		sec := parse_int(timestamp_str[17:19])

		// Create time from components
		return time.datetime_to_time(year, month, day, hour, min, sec, 0)
	}

	// Fallback: parse old Unix timestamp format for backwards compatibility
	timestamp_int: i64 = 0
	for char in timestamp_str {
		if char >= '0' && char <= '9' {
			timestamp_int = timestamp_int * 10 + i64(char - '0')
		} else {
			break
		}
	}
	return time.unix(timestamp_int, 0)
}

// Helper to parse integer from string
parse_int :: proc(s: string) -> int {
	result: int = 0
	for char in s {
		if char >= '0' && char <= '9' {
			result = result * 10 + int(char - '0')
		}
	}
	return result
}

// Clean up old backups (keep last N)
cleanup_old_backups :: proc(file_path: string, keep_count: int = 5) -> int {
	debug("Cleaning up old backups for: %s (keep %d)", file_path, keep_count)

	// Dry-run mode check
	if DRY_RUN {
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
		if err == 0 {
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

// List backups for all config files
list_all_backups :: proc() {
	config_files := []string{
		fmt.aprintf("%s/%s", WAYU_CONFIG, PATH_FILE),
		fmt.aprintf("%s/%s", WAYU_CONFIG, ALIAS_FILE),
		fmt.aprintf("%s/%s", WAYU_CONFIG, CONSTANTS_FILE),
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

	if !restore_from_backup(config_file) {
		os.exit(EXIT_IOERR)
	}
}

// Clean up old backups for all config files
cleanup_all_old_backups :: proc() {
	config_files := []string{
		fmt.aprintf("%s/%s", WAYU_CONFIG, PATH_FILE),
		fmt.aprintf("%s/%s", WAYU_CONFIG, ALIAS_FILE),
		fmt.aprintf("%s/%s", WAYU_CONFIG, CONSTANTS_FILE),
	}
	defer {
		for file in config_files {
			delete(file)
		}
	}

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

	removed := cleanup_old_backups(config_file, 5)
	if removed > 0 {
		print_success("Cleaned up %d old backup(s) for %s", removed, config_type)
	} else {
		print_info("No old backups to clean up for %s", config_type)
	}
}

// Get config file path for backup operations
get_config_file_path :: proc(config_type: string) -> string {
	switch config_type {
	case "path":
		return fmt.aprintf("%s/%s", WAYU_CONFIG, PATH_FILE)
	case "alias":
		return fmt.aprintf("%s/%s", WAYU_CONFIG, ALIAS_FILE)
	case "constants":
		return fmt.aprintf("%s/%s", WAYU_CONFIG, CONSTANTS_FILE)
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
	fmt.println("  wayu backup restore <config-type>  Restore from most recent backup")
	fmt.println("  wayu backup remove [config-type]   Clean up old backups (alias: rm)")
	fmt.println("  wayu backup help                   Show this help")

	// Config types section
	fmt.printf("\n%s%sCONFIG TYPES:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  path       PATH configuration")
	fmt.println("  alias      Alias configuration")
	fmt.println("  constants  Environment constants")

	// Examples section
	fmt.printf("\n%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %s# List all backups%s\n", get_muted(), RESET)
	fmt.printf("  %swayu backup list%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# List path backups only%s\n", get_muted(), RESET)
	fmt.printf("  %swayu backup list path%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Restore path configuration from backup%s\n", get_muted(), RESET)
	fmt.printf("  %swayu backup restore path%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Clean up old backups%s\n", get_muted(), RESET)
	fmt.printf("  %swayu backup rm%s\n", get_muted(), RESET)

	// Notes section
	fmt.printf("\n%s%sNOTES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %s• Backups are created automatically before modifications%s\n", get_muted(), RESET)
	fmt.printf("  %s• Only the last 5 backups are kept per file%s\n", get_muted(), RESET)
	fmt.printf("  %s• Backup files are stored in the same directory as config files%s\n", get_muted(), RESET)
	fmt.printf("  %s• Restore always uses the most recent backup%s\n", get_muted(), RESET)
	fmt.println()
}