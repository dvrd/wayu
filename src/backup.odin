// backup.odin - Automatic backup system for config files

package wayu

import "core:os"
import "core:fmt"
import "core:time"
import "core:strings"
import "core:slice"
import "core:strconv"
import "base:runtime"

// Backup metadata
BackupInfo :: struct {
	original_file: string,
	backup_file:   string,
	timestamp:     time.Time,
	size:          i64,
	seq:           int, // collision suffix (-N) for same-microsecond backups
	pre_restore:   bool, // taken by `backup restore` of the state it replaced
}

// Backups kept per file after every CLI/TUI write (create_backup_cli/_tui).
BACKUP_KEEP_COUNT :: 5

// Filename suffix of the snapshot `backup restore` takes before restoring.
// A default restore skips these, so repeated restores don't ping-pong.
BACKUP_PRE_RESTORE_TAG :: ".pre-restore"

// Files already backed up by create_backup_cli in this (non-TUI) process.
// A command that writes the same file many times (template apply,
// doctor --fix) keeps ONE backup: the state before the command ran.
// Allocated on the raw heap: lives for the whole process.
@(private = "file")
_backed_up_this_run: [dynamic]string

// Create backup of file with timestamp in backup/ directory
create_backup :: proc(file_path: string, tag := "") -> (backup_path: string, ok: bool) {
	// Ensure global config paths are initialized (idempotent — safe to call multiple times)
	init_shell_globals()
	debug("Creating backup for: %s", file_path)

	// Don't create backup of backup files. Only the file name counts: a
	// directory like ~/my.backup.d must not disable backups.
	if strings.contains(get_base_name(file_path), ".backup.") {
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
	}

	base_name := backup_key(file_path)
	defer delete(base_name)

	// Generate backup filename with human-readable date format plus
	// microseconds. Second resolution alone let two backups taken within the
	// same second (doctor --fix write once per entry) overwrite
	// each other, losing the pristine pre-operation copy. The file is also
	// created exclusively (O_EXCL) with a `-N` suffix on collision, so an
	// existing backup is never clobbered.
	//
	// Format: <key>.backup.YYYY-MM-DD_HH-MM-SS.UUUUUU[-N] (UTC; see backup_key)
	now := time.now()
	year, month, day := time.date(now)
	hour, min, sec, nanos := time.precise_clock_from_time(now)

	stem := fmt.aprintf("%s/%s.backup.%04d-%02d-%02d_%02d-%02d-%02d.%06d",
		backup_dir, base_name, year, int(month), day, hour, min, sec, nanos / 1000)
	defer delete(stem)

	MAX_BACKUP_SEQ :: 1000
	for seq in 0..<MAX_BACKUP_SEQ {
		candidate := seq == 0 ? fmt.aprintf("%s%s", stem, tag) : fmt.aprintf("%s-%d%s", stem, seq, tag)

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

// Name a file's backups are stored under: "<key>.backup.<stamp>". Files wayu
// owns (under wayu.config / wayu.data: wayu.toml, init.zsh, plugins.json,
// extra.zsh ...) keep their base name. Any other file (the user's rc file)
// is keyed by its path with '/' as '%': relative to $HOME (~/.zshrc ->
// ".zshrc", $ZDOTDIR=~/.config/zsh -> ".config%zsh%.zshrc"), or absolute
// with a leading '%'. So two rc files with the same name keep separate
// histories.
backup_key :: proc(file_path: string, allocator := context.allocator) -> string {
	under :: proc(path, root: string) -> bool {
		return len(root) > 0 && len(path) > len(root) && strings.has_prefix(path, root) && path[len(root)] == '/'
	}
	if under(file_path, wayu.config) || under(file_path, wayu.data) {
		return strings.clone(get_base_name(file_path), allocator)
	}
	rel := file_path
	home := os.get_env("HOME", context.temp_allocator)
	if under(file_path, home) { rel = file_path[len(home) + 1:] }
	key, allocated := strings.replace_all(rel, "/", "%", allocator)
	if !allocated { key = strings.clone(rel, allocator) }
	return key
}

// The file a backup key stands for, for display: "~/.config/zsh/.zshrc",
// "/etc/x", or the bare name for wayu's own files and top-level ~ files.
backup_key_display :: proc(key: string, allocator := context.allocator) -> string {
	if !strings.contains(key, "%") { return strings.clone(key, allocator) }
	decoded, _ := strings.replace_all(key, "%", "/", context.temp_allocator)
	if strings.has_prefix(decoded, "/") { return strings.clone(decoded, allocator) }
	return strings.concatenate({"~/", decoded}, allocator)
}

// Every backup group in the backup dir (the <key> of "<key>.backup.*"),
// wayu.toml first, then by name. Free with delete_backup_keys.
list_backup_keys :: proc(allocator := context.allocator) -> []string {
	dir := fmt.tprintf("%s/backup", wayu.data)
	dir_handle, err := os.open(dir)
	if err != nil { return {} }
	defer os.close(dir_handle)
	infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil { return {} }
	defer os.file_info_slice_delete(infos, context.allocator)

	keys := make([dynamic]string, allocator)
	for info in infos {
		if info.type == .Directory { continue }
		i := strings.index(info.name, ".backup.")
		if i <= 0 { continue }
		key := info.name[:i]
		if slice.contains(keys[:], key) { continue }
		append(&keys, strings.clone(key, allocator))
	}
	slice.sort_by(keys[:], proc(a, b: string) -> bool {
		if (a == WAYU_TOML) != (b == WAYU_TOML) { return a == WAYU_TOML }
		return a < b
	})
	return keys[:]
}

delete_backup_keys :: proc(keys: []string, allocator := context.allocator) {
	for k in keys { delete(k, allocator) }
	delete(keys, allocator)
}

// CLI version - fails immediately without prompt
// Used by all CLI commands to ensure non-interactive behavior.
// Returns true when the backup was created or the file didn't exist yet (no-op).
// Returns false only when the file existed but the backup failed.
//
// Retention: after a new backup, only the newest BACKUP_KEEP_COUNT are kept.
// Outside the TUI a file is backed up once per process (see
// _backed_up_this_run), so bulk commands can't flood the backup dir or
// prune away their own pre-command snapshot.
create_backup_cli :: proc(file_path: string) -> bool {
	if !wayu.tui_mode {
		for f in _backed_up_this_run { if f == file_path { return true } }
	}
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

	if ok {
		if !wayu.tui_mode {
			if _backed_up_this_run.allocator.procedure == nil {
				_backed_up_this_run.allocator = runtime.heap_allocator()
			}
			append(&_backed_up_this_run, strings.clone(file_path, runtime.heap_allocator()))
		}
		prune_backups(file_path, BACKUP_KEEP_COUNT)
	}
	return true
}

// Forget which files were backed up in this process (tests that simulate
// several separate CLI invocations in one process).
backup_run_reset :: proc() {
	for f in _backed_up_this_run { delete(f, runtime.heap_allocator()) }
	clear(&_backed_up_this_run)
}

// Remove all but the newest `keep` backups of `file_path`, silently and
// regardless of --dry-run (callers only reach here after a real backup).
// `protect` (a backup path) is never removed and counts toward `keep`.
@(private = "file")
prune_backups :: proc(file_path: string, keep: int, protect := "") {
	backups := list_backups_for_file(file_path)
	defer free_backup_infos(backups)
	kept := 0
	for b in backups { if b.backup_file == protect { kept += 1 } }
	for b in backups {
		if b.backup_file == protect { continue }
		if kept < keep {
			kept += 1
			continue
		}
		debug("Pruning old backup: %s", b.backup_file)
		_ = os.remove(b.backup_file)
	}
}

free_backup_infos :: proc(backups: []BackupInfo) {
	for b in backups {
		delete(b.original_file)
		delete(b.backup_file)
	}
	delete(backups)
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
	if ok { prune_backups(file_path, BACKUP_KEEP_COUNT) }

	return true
}

// Pick the backup a restore uses. `selector` is "" (newest backup that is
// not a pre-restore snapshot, so repeated restores don't ping-pong), a
// 1-based index as printed by `wayu backup list`, or a backup file name /
// path from that list. Prints the reason and returns -1 when nothing fits.
select_backup :: proc(backups: []BackupInfo, selector: string) -> int {
	if len(selector) == 0 {
		for b, i in backups { if !b.pre_restore { return i } }
		if len(backups) > 0 { return 0 }
		return -1
	}
	all_digits := true
	for c in selector { if c < '0' || c > '9' { all_digits = false; break } }
	// Decimal digits only: parse_int also takes "0x1", "+1", "1_0".
	if n, ok := strconv.parse_int(selector, 10); all_digits && ok {
		if n >= 1 && n <= len(backups) { return n - 1 }
		print_error_simple("No backup #%s (there are %d; see 'wayu backup list')", selector, len(backups))
		return -1
	}
	for b, i in backups {
		if b.backup_file == selector || get_base_name(b.backup_file) == selector { return i }
	}
	print_error_simple("Not a backup of this file: %s (see 'wayu backup list')", selector)
	return -1
}

// Restore `file_path` from a backup (see select_backup for `selector`).
//
// Safety contract:
//   * the backup content is validated before anything is written (for
//     wayu.toml: toml_content_is_sane), so a corrupt backup can't replace a
//     working config;
//   * the CURRENT file is backed up first (tagged pre-restore), so a restore
//     is itself undoable (`wayu backup restore <type> 1`);
//   * after restoring wayu.toml the generated shell init is regenerated so
//     the shell actually sees the restored state.
// The --yes confirmation gate lives in the CLI handler (restore_config_backup).
restore_from_backup :: proc(file_path: string, selector := "") -> bool {
	debug("Attempting to restore from backup: %s", file_path)

	backups := list_backups_for_file(file_path)
	defer free_backup_infos(backups)

	if len(backups) == 0 {
		if wayu.dry_run {
			print_header("DRY RUN - No changes will be made", EMOJI_INFO)
			fmt.printfln("  Backup: (none found — restore would fail)")
			return true
		}
		print_error_simple("No backups found for: %s", file_path)
		return false
	}

	// Choose BEFORE backing up the current file (which becomes the newest).
	idx := select_backup(backups, selector)
	if idx < 0 { return false }
	chosen := backups[idx]

	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould restore from backup:%s", BRIGHT_CYAN, RESET)
		fmt.printfln("  File:   %s", file_path)
		fmt.printfln("  Backup: %s", chosen.backup_file)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return true
	}

	debug("Restoring from: %s", chosen.backup_file)
	content, read_ok := safe_read_file(chosen.backup_file)
	if !read_ok {
		return false
	}
	defer delete(content)

	is_wayu_toml := get_base_name(file_path) == WAYU_TOML
	if is_wayu_toml && !toml_content_is_sane(string(content)) {
		print_error_simple("Backup %s is not valid TOML — refusing to restore it", chosen.backup_file)
		return false
	}

	// Back up the current state so the restore can be undone.
	if os.exists(file_path) {
		pre_path, pre_ok := create_backup(file_path, BACKUP_PRE_RESTORE_TAG)
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
	// Keep the retention cap across repeated restores. The newest entry is the
	// snapshot just taken; the chosen backup is protected explicitly.
	prune_backups(file_path, BACKUP_KEEP_COUNT, chosen.backup_file)

	// Only regenerate when restoring the live config (not an arbitrary
	// file that happens to be named wayu.toml).
	live_toml := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	defer delete(live_toml)
	if file_path == live_toml {
		regenerate_init_core_silently()
	}

	print_success("Restored from backup: %s", chosen.backup_file)
	return true
}

// List all backups for a file from backup/ directory
list_backups_for_file :: proc(file_path: string) -> []BackupInfo {
	key := backup_key(file_path)
	defer delete(key)
	return list_backups_for_key(key, file_path)
}

// Backups stored under `key` (see backup_key), newest first; each
// original_file is a clone of `original`.
list_backups_for_key :: proc(key: string, original: string) -> []BackupInfo {
	file_path := original
	// Search in backup/ directory instead of alongside original file
	dir := fmt.aprintf("%s/backup", wayu.data)
	defer delete(dir)

	pattern := fmt.aprintf("%s.backup.", key)
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
			suffix := info.name[len(pattern):]
			pre_restore := strings.has_suffix(suffix, BACKUP_PRE_RESTORE_TAG)
			if pre_restore { suffix = suffix[:len(suffix) - len(BACKUP_PRE_RESTORE_TAG)] }
			timestamp, seq, stamp_ok := parse_backup_suffix(suffix)
			if !stamp_ok {
				delete(full_path)
				continue
			}

			backup := BackupInfo{
				original_file = strings.clone(file_path),
				backup_file   = full_path,
				timestamp     = timestamp,
				size          = info.size,
				seq           = seq,
				pre_restore   = pre_restore,
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

// Parse the stamp of a backup file name, the part after "<key>.backup."
// (BACKUP_PRE_RESTORE_TAG already stripped):
//   YYYY-MM-DD_HH-MM-SS.UUUUUU[-N]   (UTC, microseconds, collision sequence)
// ok=false for anything else: such a file is not a wayu backup.
parse_backup_suffix :: proc(s: string) -> (t: time.Time, seq: int, ok: bool) {
	// Layout of the fixed part; 'd' = ASCII digit.
	LAYOUT :: "dddd-dd-dd_dd-dd-dd.dddddd"
	if len(s) < len(LAYOUT) { return }
	for c, i in transmute([]u8)string(LAYOUT) {
		if c == 'd' {
			if s[i] < '0' || s[i] > '9' { return }
		} else if s[i] != c {
			return
		}
	}
	num :: proc(s: string) -> int {
		n := 0
		for c in transmute([]u8)s { n = n * 10 + int(c - '0') }
		return n
	}
	rest := s[len(LAYOUT):]
	if len(rest) > 0 {
		if len(rest) < 2 || rest[0] != '-' { return }
		for c in transmute([]u8)rest[1:] {
			if c < '0' || c > '9' { return }
		}
		seq = num(rest[1:])
	}
	parsed, valid := time.datetime_to_time(num(s[0:4]), num(s[5:7]), num(s[8:10]),
		num(s[11:13]), num(s[14:16]), num(s[17:19]), num(s[20:26]) * 1000)
	if !valid { return }
	return parsed, seq, true
}

// Clean up old backups (keep last N)
cleanup_old_backups :: proc(file_path: string, keep_count: int = 5) -> int {
	key := backup_key(file_path)
	defer delete(key)
	return cleanup_old_backups_key(key, keep_count)
}

cleanup_old_backups_key :: proc(key: string, keep_count: int = 5) -> int {
	debug("Cleaning up old backups for: %s (keep %d)", key, keep_count)

	backups := list_backups_for_key(key, key)
	defer free_backup_infos(backups)

	// Dry-run mode check
	if wayu.dry_run {
		if len(backups) > keep_count {
			print_info("DRY RUN: Would remove %d old backup(s)", len(backups) - keep_count)
		}
		return 0
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
	print_header(fmt.tprintf("Backups for %s", file_name))
	fmt.println()

	for backup, i in backups {
		// Format time in readable format
		time_str := format_backup_time(backup.timestamp)
		defer delete(time_str)

		// Format size
		size_kb := f32(backup.size) / 1024.0

		fmt.printf("  %s%s%d.%s ", MUTED, BOLD, i+1, RESET)
		backup_name := get_base_name(backup.backup_file)
		fmt.printf("%s%s%s ", PRIMARY, backup_name, RESET)
		fmt.printf("%s(%.1f KB)%s", MUTED, size_kb, RESET)
		if backup.pre_restore { fmt.printf(" %s[pre-restore]%s", MUTED, RESET) }
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

// Format backup timestamp (UTC, as in the file name) for display:
// "YYYY-MM-DD HH:MM:SS UTC", or ISO-8601 "YYYY-MM-DDTHH:MM:SSZ" with `iso`.
format_backup_time :: proc(timestamp: time.Time, iso := false) -> string {
	year, month, day := time.date(timestamp)
	hour, min, sec := time.clock(timestamp)

	if iso {
		return fmt.aprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", year, int(month), day, hour, min, sec)
	}
	return fmt.aprintf("%04d-%02d-%02d %02d:%02d:%02d UTC",
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
		if len(args) == 0 || len(args) > 2 {
			print_error_simple("Usage: wayu backup restore <config-type> [N|backup-file]")
			fmt.println("Example: wayu backup restore path        # newest backup")
			fmt.println("         wayu backup restore path 3      # #3 in 'wayu backup list'")
			os.exit(EXIT_USAGE)
		}
		restore_config_backup(args[0], args[1] if len(args) == 2 else "")
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

// The groups `backup list` / `backup rm` act on: wayu.toml always (so it is
// shown even with no backups), then every other group in the backup dir
// (init.zsh from --optimize, the rc file from init, plugins.json, ...).
// Also the TUI Backups view and its cleanup. Free with delete_backup_keys.
backup_list_groups :: proc() -> []string {
	keys := list_backup_keys()
	if slice.contains(keys, WAYU_TOML) { return keys }
	out := make([]string, len(keys) + 1)
	out[0] = strings.clone(WAYU_TOML)
	copy(out[1:], keys)
	delete(keys)
	return out
}

// Emit the same data as list_all_backups as a JSON document.
// Shape: { "backups": [ {"file": "<config>", "count": N, "entries": [ ... ]}, ... ]
// "file" is wayu.toml, another wayu file name, or the rc file's path
// (~/.config/zsh/.zshrc); "timestamp" is ISO-8601 UTC.
print_all_backups_json :: proc() {
	keys := backup_list_groups()
	defer delete_backup_keys(keys)

	fmt.println("{")
	fmt.println(`  "backups": [`)

	first_file := true
	for key in keys {
		file_name := backup_key_display(key, context.temp_allocator)
		backups := list_backups_for_key(key, key)
		defer free_backup_infos(backups)

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
			time_str := format_backup_time(backup.timestamp, iso = true)
			defer delete(time_str)
			if i > 0 { fmt.println(",") }
			// Paths come from $HOME and may contain `"`, `\` or control
			// characters — escape so the document stays valid JSON.
			path_j := json_escape(backup.backup_file)
			defer delete(path_j)
			fmt.printf("      %c\"index\": %d, \"timestamp\": \"%s\", \"size_bytes\": %d, \"path\": \"%s\", \"pre_restore\": %v%c",
				'{', i + 1, time_str, backup.size, path_j, backup.pre_restore, '}')
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
	keys := backup_list_groups()
	defer delete_backup_keys(keys)

	print_header("All Configuration Backups")
	fmt.println()

	total_backups := 0
	other_files := false
	for key in keys {
		file_name := backup_key_display(key, context.temp_allocator)
		backups := list_backups_for_key(key, key)
		defer free_backup_infos(backups)
		if len(backups) == 0 { continue }
		if key != WAYU_TOML { other_files = true }

		fmt.printfln("%s%s%s (%d backup(s)):", BRIGHT_CYAN, file_name, RESET, len(backups))
		for backup, i in backups {
			time_str := format_backup_time(backup.timestamp)
			defer delete(time_str)
			size_kb := f32(backup.size) / 1024.0

			fmt.printf("  %s%d.%s ", MUTED, i+1, RESET)
			fmt.printf("%s(%.1f KB)%s ", MUTED, size_kb, RESET)
			fmt.printf("%s%s%s%s\n", MUTED, time_str, " [pre-restore]" if backup.pre_restore else "", RESET)
		}
		fmt.println()
		total_backups += len(backups)
	}

	if total_backups == 0 {
		print_info("No backups found")
		fmt.println("Backups are created automatically when you modify configuration files.")
	} else {
		fmt.printfln("%sTotal:%s %d backup(s) across all files", BRIGHT_CYAN, RESET, total_backups)
		if other_files {
			// Only wayu.toml has `backup restore`; the others are plain copies.
			fmt.printfln("%sFiles other than wayu.toml: copy a backup back by hand from %s/backup (see 'wayu backup list --json' for paths)%s",
				MUTED, wayu.data, RESET)
		}
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
restore_config_backup :: proc(config_type: string, selector := "") {
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

	// Resolve an explicit selector up front: a bad index/name is a data
	// error (65), not an I/O failure.
	backups := list_backups_for_file(config_file)
	defer free_backup_infos(backups)
	idx := -1
	if len(backups) > 0 {
		idx = select_backup(backups, selector)
		if idx < 0 { os.exit(EXIT_DATAERR) }
	}

	if wayu.dry_run {
		fmt.printfln("%sNote:%s " + shared_note, BRIGHT_YELLOW, RESET, config_type)
		restore_from_backup(config_file, selector)
		return
	}

	if !wayu.yes_flag {
		print_error("This operation requires confirmation.")
		fmt.println()
		fmt.printfln(shared_note, config_type)
		if idx >= 0 {
			fmt.printfln("Would restore %s from: %s", get_base_name(config_file), backups[idx].backup_file)
			fmt.println("The current wayu.toml will be backed up first.")
		} else {
			fmt.printfln("No backups found for %s.", get_base_name(config_file))
		}
		fmt.println()
		fmt.printfln("Add --yes flag to proceed:")
		if len(selector) > 0 {
			fmt.printfln("  wayu backup restore %s %s --yes", config_type, selector)
		} else {
			fmt.printfln("  wayu backup restore %s --yes", config_type)
		}
		os.exit(EXIT_USAGE)
	}

	// Serialize with every other wayu.toml writer: without the lock a
	// concurrent `wayu const add` that read the file before the restore
	// overwrites it afterwards and the restore is silently lost. The backup
	// is re-selected under the lock (restore_from_backup).
	config_lock_acquire_or_exit()
	defer config_lock_release()

	fmt.printfln("%sNote:%s " + shared_note, BRIGHT_YELLOW, RESET, config_type)
	if !restore_from_backup(config_file, selector) {
		os.exit(EXIT_IOERR)
	}
}

// Clean up old backups for all config files
cleanup_all_old_backups :: proc() {
	keys := backup_list_groups()
	defer delete_backup_keys(keys)

	// Old backups per group (beyond the newest BACKUP_KEEP_COUNT).
	excess := make([]int, len(keys))
	defer delete(excess)
	total_to_remove := 0
	for key, i in keys {
		backups := list_backups_for_key(key, key)
		excess[i] = max(len(backups) - BACKUP_KEEP_COUNT, 0)
		total_to_remove += excess[i]
		free_backup_infos(backups)
	}

	if total_to_remove == 0 {
		print_info("No old backups to clean up")
		return
	}

	print_excess :: proc(keys: []string, excess: []int, bullet: string) {
		for key, i in keys {
			if excess[i] == 0 { continue }
			fmt.printfln("  %s%s: %d backup(s)", bullet, backup_key_display(key, context.temp_allocator), excess[i])
		}
	}

	// Dry-run mode check
	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		print_warning("Would remove %d old backup(s):", total_to_remove)
		print_excess(keys, excess, "")
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Check for --yes flag (required for confirmation)
	if !wayu.yes_flag {
		print_error("This operation requires confirmation.")
		fmt.println()
		fmt.printfln("Found %d old backup(s) to remove:", total_to_remove)
		print_excess(keys, excess, "- ")
		fmt.println()
		fmt.printfln("Add --yes flag to proceed:")
		fmt.printfln("  wayu backup rm --yes")
		os.exit(EXIT_USAGE)
	}

	// Proceed with removal
	total_removed := 0
	for key in keys {
		total_removed += cleanup_old_backups_key(key, BACKUP_KEEP_COUNT)
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
	fmt.println("  wayu backup restore <config-type> [N|file] --yes")
	fmt.println("                                     Restore the newest backup, or #N /")
	fmt.println("                                     a file from 'wayu backup list'")
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
	fmt.printf("  %swayu backup restore path 3 --yes   # #3 from 'wayu backup list'%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Clean up old backups%s\n", get_muted(), RESET)
	fmt.printf("  %swayu backup rm%s\n", get_muted(), RESET)

	// Notes section
	fmt.printf("\n%s%sNOTES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %s• Backups are created automatically before modifications%s\n", get_muted(), RESET)
	fmt.printf("  %s• Only the last 5 backups are kept per file; one backup per command%s\n", get_muted(), RESET)
	fmt.printf("  %s• Backup files are stored in ~/.config/wayu/backup/%s\n", get_muted(), RESET)
	fmt.printf("  %s• Restore backs up the current file first ([pre-restore]); without N it%s\n", get_muted(), RESET)
	fmt.printf("  %s  uses the newest backup that is not a [pre-restore] one%s\n", get_muted(), RESET)
	fmt.println()
}