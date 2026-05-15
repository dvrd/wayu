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
			print_error(result.error_message)
			delete(result.error_message)
			os.exit(EXIT_DATAERR)
		}
		expanded := expand_env_vars(raw_path)
		defer delete(expanded)
		if !os.exists(expanded) {
			print_error("Path does not exist: %s", raw_path)
			os.exit(EXIT_NOINPUT)
		}
		hook_pre_path_add(raw_path)
		if toml_path_add(raw_path, name_hint) {
			regenerate_init_core_silently()
			print_success("✅ Added to wayu.toml: %s", raw_path)
			fmt.printfln("   Reload your shell (or 'source ~/.local/share/wayu/init.%s') to apply.", wayu.shell_ext)
			hook_post_path_add(raw_path)
		} else {
			os.exit(EXIT_IOERR)
		}
	case .REMOVE:
		if len(args) == 0 {
			print_error("Usage: wayu path remove <name-or-path>")
			os.exit(EXIT_USAGE)
		}
		hook_pre_path_remove(args[0])
		if toml_path_remove(args[0]) {
			regenerate_init_core_silently()
			print_success("✅ Removed from wayu.toml: %s", args[0])
			fmt.printfln("   Reload your shell (or 'source ~/.local/share/wayu/init.%s') to apply.", wayu.shell_ext)
			hook_post_path_remove(args[0])
		} else {
			os.exit(EXIT_IOERR)
		}
	case .LIST:
		toml_path_list()
	case:
		handle_config_command(&PATH_SPEC, action, args)
	}
}

// ============================================================================
// PATH-specific operations (clean and dedup)
// ============================================================================

// Clean missing paths - remove directories that no longer exist
// ============================================================================
// Shared helper for PATH mutation (clean + dedup)
// ============================================================================
//
// Extracted 2026-04-24 (code review D4). clean_missing_paths and
// remove_duplicate_paths share the identical steps 3-11: empty-set early
// return, dry-run preview, --yes gate, confirmation banner, line-by-line
// filter of the shell config file, backup + write, cleanup. Only the
// verbs/names and the target-set computation differ.

PathMutationSpec :: struct {
	label:             string, // Human-readable "duplicate entries" / "missing directories"
	empty_success_msg: string, // Printed when len(targets) == 0
	header_title:      string, // print_header title on the actual mutation
	header_icon:       string,
	yes_hint_cmd:      string, // Usage line for --yes refusal, e.g. "wayu path clean --yes"
	success_fmt:       string, // Printed on success with the count, e.g. "✅ Removed %d missing ..."
}

// Walk `path.<shell>` line-by-line, drop each line whose parsed entry.name
// appears in `targets` (multiset: duplicate detection consumes each match
// exactly once so later duplicates of the same name survive appropriately).
// Handles all I/O, backup, and user messaging per `spec`.
mutate_path_entries :: proc(spec: PathMutationSpec, targets: []ConfigEntry) {
	if len(targets) == 0 {
		print_success("%s", spec.empty_success_msg)
		return
	}

	// Dry-run preview
	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		print_warning("Would remove %d %s:", len(targets), spec.label)
		for entry in targets {
			fmt.printfln("  - %s", entry.name)
		}
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// --yes gate
	if !wayu.yes_flag {
		print_error("This operation requires confirmation.")
		fmt.println()
		fmt.printfln("Found %d %s to remove:", len(targets), spec.label)
		for entry in targets {
			fmt.printfln("  - %s", entry.name)
		}
		fmt.println()
		fmt.printfln("Add --yes flag to proceed:")
		fmt.printfln("  %s", spec.yes_hint_cmd)
		os.exit(EXIT_USAGE)
	}

	// Confirmation banner
	print_header(spec.header_title, spec.header_icon)
	fmt.println()
	print_warning("Found %d %s to remove:", len(targets), spec.label)
	for entry in targets {
		fmt.printfln("  - %s", entry.name)
	}
	fmt.println()

	// Read shell config file
	config_file := get_config_file_with_fallback(PATH_SPEC.file_name, wayu.shell)
	defer delete(config_file)

	content, read_ok := safe_read_file(config_file)
	if !read_ok { os.exit(EXIT_IOERR) }
	defer delete(content)

	lines := strings.split(string(content), "\n", context.temp_allocator)

	// Multiset of names that still need to be removed. Copying gives us a
	// mutable pool we can consume one-per-match (this matches the previous
	// dedup behaviour: first occurrence survives, later duplicates drop).
	pending_names := make([dynamic]string, 0, len(targets))
	defer {
		for name in pending_names { delete(name) }
		delete(pending_names)
	}
	for entry in targets {
		append(&pending_names, strings.clone(entry.name))
	}

	new_lines := make([dynamic]string)
	defer {
		for line in new_lines { delete(line) }
		delete(new_lines)
	}

	removed_count := 0
	for line in lines {
		entry, ok := PATH_SPEC.parse_line(line)
		if ok {
			defer cleanup_entry(&entry)

			is_target := false
			for i in 0..<len(pending_names) {
				if pending_names[i] == entry.name {
					is_target = true
					removed_count += 1
					delete(pending_names[i])
					last_idx := len(pending_names) - 1
					if i != last_idx {
						pending_names[i] = pending_names[last_idx]
					}
					resize(&pending_names, last_idx)
					break
				}
			}
			if is_target do continue
		}
		append(&new_lines, strings.clone(line))
	}

	// Backup, write, rotate
	if !create_backup_cli(config_file) { os.exit(EXIT_IOERR) }

	new_content := strings.join(new_lines[:], "\n")
	defer delete(new_content)

	if !safe_write_file(config_file, transmute([]byte)new_content) { os.exit(EXIT_IOERR) }

	cleanup_old_backups(config_file, 5)

	print_success(spec.success_fmt, removed_count)
}

clean_missing_paths :: proc() {
	// Check if wayu is initialized first
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	// Read all PATH entries
	entries := read_config_entries(&PATH_SPEC)
	defer cleanup_entries(&entries)

	// Find missing paths
	missing_entries := make([dynamic]ConfigEntry)
	defer {
		for &entry in missing_entries {
			cleanup_entry(&entry)
		}
		delete(missing_entries)
	}

	for entry in entries {
		expanded := expand_env_vars(entry.name)
		defer delete(expanded)

		if !os.exists(expanded) {
			missing_entry := ConfigEntry{
				type = entry.type,
				name = strings.clone(entry.name),
				value = strings.clone(entry.value),
				line = strings.clone(entry.line),
			}
			append(&missing_entries, missing_entry)
		}
	}

	mutate_path_entries(PathMutationSpec{
		label             = "missing directories",
		empty_success_msg = "✅ No missing directories found in PATH",
		header_title      = "Clean Missing PATH Entries",
		header_icon       = "🧹",
		yes_hint_cmd      = "wayu path clean --yes",
		success_fmt       = "✅ Removed %d missing directories from PATH",
	}, missing_entries[:])
}

// Remove duplicate paths
remove_duplicate_paths :: proc() {
	// Check if wayu is initialized first
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	// Read all PATH entries
	entries := read_config_entries(&PATH_SPEC)
	defer cleanup_entries(&entries)

	// Find duplicates by expanding paths
	expanded_paths := make([]string, len(entries))
	defer {
		for path in expanded_paths {
			delete(path)
		}
		delete(expanded_paths)
	}

	for entry, i in entries {
		expanded_paths[i] = expand_env_vars(entry.name)
	}

	// Track which indices are duplicates (keep first, mark rest)
	duplicate_indices := make([dynamic]int)
	defer delete(duplicate_indices)

	for i in 0..<len(expanded_paths) {
		for j in i + 1..<len(expanded_paths) {
			if expanded_paths[i] == expanded_paths[j] {
				append(&duplicate_indices, j)
			}
		}
	}

	// Materialise targets as ConfigEntry clones so mutate_path_entries can
	// own the cleanup pool uniformly (same shape as clean_missing_paths).
	targets := make([dynamic]ConfigEntry, 0, len(duplicate_indices))
	defer {
		for &e in targets { cleanup_entry(&e) }
		delete(targets)
	}
	for idx in duplicate_indices {
		append(&targets, ConfigEntry{
			type  = entries[idx].type,
			name  = strings.clone(entries[idx].name),
			value = strings.clone(entries[idx].value),
			line  = strings.clone(entries[idx].line),
		})
	}

	mutate_path_entries(PathMutationSpec{
		label             = "duplicate entries",
		empty_success_msg = "✅ No duplicate entries found in PATH",
		header_title      = "Remove Duplicate PATH Entries",
		header_icon       = "🔗",
		yes_hint_cmd      = "wayu path dedup --yes",
		success_fmt       = "✅ Removed %d duplicate entries from PATH",
	}, targets[:])
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
// The caller must delete the returned string.
expand_env_vars :: proc(path: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	i := 0
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
			// Variable not set or empty — preserve original token
			strings.write_string(&builder, path[token_start : token_start + token_len])
		}
	}

	result := strings.clone(strings.to_string(builder))

	// Resolve relative paths (., .., ./, ../) and any remaining ~ to absolute.
	abs_path, abs_err := filepath.abs(result, context.allocator)
	if abs_err == nil {
		delete(result)
		result = abs_path
	}

	return result
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
	config_file := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	defer delete(config_file)

	content := must_read_modern_wayu_toml(config_file)
	defer delete(content)

	entries := make([dynamic]TomlPathEntry)
	lines := strings.split(string(content), "\n")
	defer delete(lines)

	in_paths := false
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "[paths]" {
			in_paths = true
			continue
		}
		if strings.has_prefix(trimmed, "[") {
			in_paths = false
			continue
		}
		if !in_paths { continue }
		if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") { continue }

		eq := strings.index_byte(trimmed, '=')
		if eq < 1 { continue }
		key := strings.trim_space(trimmed[:eq])
		val := strings.trim_space(trimmed[eq+1:])
		val = strings.trim_prefix(val, `"`)
		val = strings.trim_suffix(val, `"`)
		if len(key) == 0 || len(val) == 0 { continue }
		unesc := unescape_toml_string(val)
		append(&entries, TomlPathEntry{key = strings.clone(key), path = unesc})
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
			line  = fmt.aprintf("add_to_path \"%s\"", path),
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

	// Try exact match first
	for path_entry in paths {
		if path_entry == search_path {
			fmt.println(path_entry)
			for p in paths {
				delete(p)
			}
			delete(paths)
			return
		}
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

	// Count sources
	active_count := 0
	inactive_count := 0
	for p in paths {
		// Check if path is in current environment
		found := false
		for env_path in path_entries {
			if env_path == p {
				found = true
				break
			}
		}
		if found {
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

	// Filter based on SOURCE_FILTER
	show_wayu := wayu.source_filter == "all" || wayu.source_filter == "wayu"
	show_external := wayu.source_filter == "all" || wayu.source_filter == "external"
	show_inactive := wayu.source_filter == "all" || wayu.source_filter == "inactive"

	// Build table (consistent with alias ls / constants ls)
	headers := []string{"Path", "", "Source"}
	path_table := new_table(headers)
	defer table_destroy(&path_table)

	table_style(&path_table, style_foreground(new_style(), "white"))
	table_header_style(&path_table, style_bold(style_foreground(new_style(), "cyan"), true))
	table_border(&path_table, .Normal)

	// Add wayu entries
	if show_wayu || show_inactive {
		for p in paths {
			// Check if path is in current environment
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

			status := " "
			if !os.exists(p) { status = "✗" }

			source := "wayu"
			if !found { source = "wayu (inactive)" }

			row := []string{p, status, source}
			table_add_row(&path_table, row)
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

	// Determine if we show different source categories
	show_wayu := wayu.source_filter == "all" || wayu.source_filter == "wayu"
	show_external := wayu.source_filter == "all" || wayu.source_filter == "external"
	show_inactive := wayu.source_filter == "all" || wayu.source_filter == "inactive"

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
			exists := os.exists(p)

			if !first_entry {
				fmt.println(",")
			}
			exists_str := exists ? "true" : "false"
			// Build JSON manually to avoid escaping issues
			fmt.print("    {\"path\": \"")
			fmt.print(p)
			fmt.print("\", \"source\": \"")
			fmt.print(source)
			fmt.print("\", \"exists\": ")
			fmt.print(exists_str)
			fmt.print("}")
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
toml_path_add :: proc(path: string, name_hint: string = "") -> bool {
	config_file := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	defer delete(config_file)

	existing := toml_path_read_keyed()
	defer {
		for &e in existing { delete(e.key); delete(e.path) }
		delete(existing)
	}

	for e in existing {
		if e.path == path {
			print_warning("Path already exists in wayu.toml: %s (key %q)", path, e.key)
			return true
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
			return false
		}
		if sanitised in taken {
			print_error("Name %q already used in [paths]", sanitised)
			return false
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

	content, ok := safe_read_file(config_file)
	if !ok { return false }
	defer delete(content)

	new_content := replace_toml_table_section(string(content), "paths", body)
	defer delete(new_content)

	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould add to wayu.toml: %s = %q%s", BRIGHT_CYAN, new_key, path, RESET)
		return true
	}

	if !create_backup_cli(config_file) { return false }
	return safe_write_file(config_file, transmute([]byte)new_content)
}

// Remove a path. `target` matches against either a key (`local_bin`) or a
// raw path value (`/usr/local/bin`). Key match is tried first.
toml_path_remove :: proc(target: string) -> bool {
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

	if match_idx < 0 {
		if wayu.dry_run {
			print_header("DRY RUN - No changes will be made", EMOJI_INFO)
			fmt.printfln("%sWould remove from wayu.toml: %s (not found)%s", BRIGHT_CYAN, target, RESET)
			return true
		}
		print_error("Not found in wayu.toml [paths]: %s", target)
		return false
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

	content, ok := safe_read_file(config_file)
	if !ok { return false }
	defer delete(content)

	new_content := replace_toml_table_section(string(content), "paths", body)
	defer delete(new_content)

	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.printfln("%sWould remove from wayu.toml: %s = %q%s", BRIGHT_CYAN, removed.key, removed.path, RESET)
		return true
	}

	if !create_backup_cli(config_file) { return false }
	return safe_write_file(config_file, transmute([]byte)new_content)
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
