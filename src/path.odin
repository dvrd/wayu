// path.odin - PATH entry management (refactored to use config_entry abstraction)
//
// This module manages PATH entries using the generic config_entry system.
// It provides PATH-specific functionality like clean and dedup operations.

#+feature dynamic-literals
package wayu

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Outcome of a [paths] mutation. Lets the CLI handler tell a real change
// apart from a no-op (duplicate add) and pick the right exit code.
PathOpResult :: enum {
	OK,        // changed (or, under --dry-run, would change)
	NOOP,      // nothing to do (e.g. path already present)
	NOT_FOUND, // remove target not in [paths]           → EXIT_DATAERR
	INVALID,   // bad input (name hint, ...)             → EXIT_DATAERR
	IO_ERROR,  // read/backup/write failure              → EXIT_IOERR
}

// Main handler for PATH commands.
// wayu.toml is the single source of truth for PATH; we create it if missing.
handle_path_command :: proc(action: Action, args: []string) {
	if !ensure_wayu_toml_exists() {
		print_error_simple("Failed to create wayu.toml")
		os.exit(EXIT_IOERR)
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
		get_toml_path_value(args[0])
	case .ADD:
		if len(args) == 0 {
			print_error("Usage: wayu path add [<name>=]<path>")
			os.exit(EXIT_USAGE)
		}
		name_hint, raw_path, _ := parse_path_arg(args[0])
		entry := ConfigEntry{type = .PATH, name = raw_path, value = "", line = ""}
		result := validate_path_entry(entry)
		if !result.valid {
			print_error("%s", result.error_message)
			delete(result.error_message)
			os.exit(EXIT_DATAERR)
		}
		expanded := expand_env_vars(raw_path, require_resolved = true)
		defer delete(expanded)
		if len(expanded) == 0 {
			print_error("Could not resolve path to an absolute path: %s", raw_path)
			os.exit(EXIT_DATAERR)
		}
		if !os.exists(expanded) {
			print_error("Path does not exist: %s", raw_path)
			os.exit(EXIT_NOINPUT)
		}
		hook_pre_path_add(expanded)
		res := toml_path_add_result(raw_path, name_hint)
		exit_on_path_failure(res)
		// NOOP: already present (warning printed). Dry-run: preview printed.
		// Neither changed anything, so no regen, no success line, no hook.
		if res == .NOOP || wayu.dry_run { return }
		regenerate_init_core_silently()
		print_success("✅ Added to wayu.toml: %s", expanded)
		fmt.printfln("   Reload your shell (or 'source ~/.config/wayu/init.%s') to apply.", wayu.shell_ext)
		hook_post_path_add(expanded)
	case .REMOVE:
		if len(args) == 0 {
			print_error("Usage: wayu path remove <name-or-path>")
			os.exit(EXIT_USAGE)
		}
		hook_pre_path_remove(args[0])
		res := toml_path_remove_result(args[0])
		exit_on_path_failure(res)
		if wayu.dry_run { return }
		regenerate_init_core_silently()
		print_success("✅ Removed from wayu.toml: %s", args[0])
		fmt.printfln("   Reload your shell (or 'source ~/.config/wayu/init.%s') to apply.", wayu.shell_ext)
		hook_post_path_remove(args[0])
	case .LIST:
		toml_path_list()
	case:
		handle_config_command(&PATH_SPEC, action, args)
	}
}

// Exit with the code matching a failed PathOpResult; returns for OK/NOOP.
@(private = "file")
exit_on_path_failure :: proc(res: PathOpResult) {
	#partial switch res {
	case .NOT_FOUND, .INVALID: os.exit(EXIT_DATAERR)
	case .IO_ERROR:            os.exit(EXIT_IOERR)
	}
}

// ============================================================================
// PATH-specific operations (clean and dedup)
// ============================================================================
//
// Both operate on wayu.toml's [paths] table (the single source of truth):
// compute the set of entries to drop, then share one mutation tail —
// empty-set early return, --dry-run preview, --yes gate, backup + rewrite of
// [paths] via replace_toml_table_section, init regeneration.

PathMutationSpec :: struct {
	label:             string, // Human-readable "duplicate entries" / "missing directories"
	empty_success_msg: string, // Printed when nothing is to be removed
	header_title:      string, // print_header title on the actual mutation
	header_icon:       string,
	yes_hint_cmd:      string, // Usage line for --yes refusal, e.g. "wayu path clean --yes"
	success_fmt:       string, // Printed on success with the count, e.g. "✅ Removed %d missing ..."
}

// Drop every `entries[i]` with `drop[i] == true` from [paths]. Handles
// preview, confirmation, backup, write and regeneration per `spec`.
mutate_path_entries :: proc(spec: PathMutationSpec, entries: []TomlPathEntry, drop: []bool) {
	assert(len(entries) == len(drop))
	count := 0
	for d in drop { if d { count += 1 } }

	if count == 0 {
		print_success("%s", spec.empty_success_msg)
		return
	}

	print_targets :: proc(entries: []TomlPathEntry, drop: []bool) {
		for e, i in entries {
			if drop[i] { fmt.printfln("  - %s = %s", e.key, e.path) }
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

	kept := make([dynamic]TomlPathEntry, 0, len(entries))
	defer delete(kept)
	for e, i in entries {
		if !drop[i] { append(&kept, e) }
	}
	slice_sort_path_entries(kept[:])
	body := render_keyed_body(kept[:])
	defer { for s in body { delete(s) }; delete(body) }

	config_file := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	defer delete(config_file)

	content, read_ok := safe_read_file(config_file)
	if !read_ok { os.exit(EXIT_IOERR) }
	defer delete(content)

	new_content := replace_toml_table_section(string(content), "paths", body)
	defer delete(new_content)

	if !create_backup_cli(config_file) { os.exit(EXIT_IOERR) }
	if !safe_write_file(config_file, transmute([]byte)new_content) { os.exit(EXIT_IOERR) }
	clear_toml_content_cache()
	cleanup_old_backups(config_file, 5)

	regenerate_init_core_silently()
	print_success(spec.success_fmt, count)
}

@(private = "file")
free_toml_path_entries :: proc(entries: ^[dynamic]TomlPathEntry) {
	for &e in entries { delete(e.key); delete(e.path) }
	delete(entries^)
}

// Clean missing paths - remove [paths] entries whose directory no longer
// exists. Stored values are expanded ($HOME, ${VAR}, ~) before the check.
clean_missing_paths :: proc() {
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	entries := toml_path_read_keyed()
	defer free_toml_path_entries(&entries)

	drop := make([]bool, len(entries))
	defer delete(drop)
	for e, i in entries {
		expanded := expand_env_vars(e.path)
		defer delete(expanded)
		drop[i] = !os.exists(expanded)
	}

	mutate_path_entries(PathMutationSpec{
		label             = "missing directories",
		empty_success_msg = "✅ No missing directories found in PATH",
		header_title      = "Clean Missing PATH Entries",
		header_icon       = "🧹",
		yes_hint_cmd      = "wayu path clean --yes",
		success_fmt       = "✅ Removed %d missing directories from PATH",
	}, entries[:], drop)
}

// Remove duplicate paths - entries that resolve to the same directory after
// expansion (`$HOME/bin` == `~/bin` == `/Users/me/bin`). The first entry in
// declaration order survives; later duplicates are dropped.
remove_duplicate_paths :: proc() {
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	entries := toml_path_read_keyed()
	defer free_toml_path_entries(&entries)

	expanded := make([]string, len(entries))
	defer {
		for p in expanded { delete(p) }
		delete(expanded)
	}
	for e, i in entries {
		expanded[i] = expand_env_vars(e.path)
	}

	seen := make(map[string]bool)
	defer delete(seen)
	drop := make([]bool, len(entries))
	defer delete(drop)
	for p, i in expanded {
		if p in seen { drop[i] = true } else { seen[p] = true }
	}

	mutate_path_entries(PathMutationSpec{
		label             = "duplicate entries",
		empty_success_msg = "✅ No duplicate entries found in PATH",
		header_title      = "Remove Duplicate PATH Entries",
		header_icon       = "🔗",
		yes_hint_cmd      = "wayu path dedup --yes",
		success_fmt       = "✅ Removed %d duplicate entries from PATH",
	}, entries[:], drop)
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
	if a == b { return true }
	ea := expand_env_vars(a, require_resolved = true)
	defer delete(ea)
	if len(ea) == 0 { return false }
	eb := expand_env_vars(b, require_resolved = true)
	defer delete(eb)
	return ea == eb
}

// ============================================================================
// PATH-specific helpers
// ============================================================================

// Extract PATH items as a list of strings (for backward compatibility with old code)
extract_path_items :: proc() -> []string {
	entries := read_config_entries(&PATH_SPEC)
	defer cleanup_entries(&entries)

	items := make([]string, len(entries))
	for entry, i in entries {
		items[i] = strings.clone(entry.name)
	}

	return items
}

// is_env_var_char returns true for characters valid in a shell identifier:
// A-Z, a-z, 0-9, underscore.
@(private="file")
is_env_var_char :: proc(c: byte) -> bool {
	return (c >= 'A' && c <= 'Z') ||
	       (c >= 'a' && c <= 'z') ||
	       (c >= '0' && c <= '9') ||
	       c == '_'
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
			if require_resolved { return "" }
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
			if require_resolved { return "" }
			// Variable not set or empty — preserve original token
			strings.write_string(&builder, path[token_start : token_start + token_len])
		}
	}

	result := strings.clone(strings.to_string(builder))

	// Make the path absolute without resolving symlinks or requiring it to
	// exist (TUI and templates may stage paths before creating directories).
	defer delete(result)
	if filepath.is_abs(result) {
		cleaned, err := filepath.clean(result)
		if err == nil { return cleaned }
	} else {
		cwd, cwd_err := os.getwd(context.allocator)
		defer delete(cwd)
		if cwd_err == nil {
			joined, err := filepath.join({cwd, result})
			if err == nil { return joined }
		}
	}
	if require_resolved { return "" }
	return strings.clone(result)
}

// ============================================================================
// wayu.toml PATH operations
// ============================================================================

WAYU_TOML :: "wayu.toml"

// TomlPathEntry is a (key, value) pair from the [paths] table in wayu.toml.
// (Distinct from output.odin's PathEntry which models a $PATH directory.)
TomlPathEntry :: struct {
	key:  string,
	path: string,
}

// Read [paths] table. Aborts (with a migrate-hint) if the file uses the
// obsolete [[paths]] schema. Caller frees each entry's strings + the slice.
toml_path_read_keyed :: proc() -> [dynamic]TomlPathEntry {
	// Use the shared TOML content cache when available (avoids re-reading
	// the file that enforce_modern_wayu_toml_or_exit already read).
	content_str, cached := get_cached_toml_content()
	uncached_content: []byte
	if !cached {
		config_file := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
		defer delete(config_file)
		uncached_content = must_read_modern_wayu_toml(config_file)
		content_str = string(uncached_content)
	}
	defer if len(uncached_content) > 0 { delete(uncached_content) }

	entries := make([dynamic]TomlPathEntry)

	it := make_line_iter(content_str)
	in_paths := false
	for line in line_iter_next(&it) {
		trimmed := strings.trim_space(line)
		if toml_line_is_section(trimmed, "paths") {
			in_paths = true
			continue
		}
		if strings.has_prefix(trimmed, "[") {
			in_paths = false
			continue
		}
		if !in_paths { continue }

		key, val, ok := toml_parse_kv_line(trimmed)
		if !ok { continue }
		if len(val) == 0 { delete(val); continue } // an empty PATH entry is meaningless
		append(&entries, TomlPathEntry{key = strings.clone(key), path = val})
	}
	return entries
}

// Convenience: returns just the path values, in declaration order. Free with
// `for p in paths { delete(p) }; delete(paths)`.
toml_path_read :: proc() -> [dynamic]string {
	entries := toml_path_read_keyed()
	defer {
		for &e in entries { delete(e.key) }
		delete(entries)
	}
	out := make([dynamic]string)
	for e in entries { append(&out, e.path) }
	return out
}

// read_toml_path_entries - Read PATH entries from TOML as ConfigEntry array
read_toml_path_entries :: proc() -> [dynamic]ConfigEntry {
	paths := toml_path_read()
	defer {
		for p in paths { delete(p) }
		delete(paths)
	}

	entries := make([dynamic]ConfigEntry)
	for path in paths {
		append(&entries, ConfigEntry{
			type  = .PATH,
			name  = strings.clone(path),
			value = "",
			line  = "",  // Only populated on-demand by write paths
		})
	}

	return entries
}

// Get a specific PATH entry from TOML with fuzzy matching fallback
get_toml_path_value :: proc(search_path: string) {
	if len(strings.trim_space(search_path)) == 0 {
		print_cli_usage_error(&PATH_SPEC, "get")
		os.exit(EXIT_USAGE)
	}
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	paths := toml_path_read()

	// Try exact match first, then a resolved match ($HOME/bin == ~/bin).
	exact_idx := -1
	for path_entry, i in paths {
		if path_entry == search_path { exact_idx = i; break }
	}
	if exact_idx < 0 {
		for path_entry, i in paths {
			if path_values_equal(path_entry, search_path) { exact_idx = i; break }
		}
	}
	if exact_idx >= 0 {
		fmt.println(paths[exact_idx])
		for p in paths {
			delete(p)
		}
		delete(paths)
		return
	}

	// Fuzzy match fallback
	fuzzy_matches := make([dynamic]FuzzyMatch)

	search_lower := strings.to_lower(search_path)

	for path_entry in paths {
		score := 0
		match_type := MatchType.Fuzzy

		// Check for exact match
		if strings.equal_fold(path_entry, search_path) {
			score = 10000
			match_type = .Exact
		} else if strings.has_prefix(strings.to_lower(path_entry), search_lower) {
			// Prefix match
			score = 5000 + fuzzy_score(path_entry, search_path)
			match_type = .Prefix
		} else if strings.contains(strings.to_lower(path_entry), search_lower) {
			// Substring match
			score = 3000 + fuzzy_score(path_entry, search_path)
			match_type = .Substring
		} else if is_acronym_match(path_entry, search_path) {
			// Acronym match
			score = 2000 + fuzzy_score(path_entry, search_path)
			match_type = .Acronym
		} else {
			// General fuzzy match
			score = fuzzy_score(path_entry, search_path)
			match_type = .Fuzzy
		}

		if score > 0 {
			// For PATH entries, create a ConfigEntry with the path as name
			entry := ConfigEntry{
				type = .PATH,
				name = strings.clone(path_entry),
				value = "",
				line = "",
			}
			append(&fuzzy_matches, FuzzyMatch{
				entry = entry,
				score = score,
				match_type = match_type,
			})
		}
	}

	if len(fuzzy_matches) > 0 {
		// Sort by score descending
		slice.sort_by(fuzzy_matches[:], proc(a, b: FuzzyMatch) -> bool {
			return a.score > b.score
		})

		if len(fuzzy_matches) == 1 {
			// Single fuzzy match: print path and exit 0
			fmt.println(fuzzy_matches[0].entry.name)
			// Clean up
			delete(search_lower)
			for match in fuzzy_matches {
				cleanup_clone(match.entry)
			}
			delete(fuzzy_matches)
			for p in paths {
				delete(p)
			}
			delete(paths)
			return
		} else {
			// Multiple matches: show suggestions and exit with error
			print_fuzzy_suggestions(&PATH_SPEC, search_path, fuzzy_matches[:])
			// Clean up before exit
			delete(search_lower)
			for match in fuzzy_matches {
				cleanup_clone(match.entry)
			}
			delete(fuzzy_matches)
			for p in paths {
				delete(p)
			}
			delete(paths)
			os.exit(EXIT_DATAERR)
		}
	}

	// No matches at all - clean up
	delete(search_lower)
	for match in fuzzy_matches {
		cleanup_clone(match.entry)
	}
	delete(fuzzy_matches)
	for p in paths {
		delete(p)
	}
	delete(paths)

	print_error("PATH not found: %s", search_path)
	os.exit(EXIT_DATAERR)
}

// Lista los paths de wayu.toml en stdout
toml_path_list :: proc() {
	paths := toml_path_read()
	defer {
		for p in paths { delete(p) }
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
		// JSON output: only include wayu entries for now (external JSON support deferred)
		print_paths_json(paths[:], path_entries[:], wayu_set)
		return
	}

	print_header("PATH (wayu.toml)", PATH_SPEC.icon)
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

	// Count sources
	active_count := 0
	inactive_count := 0
	for p in paths {
		if _, found := env_path_set[p]; found {
			active_count += 1
		} else {
			inactive_count += 1
		}
	}

	// Count external entries
	external_count := 0
	for env_path in path_entries {
		if _, is_wayu := wayu_set[env_path]; !is_wayu {
			external_count += 1
		}
	}

	// Print summary with external count
	fmt.printfln("  %d active · %d inactive · %d external", active_count, inactive_count, external_count)
	fmt.println()

	// Filter based on SOURCE_FILTER.
	// "wayu" shows ALL wayu-managed entries (active + inactive) so users
	// can always see and manage their own config. Hiding inactive wayu
	// entries makes stale paths invisible and only discoverable via --full.
	show_wayu := wayu.source_filter == "all" || wayu.source_filter == "wayu"
	show_external := wayu.source_filter == "all" || wayu.source_filter == "external"
	show_inactive := wayu.source_filter == "all" || wayu.source_filter == "inactive" || wayu.source_filter == "wayu"

	// Build table: only show Source column when multiple sources are visible
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

	// Add wayu entries
	if show_wayu || show_inactive {
		for p in paths {
			// O(1) lookup using env_path_set built above
			found := p in env_path_set

			// Skip if not matching filter
			if found && !show_wayu {
				continue
			}
			if !found && !show_inactive {
				continue
			}

			status := " "
			if !path_exists_expanded(p) { status = "✗" }

			if has_multiple_sources {
				source := "wayu"
				if !found { source = "wayu (inactive)" }
				row := []string{p, status, source}
				table_add_row(&path_table, row)
			} else {
				row := []string{p, status}
				table_add_row(&path_table, row)
			}
		}
	}

	// Add external entries
	if show_external {
		for env_path in path_entries {
			if _, is_wayu := wayu_set[env_path]; !is_wayu {
				status := " "
				if !os.exists(env_path) { status = "✗" }
				row := []string{env_path, status, "external"}
				table_add_row(&path_table, row)
			}
		}
	}

	output := table_render(path_table, get_cli_terminal_width())
	defer delete(output)
	fmt.print(output)

	if !show_external && external_count > 0 {
		fmt.printfln("%sPass --full to show %d external entries%s", get_muted(), external_count, RESET)
	}
}

print_paths_json :: proc(paths: []string, path_entries: []string, wayu_set: map[string]bool) {
	fmt.println("{")
	fmt.println("  \"paths\": [")

	// Determine if we show different source categories (same logic as table view)
	show_wayu := wayu.source_filter == "all" || wayu.source_filter == "wayu"
	show_external := wayu.source_filter == "all" || wayu.source_filter == "external"
	show_inactive := wayu.source_filter == "all" || wayu.source_filter == "inactive" || wayu.source_filter == "wayu"

	first_entry := true

	// Output wayu entries
	if show_wayu || show_inactive {
		for p in paths {
			found := false
			for env_path in path_entries {
				if env_path == p {
					found = true
					break
				}
			}

			// Skip if not matching filter
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
			path_j := json_escape(p);      defer delete(path_j)
			src_j  := json_escape(source); defer delete(src_j)
			fmt.printf("    %c\"path\": \"%s\", \"source\": \"%s\", \"exists\": %s%c", '{', path_j, src_j, exists_str, '}')
			first_entry = false
		}
	}

	fmt.println()
	fmt.println("  ]")
	fmt.println("}")
}

// Add a path to wayu.toml's [paths] table. `name_hint` is optional; when
// empty we derive a key from the basename (`/usr/local/bin` → `local_bin`).
// Existing path values are preserved; the [paths] table is rewritten
// alphabetically by key.
//
// Compatibility wrapper: true when the path is (or would be, under
// --dry-run) present afterwards. Use toml_path_add_result to distinguish a
// real change from a duplicate no-op.
toml_path_add :: proc(raw_path: string, name_hint: string = "") -> bool {
	res := toml_path_add_result(raw_path, name_hint)
	return res == .OK || res == .NOOP
}

toml_path_add_result :: proc(raw_path: string, name_hint: string = "") -> PathOpResult {
	// Freeze the intended path at every write boundary (CLI, TUI, templates,
	// migration), before duplicate detection or key generation.
	path := expand_env_vars(raw_path, require_resolved = true)
	defer delete(path)
	if len(path) == 0 {
		print_error("Could not resolve path to an absolute path: %s", raw_path)
		return .INVALID
	}

	config_file := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	defer delete(config_file)

	existing := toml_path_read_keyed()
	defer {
		for &e in existing { delete(e.key); delete(e.path) }
		delete(existing)
	}

	// Compare resolved values so `$HOME/bin` already stored blocks `~/bin`.
	for e in existing {
		if path_values_equal(e.path, path) {
			print_warning("Path already exists in wayu.toml: %s (key %q)", e.path, e.key)
			return .NOOP
		}
	}

	taken := make(map[string]bool)
	defer delete(taken)
	for e in existing { taken[e.key] = true }

	new_key: string
	if len(name_hint) > 0 {
		sanitised := sanitize_path_key(name_hint)
		defer if len(sanitised) > 0 { delete(sanitised) }
		if len(sanitised) == 0 {
			print_error("Invalid name %q (must contain alphanumerics)", name_hint)
			return .INVALID
		}
		if sanitised in taken {
			print_error("Name %q already used in [paths]", sanitised)
			return .INVALID
		}
		new_key = strings.clone(sanitised)
	} else {
		new_key = derive_path_key(path, taken)
	}
	defer delete(new_key)

	// Build sorted body (existing entries + the new one).
	combined := make([dynamic]TomlPathEntry, 0, len(existing) + 1)
	defer delete(combined)
	for e in existing { append(&combined, e) }
	append(&combined, TomlPathEntry{key = new_key, path = path})

	slice_sort_path_entries(combined[:])
	body := render_keyed_body(combined[:])
	defer { for s in body { delete(s) }; delete(body) }

	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould add to wayu.toml: %s = %q%s", BRIGHT_CYAN, new_key, path, RESET)
		return .OK
	}

	return write_paths_body(config_file, body)
}

// Splice `body` into [paths], back up and write. Invalidates the shared TOML
// cache so subsequent in-process reads see the new content.
@(private = "file")
write_paths_body :: proc(config_file: string, body: []string) -> PathOpResult {
	content, ok := safe_read_file(config_file)
	if !ok { return .IO_ERROR }
	defer delete(content)

	new_content := replace_toml_table_section(string(content), "paths", body)
	defer delete(new_content)

	if !create_backup_cli(config_file) { return .IO_ERROR }
	if !safe_write_file(config_file, transmute([]byte)new_content) { return .IO_ERROR }
	clear_toml_content_cache()
	return .OK
}

// Remove a path. `target` matches against either a key (`local_bin`) or a
// path value (`/usr/local/bin`). Key match is tried first, then an exact
// value match, then a resolved match (`~/bin` removes a stored `$HOME/bin`).
//
// Compatibility wrapper: true only when an entry was (or, under --dry-run,
// would be) removed.
toml_path_remove :: proc(target: string) -> bool {
	return toml_path_remove_result(target) == .OK
}

toml_path_remove_result :: proc(target: string) -> PathOpResult {
	config_file := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	defer delete(config_file)

	existing := toml_path_read_keyed()
	defer {
		for &e in existing { delete(e.key); delete(e.path) }
		delete(existing)
	}

	match_idx := -1
	for e, i in existing {
		if e.key == target { match_idx = i; break }
	}
	if match_idx < 0 {
		for e, i in existing {
			if e.path == target { match_idx = i; break }
		}
	}
	// Resolve the target the same way toml_path_add does (~, $VAR, relative →
	// absolute) so `wayu path rm ./bin` matches what `wayu path add ./bin` stored.
	// Stored values are expanded too, covering legacy unexpanded entries.
	if match_idx < 0 {
		for e, i in existing {
			if path_values_equal(e.path, target) { match_idx = i; break }
		}
	}

	if match_idx < 0 {
		print_error("Not found in wayu.toml [paths]: %s", target)
		return .NOT_FOUND
	}

	removed := existing[match_idx]
	kept := make([dynamic]TomlPathEntry, 0, len(existing) - 1)
	defer delete(kept)
	for e, i in existing {
		if i == match_idx { continue }
		append(&kept, e)
	}
	slice_sort_path_entries(kept[:])
	body := render_keyed_body(kept[:])
	defer { for s in body { delete(s) }; delete(body) }

	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.printfln("%sWould remove from wayu.toml: %s = %q%s", BRIGHT_CYAN, removed.key, removed.path, RESET)
		return .OK
	}

	return write_paths_body(config_file, body)
}

// Insertion-sort a small slice of TomlPathEntry by key. We want stable, no deps.
slice_sort_path_entries :: proc(s: []TomlPathEntry) {
	for i := 1; i < len(s); i += 1 {
		j := i
		for j > 0 && s[j-1].key > s[j].key {
			s[j-1], s[j] = s[j], s[j-1]
			j -= 1
		}
	}
}

// Render `entries` as `key = "value"` lines. The path value is escaped so
// pathological inputs (`"`, `\`, newlines) can't inject TOML structure.
// Caller frees each line + slice.
render_keyed_body :: proc(entries: []TomlPathEntry) -> []string {
	out := make([]string, len(entries))
	for e, i in entries {
		escaped := escape_toml_string(e.path)
		out[i] = fmt.aprintf(`%s = "%s"`, e.key, escaped)
		delete(escaped)
	}
	return out
}
