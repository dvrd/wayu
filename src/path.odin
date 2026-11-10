#+feature dynamic-literals
// path.odin - PATH entry management (refactored to use config_entry abstraction)
//
// This module manages PATH entries using the generic config_entry system.
// It provides PATH-specific functionality like clean and dedup operations.


package wayu

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Outcome of a PATH entry mutation. Lets the CLI handler tell a real change
// apart from a no-op (duplicate add) and pick the right exit code.
PathOpResult :: enum {
	OK, // changed (or, under --dry-run, would change)
	NOOP, // nothing to do (e.g. path already present)
	NOT_FOUND, // remove target not an entry             → EXIT_DATAERR
	INVALID, // bad input (name hint, ...)             → EXIT_DATAERR
	IO_ERROR, // backup/write failure                   → EXIT_IOERR
	BAD_STORE, // entries.json unreadable / malformed    → EXIT_CONFIG
}

// Main handler for PATH commands (entries live in <data>/entries.json).
handle_path_command :: proc(action: Action, args: []string) {
	// Mutations hold the config lock across read → write → regenerate so
	// concurrent wayu runs neither lose entries nor publish stale init files.
	mutating := action == .ADD || action == .REMOVE || action == .CLEAN || action == .DEDUP
	if mutating {
		config_lock_acquire_or_exit()
	}
	defer if mutating {
		config_lock_release()
	}

	if !ensure_wayu_toml_exists() {
		print_error_simple("Failed to create wayu.toml")
		os.exit(EXIT_IOERR)
	}
	// Before `wayu init`: one "not initialized" error (exit 78) like alias/
	// const, not a file-not-found plus a read error (OKAMI-237). `add`
	// checks after validating its argument (bad input is reported first).
	if action != .HELP && action != .UNKNOWN && action != .ADD && !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	#partial switch action {
	case .CLEAN:
		clean_missing_paths()
	case .DEDUP:
		remove_duplicate_paths()
	case .GET:
		if len(args) == 0 {
			print_cli_usage_error(&PATH_SPEC, "get")
			os.exit(EXIT_USAGE)
		}
		path_get_value(args[0])
	case .ADD:
		if len(args) == 0 {
			print_error("Usage: wayu path add [<name>=]<path>")
			os.exit(EXIT_USAGE)
		}
		name_hint, raw_path, _ := parse_path_arg(args[0])
		expanded, check_err, check_code := path_add_check(raw_path)
		defer delete(expanded)
		if check_code != EXIT_SUCCESS {
			print_error("%s", check_err)
			delete(check_err)
			os.exit(check_code)
		}
		if !check_wayu_initialized() {
			os.exit(EXIT_CONFIG)
		}
		// pre-hook only for an add that will really change the entries
		// (duplicates / bad names are reported by the write below).
		if path_add_would_change(raw_path, name_hint) {
			hook_pre_path_add(expanded)
		}
		res := path_add_result(raw_path, name_hint)
		exit_on_path_failure(res)
		// NOOP: already present (warning printed). Dry-run: preview printed.
		// Neither changed anything, so no regen, no success line, no hook.
		if res == .NOOP || wayu.dry_run {
			return
		}
		regenerate_init_core_silently()
		print_success("Added to PATH: %s", expanded)
		print_path_applied_hint()
		hook_post_path_add(expanded)
	case .REMOVE:
		if len(args) == 0 {
			print_error("Usage: wayu path remove <name-or-path>")
			os.exit(EXIT_USAGE)
		}
		// Hooks get the stored directory ({path}), also when the target is a key.
		hook_path, found := path_entry_lookup(args[0])
		defer delete(hook_path)
		if found {
			hook_pre_path_remove(hook_path)
		}
		res := path_remove_result(args[0])
		exit_on_path_failure(res)
		if wayu.dry_run {
			return
		}
		regenerate_init_core_silently()
		print_success("Removed from PATH: %s", args[0])
		print_path_applied_hint()
		hook_post_path_remove(hook_path)
	case .LIST:
		path_list()
	case:
		handle_config_command(&PATH_SPEC, action, args)
	}
}

// The checks `wayu path add` applies to its path argument before writing,
// shared with the TUI add form: valid format, resolvable to an absolute path
// ($VAR set, relative paths against the working directory), and existing.
// On success `expanded` is the resolved path (caller deletes) and code is
// EXIT_SUCCESS; otherwise `err` (caller deletes) says why and `code` is the
// CLI exit code (EXIT_DATAERR / EXIT_NOINPUT).
path_add_check :: proc(raw_path: string) -> (expanded: string, err: string, code: int) {
	result := validate_path_entry(ConfigEntry{type = .PATH, name = raw_path})
	if len(result.warning) > 0 do delete(result.warning)
	if !result.valid {
		return "", result.error_message, EXIT_DATAERR
	}
	expanded = expand_env_vars(raw_path, require_resolved = true)
	if len(expanded) == 0 {
		delete(expanded)
		return "",
			fmt.aprintf("Could not resolve path to an absolute path: %s", raw_path),
			EXIT_DATAERR
	}
	if !os.exists(expanded) {
		delete(expanded)
		return "", fmt.aprintf("Path does not exist: %s", raw_path), EXIT_NOINPUT
	}
	return expanded, "", EXIT_SUCCESS
}

// zsh/bash shells apply [paths] changes at their next prompt (path_sync
// hook); fish has no live sync yet, so it still needs a reload.
@(private = "file")
print_path_applied_hint :: proc() {
	if wayu.shell == .FISH {
		fmt.printfln(
			"   Reload your shell (or 'source %s/init.%s') to apply.",
			wayu.data,
			wayu.shell_ext,
		)
		return
	}
	fmt.println(
		"   Open shells apply it at their next prompt; new shells pick it up automatically.",
	)
}

// Exit with the code matching a failed PathOpResult; returns for OK/NOOP.
@(private = "file")
exit_on_path_failure :: proc(res: PathOpResult) {
	#partial switch res {
	case .NOT_FOUND, .INVALID:
		os.exit(EXIT_DATAERR)
	case .IO_ERROR:
		os.exit(EXIT_IOERR)
	case .BAD_STORE:
		os.exit(EXIT_CONFIG)
	}
}

// ============================================================================
// PATH-specific operations (clean and dedup)
// ============================================================================
//
// Both compute the set of store entries to drop, then share one mutation
// tail — empty-set early return, --dry-run preview, --yes gate, backup +
// rewrite of entries.json without the dropped entries, init regeneration.

PathMutationSpec :: struct {
	label:             string, // Human-readable "duplicate entries" / "missing directories"
	empty_success_msg: string, // Printed when nothing is to be removed
	header_title:      string, // print_header title on the actual mutation
	header_icon:       string,
	yes_hint_cmd:      string, // Usage line for --yes refusal, e.g. "wayu path clean --yes"
	success_fmt:       string, // Printed on success with the count, e.g. "✅ Removed %d missing ..."
}

// Drop every `entries[i]` with `drop[i] == true`. Handles preview,
// confirmation, backup, write and regeneration per `spec`.
mutate_path_entries :: proc(spec: PathMutationSpec, entries: []StorePath, drop: []bool) {
	assert(len(entries) == len(drop))
	count := 0
	for d in drop {
		if d {
			count += 1
		}
	}

	if count == 0 {
		print_success("%s", spec.empty_success_msg)
		return
	}

	print_targets :: proc(entries: []StorePath, drop: []bool) {
		for e, i in entries {
			if drop[i] {
				fmt.printfln("  - %s = %s", e.key, e.dir)
			}
		}
	}

	// Dry-run preview
	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		print_warning("Would remove %d %s:", count, spec.label)
		print_targets(entries, drop)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// --yes gate
	if !wayu.yes_flag {
		print_error("This operation requires confirmation.")
		fmt.println()
		fmt.printfln("Found %d %s to remove:", count, spec.label)
		print_targets(entries, drop)
		fmt.println()
		fmt.printfln("Add --yes flag to proceed:")
		fmt.printfln("  %s", spec.yes_hint_cmd)
		os.exit(EXIT_USAGE)
	}

	// Confirmation banner
	print_header(spec.header_title, spec.header_icon)
	fmt.println()
	print_warning("Found %d %s to remove:", count, spec.label)
	print_targets(entries, drop)
	fmt.println()

	// The survivors keep their order (PATH precedence).
	exit_on_path_failure(path_store_drop(entries, drop))

	regenerate_init_core_silently()
	print_success(spec.success_fmt, count)
}

// Which PATH entries `path clean` drops: those whose directory is missing
// after expanding the env constants, the environment and `~` the way the
// generated init does (doctor_expand_path). An entry using a variable set in
// neither is unresolved — its directory is unknown, so it is kept.
// Caller deletes the result.
path_clean_drop_mask :: proc(entries: []StorePath, consts: []ConfigEntry) -> []bool {
	drop := make([]bool, len(entries))
	for e, i in entries {
		expanded := doctor_expand_path(e.dir, consts)
		defer delete(expanded)
		drop[i] = len(expanded) > 0 && !os.exists(expanded)
	}
	return drop
}

// Which PATH entries `path dedup` drops: later entries resolving (same
// expansion as path_clean_drop_mask) to an earlier entry's directory.
// Unresolved entries only match byte-for-byte. Caller deletes the result.
path_dedup_drop_mask :: proc(entries: []StorePath, consts: []ConfigEntry) -> []bool {
	drop := make([]bool, len(entries))
	seen := make(map[string]bool)
	defer {
		for k in seen {delete(k)}
		delete(seen)
	}
	for e, i in entries {
		k := doctor_expand_path(e.dir, consts)
		if len(k) == 0 {
			// Expanded keys are absolute ("/..."), so "raw:" can't collide.
			delete(k)
			k = strings.concatenate({"raw:", e.dir})
		}
		if k in seen {
			drop[i] = true
			delete(k)
			continue
		}
		seen[k] = true
	}
	return drop
}

// clean / dedup: compute `mask` over the current entries and apply `spec`.
@(private = "file")
path_prune :: proc(
	spec: PathMutationSpec,
	mask: proc(entries: []StorePath, consts: []ConfigEntry) -> []bool,
) {
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}
	config_lock_acquire_or_exit()
	defer config_lock_release()

	store := entries_load()
	defer entries_store_destroy(&store)
	consts := entries_as_config_entries(&store, .ENV)
	defer cleanup_entries(&consts)
	drop := mask(store.paths[:], consts)
	defer delete(drop)

	mutate_path_entries(spec, store.paths[:], drop)
}

// Clean missing paths - remove PATH entries whose directory no longer
// exists (see path_clean_drop_mask; unset variables are never "missing").
clean_missing_paths :: proc() {
	path_prune(
		PathMutationSpec {
			label = "missing directories",
			empty_success_msg = "✅ No missing directories found in PATH",
			header_title = "Clean Missing PATH Entries",
			header_icon = "🧹",
			yes_hint_cmd = "wayu path clean --yes",
			success_fmt = "✅ Removed %d missing directories from PATH",
		},
		path_clean_drop_mask,
	)
}

// Remove duplicate paths - entries that resolve to the same directory after
// expansion (`$HOME/bin` == `~/bin` == `/Users/me/bin`). The first entry in
// order survives; later duplicates are dropped.
remove_duplicate_paths :: proc() {
	path_prune(
		PathMutationSpec {
			label = "duplicate entries",
			empty_success_msg = "✅ No duplicate entries found in PATH",
			header_title = "Remove Duplicate PATH Entries",
			header_icon = "🔗",
			yes_hint_cmd = "wayu path dedup --yes",
			success_fmt = "✅ Removed %d duplicate entries from PATH",
		},
		path_dedup_drop_mask,
	)
}

// os.exists on the resolved value (`$HOME/bin` checks /Users/me/bin).
path_exists_expanded :: proc(p: string) -> bool {
	expanded := expand_env_vars(p)
	defer delete(expanded)
	return os.exists(expanded)
}

// True when two PATH values refer to the same directory once env vars, `~`
// and relative segments are resolved (`$HOME/bin` vs `~/bin`).
// Both sides resolve strictly (require_resolved); values that can't be
// resolved (unset $VAR, ~user) only match byte-for-byte.
// Shared by add (duplicate check), rm (target match) and get.
path_values_equal :: proc(a, b: string) -> bool {
	if a == b {
		return true
	}
	ea := expand_env_vars(a, require_resolved = true)
	defer delete(ea)
	if len(ea) == 0 {
		return false
	}
	eb := expand_env_vars(b, require_resolved = true)
	defer delete(eb)
	return ea == eb
}

// ============================================================================
// PATH-specific helpers
// ============================================================================

// is_env_var_char returns true for characters valid in a shell identifier:
// A-Z, a-z, 0-9, underscore.
@(private = "file")
is_env_var_char :: proc(c: byte) -> bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'
}

// Expand environment variables in path strings.
// Handles $VAR and ${VAR} syntax for any variable present in the environment.
// Unresolved tokens (variable not set or empty) are left as-is.
// A leading `~` or `~/` expands to $HOME (as the shell would).
// With require_resolved, return an empty string on unresolved variables or failure.
// The caller must delete the returned string.
expand_env_vars :: proc(path: string, require_resolved: bool = false) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	i := 0
	if path == "~" || strings.has_prefix(path, "~/") {
		home := os.get_env("HOME", context.allocator)
		defer delete(home)
		if len(home) == 0 {
			if require_resolved {
				return ""
			}
		} else {
			strings.write_string(&builder, home)
			i = 1
		}
	} else if require_resolved && strings.has_prefix(path, "~") {
		// Named-user home expansion is unsupported; never anchor it to cwd.
		return ""
	}
	for i < len(path) {
		if path[i] != '$' {
			strings.write_byte(&builder, path[i])
			i += 1
			continue
		}

		// We are at a '$' — determine token length and variable name.
		token_start := i
		i += 1 // skip '$'

		var_name: string
		token_len: int

		if i < len(path) && path[i] == '{' {
			// ${VAR} syntax — find closing '}'
			i += 1 // skip '{'
			name_start := i
			for i < len(path) && path[i] != '}' {
				i += 1
			}
			var_name = path[name_start:i]
			if i < len(path) {
				i += 1 // skip '}'
			}
			token_len = i - token_start
		} else {
			// $VAR syntax — scan identifier characters
			name_start := i
			for i < len(path) && is_env_var_char(path[i]) {
				i += 1
			}
			var_name = path[name_start:i]
			token_len = i - token_start
		}

		if len(var_name) == 0 {
			// Bare '$' with no identifier — emit as-is
			strings.write_byte(&builder, '$')
			continue
		}

		value := os.get_env(var_name, context.allocator)
		defer delete(value)

		if len(value) > 0 {
			strings.write_string(&builder, value)
		} else {
			if require_resolved {
				return ""
			}
			// Variable not set or empty — preserve original token
			strings.write_string(&builder, path[token_start:token_start + token_len])
		}
	}

	result := strings.clone(strings.to_string(builder))

	// Make the path absolute without resolving symlinks or requiring it to
	// exist (TUI and templates may stage paths before creating directories).
	defer delete(result)
	if filepath.is_abs(result) {
		cleaned, err := filepath.clean(result)
		if err == nil {
			return cleaned
		}
	} else {
		cwd, cwd_err := os.getwd(context.allocator)
		defer delete(cwd)
		if cwd_err == nil {
			joined, err := filepath.join({cwd, result})
			if err == nil {
				return joined
			}
		}
	}
	if require_resolved {
		return ""
	}
	return strings.clone(result)
}

// ============================================================================
// PATH entries in the entry store (entries.json "paths")
// ============================================================================

WAYU_TOML :: "wayu.toml"

// Free the strings of `paths` and the array.
free_store_paths :: proc(paths: ^[dynamic]StorePath) {
	for p in paths {delete(p.key); delete(p.dir)}
	delete(paths^)
}

// The store's PATH entries (key, dir), in order (= PATH priority). Exits
// EXIT_CONFIG when entries.json is malformed. Free with free_store_paths.
path_entries_read :: proc() -> [dynamic]StorePath {
	store := entries_load()
	paths := store.paths
	store.paths = nil
	entries_store_destroy(&store)
	return paths
}

// Just the dirs of path_entries_read, in order. Free with
// `for p in paths { delete(p) }; delete(paths)`.
path_dirs_read :: proc() -> [dynamic]string {
	entries := path_entries_read()
	defer {
		for e in entries {delete(e.key)}
		delete(entries)
	}
	out := make([dynamic]string, 0, len(entries))
	for e in entries {append(&out, e.dir)}
	return out
}

// PATH entries as ConfigEntry values (name = dir). Free with cleanup_entries.
read_path_config_entries :: proc() -> []ConfigEntry {
	dirs := path_dirs_read()
	defer delete(dirs)
	entries := make([]ConfigEntry, len(dirs))
	for d, i in dirs {
		entries[i] = ConfigEntry {
			type = .PATH,
			name = d,
		}
	} // ownership moves
	return entries
}

// Get a PATH entry (exact, or resolved-equal: `$HOME/bin` == `~/bin`).
path_get_value :: proc(search_path: string) {
	if len(strings.trim_space(search_path)) == 0 {
		print_cli_usage_error(&PATH_SPEC, "get")
		os.exit(EXIT_USAGE)
	}
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	paths := path_dirs_read()

	exact_idx := -1
	for path_entry, i in paths {
		if path_entry == search_path {
			exact_idx = i; break
		}
	}
	if exact_idx < 0 {
		for path_entry, i in paths {
			if path_values_equal(path_entry, search_path) {
				exact_idx = i; break
			}
		}
	}
	if exact_idx >= 0 {
		fmt.println(paths[exact_idx])
		for p in paths {delete(p)}
		delete(paths)
		return
	}

	// Exact (or resolved-equal) match only (OKAMI-207).
	exit_get_not_found(&PATH_SPEC, search_path, paths[:])
}

// `wayu path list`: wayu's PATH entries and (with --full) the rest of $PATH.
path_list :: proc() {
	paths := path_dirs_read()
	defer {
		for p in paths {delete(p)}
		delete(paths)
	}

	// Snapshot current PATH for cross-reference
	path_entries := snapshot_path_entries()

	// Build set of wayu-managed paths for fast lookup
	wayu_set := make(map[string]bool)
	defer delete(wayu_set)
	for p in paths {
		wayu_set[p] = true
	}

	if wayu.json_output {
		print_paths_json(paths[:], path_entries[:], wayu_set)
		return
	}

	print_header("PATH (wayu)", PATH_SPEC.icon)
	fmt.println()

	// Count external entries early for later checks
	temp_external_count := 0
	for env_path in path_entries {
		if _, is_wayu := wayu_set[env_path]; !is_wayu {
			temp_external_count += 1
		}
	}

	if len(paths) == 0 && temp_external_count == 0 {
		fmt.printfln("  No paths configured")
		return
	}

	// Build a set of env paths for O(1) lookup instead of O(N×M)
	env_path_set := make(map[string]bool, len(path_entries))
	defer delete(env_path_set)
	for env_path in path_entries {
		env_path_set[env_path] = true
	}

	active_count := 0
	inactive_count := 0
	for p in paths {
		if _, found := env_path_set[p]; found {
			active_count += 1
		} else {
			inactive_count += 1
		}
	}

	external_count := 0
	for env_path in path_entries {
		if _, is_wayu := wayu_set[env_path]; !is_wayu {
			external_count += 1
		}
	}

	fmt.printfln(
		"  %d active · %d inactive · %d external",
		active_count,
		inactive_count,
		external_count,
	)
	fmt.println()

	// Filter based on SOURCE_FILTER.
	// "wayu" shows ALL wayu-managed entries (active + inactive) so users
	// can always see and manage their own config. Hiding inactive wayu
	// entries makes stale paths invisible and only discoverable via --full.
	show_wayu := wayu.source_filter == "all" || wayu.source_filter == "wayu"
	show_external := wayu.source_filter == "all" || wayu.source_filter == "external"
	show_inactive :=
		wayu.source_filter == "all" ||
		wayu.source_filter == "inactive" ||
		wayu.source_filter == "wayu"

	has_multiple_sources := show_external || (show_wayu && show_inactive)
	headers: []string
	if has_multiple_sources {
		headers = []string{"Path", "", "Source"}
	} else {
		headers = []string{"Path", ""}
	}
	path_table := new_table(headers)
	defer table_destroy(&path_table)

	table_style(&path_table, style_foreground(new_style(), "white"))
	table_header_style(&path_table, style_bold(style_foreground(new_style(), "cyan"), true))
	table_border(&path_table, .Normal)

	if show_wayu || show_inactive {
		for p in paths {
			found := p in env_path_set
			if found && !show_wayu {
				continue
			}
			if !found && !show_inactive {
				continue
			}

			status := " "
			if !path_exists_expanded(p) {
				status = "✗"
			}

			if has_multiple_sources {
				source := "wayu"
				if !found {
					source = "wayu (inactive)"
				}
				table_add_row(&path_table, []string{p, status, source})
			} else {
				table_add_row(&path_table, []string{p, status})
			}
		}
	}

	if show_external {
		for env_path in path_entries {
			if _, is_wayu := wayu_set[env_path]; !is_wayu {
				status := " "
				if !os.exists(env_path) {
					status = "✗"
				}
				table_add_row(&path_table, []string{env_path, status, "external"})
			}
		}
	}

	output := table_render(path_table, get_cli_terminal_width())
	defer delete(output)
	fmt.print(output)

	if !show_external && external_count > 0 {
		fmt.printfln(
			"%sPass --full to show %d external entries%s",
			get_muted(),
			external_count,
			RESET,
		)
	}
}

print_paths_json :: proc(paths: []string, path_entries: []string, wayu_set: map[string]bool) {
	fmt.println("{")
	fmt.println("  \"paths\": [")

	show_wayu := wayu.source_filter == "all" || wayu.source_filter == "wayu"
	show_external := wayu.source_filter == "all" || wayu.source_filter == "external"
	show_inactive :=
		wayu.source_filter == "all" ||
		wayu.source_filter == "inactive" ||
		wayu.source_filter == "wayu"

	first_entry := true

	if show_wayu || show_inactive {
		for p in paths {
			found := false
			for env_path in path_entries {
				if env_path == p {
					found = true
					break
				}
			}
			if found && !show_wayu {
				continue
			}
			if !found && !show_inactive {
				continue
			}

			source := found ? "wayu" : "wayu (inactive)"
			exists := path_exists_expanded(p)

			if !first_entry {
				fmt.println(",")
			}
			exists_str := exists ? "true" : "false"
			// Values are JSON-escaped so quotes/backslashes/control chars in a
			// path can't break the document. `{` is a fmt verb opener → %c.
			path_j := json_escape(p); defer delete(path_j)
			src_j := json_escape(source); defer delete(src_j)
			fmt.printf(
				"    %c\"path\": \"%s\", \"source\": \"%s\", \"exists\": %s%c",
				'{',
				path_j,
				src_j,
				exists_str,
				'}',
			)
			first_entry = false
		}
	}

	// External entries (in $PATH, not wayu's): same rows as the table view,
	// so --source external / --full agree with it (OKAMI-239).
	if show_external {
		for env_path in path_entries {
			if _, is_wayu := wayu_set[env_path]; is_wayu {
				continue
			}
			if !first_entry {
				fmt.println(",")
			}
			exists_str := os.exists(env_path) ? "true" : "false"
			path_j := json_escape(env_path); defer delete(path_j)
			fmt.printf(
				"    %c\"path\": \"%s\", \"source\": \"external\", \"exists\": %s%c",
				'{',
				path_j,
				exists_str,
				'}',
			)
			first_entry = false
		}
	}

	if !first_entry {
		fmt.println()
	}
	fmt.println("  ]")
	fmt.println("}")
}

// Store read for a mutation (fresh, no exit): BAD_STORE prints why unless
// `quiet`.
@(private = "file")
path_store_read :: proc(quiet := false) -> (store: EntryStore, res: PathOpResult) {
	s, err, ok := entries_read()
	if !ok {
		if !quiet {
			print_error_simple("%s", err)
		}
		return {}, .BAD_STORE
	}
	return s, .OK
}

// Index of the entry `target` names: key, then exact dir, then resolved dir
// (`wayu path rm ./bin` matches what `wayu path add ./bin` stored). -1 if none.
path_store_match :: proc(paths: []StorePath, target: string) -> int {
	for e, i in paths {
		if e.key == target {
			return i
		}
	}
	for e, i in paths {
		if e.dir == target {
			return i
		}
	}
	for e, i in paths {
		if path_values_equal(e.dir, target) {
			return i
		}
	}
	return -1
}

// Read-only, silent preview of path_add_result: true when the add would
// change the store (not a duplicate, name hint usable). Used to fire
// pre_path_add only for real changes (OKAMI-230); the locked write re-checks.
path_add_would_change :: proc(raw_path: string, name_hint: string = "") -> bool {
	path := expand_env_vars(raw_path, require_resolved = true)
	defer delete(path)
	if len(path) == 0 {
		return false
	}

	store, res := path_store_read(quiet = true)
	if res != .OK {
		return false
	} // the write reports why
	defer entries_store_destroy(&store)
	for e in store.paths {
		if path_values_equal(e.dir, path) {
			return false
		}
	}
	if len(name_hint) > 0 {
		sanitised := sanitize_path_key(name_hint)
		defer if len(sanitised) > 0 {
			delete(sanitised)
		}
		if len(sanitised) == 0 {
			return false
		}
		for e in store.paths {
			if e.key == sanitised {
				return false
			}
		}
	}
	return true
}

// Read-only: the stored dir of the entry path_remove_result would remove for
// `target` (key, exact dir, resolved dir). Caller deletes `path` ("" when
// not found).
path_entry_lookup :: proc(target: string) -> (path: string, found: bool) {
	store, res := path_store_read(quiet = true)
	if res != .OK {
		return "", false
	} // the remove reports why
	defer entries_store_destroy(&store)
	if i := path_store_match(store.paths[:], target); i >= 0 {
		return strings.clone(store.paths[i].dir), true
	}
	return "", false
}

// Add a PATH entry. `name_hint` is optional; when empty a key is derived from
// the basename (`/usr/local/bin` → `local_bin`). The new entry is appended:
// order is PATH precedence (first wins), so existing entries never move and a
// new directory never shadows one the user already has. NOOP when the dir
// (resolved) is already there.
path_add_result :: proc(raw_path: string, name_hint: string = "") -> PathOpResult {
	// Freeze the intended path at every write boundary (CLI, TUI, templates)
	// before duplicate detection or key generation.
	path := expand_env_vars(raw_path, require_resolved = true)
	defer delete(path)
	if len(path) == 0 {
		print_error("Could not resolve path to an absolute path: %s", raw_path)
		return .INVALID
	}

	if !config_lock_acquire() {
		return .IO_ERROR
	}
	defer config_lock_release()

	store, read_res := path_store_read()
	if read_res != .OK {
		return read_res
	}
	defer entries_store_destroy(&store)

	// Compare resolved values so `$HOME/bin` already stored blocks `~/bin`.
	for e in store.paths {
		if path_values_equal(e.dir, path) {
			print_warning("Path already added: %s (key %q)", e.dir, e.key)
			return .NOOP
		}
	}

	taken := make(map[string]bool)
	defer delete(taken)
	for e in store.paths {taken[e.key] = true}

	new_key: string
	if len(name_hint) > 0 {
		sanitised := sanitize_path_key(name_hint)
		defer if len(sanitised) > 0 {
			delete(sanitised)
		}
		if len(sanitised) == 0 {
			print_error("Invalid name %q (must contain alphanumerics)", name_hint)
			return .INVALID
		}
		if sanitised in taken {
			print_error("Name %q is already used by another PATH entry", sanitised)
			return .INVALID
		}
		new_key = strings.clone(sanitised)
	} else {
		new_key = derive_path_key(path, taken)
	}

	if wayu.dry_run {
		defer delete(new_key)
		// The TUI sets print_quiet and shows its own preview.
		if !print_quiet {
			print_header("DRY RUN - No changes will be made", EMOJI_INFO)
			fmt.println()
			fmt.printfln("%sWould add PATH entry: %s = %q%s", BRIGHT_CYAN, new_key, path, RESET)
		}
		return .OK
	}

	append(&store.paths, StorePath{key = new_key, dir = strings.clone(path)}) // the store owns both
	if !entries_save(&store) {
		return .IO_ERROR
	}
	return .OK
}

// Point the entry matching `target` (key, stored dir, or resolved dir — same
// match order as remove) at `raw_path`, in place: the entry keeps its key and
// its position (= PATH precedence). Used by the TUI edit action. NOOP when it
// already holds that path; INVALID when another entry does. Honors --dry-run
// (preview silenced under print_quiet).
path_replace_result :: proc(target, raw_path: string) -> PathOpResult {
	path := expand_env_vars(raw_path, require_resolved = true)
	defer delete(path)
	if len(path) == 0 {
		print_error("Could not resolve path to an absolute path: %s", raw_path)
		return .INVALID
	}

	if !config_lock_acquire() {
		return .IO_ERROR
	}
	defer config_lock_release()

	store, read_res := path_store_read()
	if read_res != .OK {
		return read_res
	}
	defer entries_store_destroy(&store)

	idx := path_store_match(store.paths[:], target)
	if idx < 0 {
		print_error("PATH entry not found: %s", target)
		return .NOT_FOUND
	}
	if store.paths[idx].dir == path {
		return .NOOP
	}
	for e, i in store.paths {
		if i != idx && path_values_equal(e.dir, path) {
			print_error("Path already added: %s (key %q)", e.dir, e.key)
			return .INVALID
		}
	}
	if wayu.dry_run {
		if !print_quiet {
			print_header("DRY RUN - No changes will be made", EMOJI_INFO)
			fmt.printfln(
				"%sWould set PATH entry: %s = %q%s",
				BRIGHT_CYAN,
				store.paths[idx].key,
				path,
				RESET,
			)
		}
		return .OK
	}
	delete(store.paths[idx].dir)
	store.paths[idx].dir = strings.clone(path)
	if !entries_save(&store) {
		return .IO_ERROR
	}
	return .OK
}

// Remove the entry `target` names (key, exact dir, resolved dir).
path_remove_result :: proc(target: string) -> PathOpResult {
	if !config_lock_acquire() {
		return .IO_ERROR
	}
	defer config_lock_release()

	store, read_res := path_store_read()
	if read_res != .OK {
		return read_res
	}
	defer entries_store_destroy(&store)

	idx := path_store_match(store.paths[:], target)
	if idx < 0 {
		print_error("PATH entry not found: %s", target)
		return .NOT_FOUND
	}

	if wayu.dry_run {
		if !print_quiet {
			removed := store.paths[idx]
			print_header("DRY RUN - No changes will be made", EMOJI_INFO)
			fmt.printfln(
				"%sWould remove PATH entry: %s = %q%s",
				BRIGHT_CYAN,
				removed.key,
				removed.dir,
				RESET,
			)
		}
		return .OK
	}

	delete(store.paths[idx].key)
	delete(store.paths[idx].dir)
	ordered_remove(&store.paths, idx)
	if !entries_save(&store) {
		return .IO_ERROR
	}
	return .OK
}

// Drop the entries of `entries` whose `drop[i]` is set (clean/dedup/doctor
// --fix). The store is re-read and entries are matched by key (keys are
// unique), so entries added meanwhile survive. Caller holds the config lock
// and handled --dry-run.
path_store_drop :: proc(entries: []StorePath, drop: []bool) -> PathOpResult {
	store, read_res := path_store_read()
	if read_res != .OK {
		return read_res
	}
	defer entries_store_destroy(&store)

	kept := make([dynamic]StorePath, 0, len(store.paths))
	for e in store.paths {
		gone := false
		for d, i in entries {
			if drop[i] && d.key == e.key {
				gone = true; break
			}
		}
		if gone {
			delete(e.key); delete(e.dir)
		} else {
			append(&kept, e)
		}
	}
	delete(store.paths)
	store.paths = kept
	if !entries_save(&store) {
		return .IO_ERROR
	}
	return .OK
}
