// alias.odin - ALIAS entry management
//
// Aliases are always TOML-native; if wayu.toml is absent we create it.

package wayu
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sort"
// Main handler for ALIAS commands.
//
// Thin delegation to the generic TOML-entry dispatcher. The spec wires up
// toml_alias_add/remove/list/get + per-action hooks + the external-sources
// epilogue on LIST (see ALIAS_SPEC in config_specs.odin). All per-type
// logic lives in toml_alias_* procs below.
handle_alias_command :: proc(action: Action, args: []string) {
	handle_toml_entry_command(&ALIAS_SPEC, action, args)
}

read_toml_alias_entries :: proc() -> []ConfigEntry {
	alias_entries := read_wayu_toml_aliases()
	defer {
		for entry in alias_entries {
			delete(entry.name)
			delete(entry.command)
		}
		delete(alias_entries)
	}

	entries := make([dynamic]ConfigEntry)
	for entry in alias_entries {
		append(&entries, ConfigEntry{
			type = .ALIAS,
			name = strings.clone(entry.name),
			value = strings.clone(entry.command),
			line = fmt.aprintf(`alias %s="%s"`, entry.name, entry.command),
		})
	}

	return entries[:]
}

write_wayu_toml_aliases :: proc(entries: []ConfigEntry) -> bool {
	config_path := fmt.aprintf("%s/wayu.toml", wayu.config)
	defer delete(config_path)

	content, ok := safe_read_file(config_path)
	if !ok { return false }
	defer delete(content)

	base_content := strip_toml_alias_sections(string(content))
	defer delete(base_content)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	if len(base_content) > 0 {
		strings.write_string(&builder, base_content)
	}

	if len(entries) > 0 {
		if len(base_content) > 0 && !strings.has_suffix(base_content, "\n") {
			strings.write_string(&builder, "\n")
		}
		if len(strings.trim_space(base_content)) > 0 {
			strings.write_string(&builder, "\n")
		}

		// Sort alphabetically by name for stable output.
		sorted := make([]ConfigEntry, len(entries))
		defer delete(sorted)
		copy(sorted, entries)
		slice.sort_by(sorted, proc(a, b: ConfigEntry) -> bool { return a.name < b.name })

		strings.write_string(&builder, "[aliases]\n")
		for entry in sorted {
			escaped := escape_toml_string(entry.value)
			fmt.sbprintfln(&builder, "%s = \"%s\"", entry.name, escaped)
			delete(escaped)
		}
		strings.write_string(&builder, "\n")
	}

	new_content := strings.clone(strings.to_string(builder))
	defer delete(new_content)

	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould update wayu.toml aliases:%s", BRIGHT_CYAN, RESET)
		fmt.print(new_content)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return true
	}

	if !create_backup_cli(config_path) { return false }
	return safe_write_file(config_path, transmute([]byte)new_content)
}

strip_toml_alias_sections :: proc(content: string) -> string {
	lines := strings.split(content, "\n")
	defer delete(lines)

	result := make([dynamic]string)
	defer {
		for line in result { delete(line) }
		delete(result)
	}

	skip_section := false
	for line in lines {
		trimmed := strings.trim_space(line)

		if trimmed == "[aliases]" {
			skip_section = true
			continue
		}

		if skip_section && strings.has_prefix(trimmed, "[") {
			skip_section = false
		}

		if skip_section {
			continue
		}

		append(&result, strings.clone(line))
	}

	return strings.join(result[:], "\n")
}

toml_alias_add :: proc(entry: ConfigEntry) -> (bool, string) {
	validation := validate_alias(entry.name, entry.value)
	if !validation.valid {
		err := strings.clone(validation.error_message)
		delete(validation.error_message)
		return false, err
	}

	existing := read_toml_alias_entries()
	defer cleanup_entries(&existing)

	updated := make([dynamic]ConfigEntry)
	defer {
		for &e in updated { cleanup_entry(&e) }
		delete(updated)
	}
	for e in existing {
		append(&updated, ConfigEntry{
			type = e.type,
			name = strings.clone(e.name),
			value = strings.clone(e.value),
			line = strings.clone(e.line),
		})
	}

	had_existing := false
	for e in updated {
		if e.name == entry.name {
			had_existing = true
			break
		}
	}

	for &e in updated {
		if e.name == entry.name {
			delete(e.value)
			e.value = strings.clone(entry.value)
			delete(e.line)
			e.line = fmt.aprintf(`alias %s="%s"`, entry.name, entry.value)
			had_existing = true
			if !write_wayu_toml_aliases(updated[:]) {
				return false, strings.clone("I/O error: could not update wayu.toml")
			}
			print_success("Alias updated successfully in wayu.toml: %s", entry.name)
			return true, ""
		}
	}

	append(&updated, ConfigEntry{
		type = .ALIAS,
		name = strings.clone(entry.name),
		value = strings.clone(entry.value),
		line = fmt.aprintf(`alias %s="%s"`, entry.name, entry.value),
	})

	if !write_wayu_toml_aliases(updated[:]) {
		return false, strings.clone("I/O error: could not update wayu.toml")
	}

	regenerate_init_core_silently()

	if had_existing {
		print_success("Alias updated successfully in wayu.toml: %s", entry.name)
	} else {
		print_success("Alias added successfully to wayu.toml: %s", entry.name)
	}
	return true, ""
}

toml_alias_remove :: proc(name: string) -> (bool, string) {
	existing := read_toml_alias_entries()
	defer cleanup_entries(&existing)

	updated := make([dynamic]ConfigEntry)
	defer {
		for &e in updated { cleanup_entry(&e) }
		delete(updated)
	}

	found := false
	for e in existing {
		if e.name == name {
			found = true
			continue
		}
		append(&updated, ConfigEntry{
			type = e.type,
			name = strings.clone(e.name),
			value = strings.clone(e.value),
			line = strings.clone(e.line),
		})
	}

	if !found {
		return false, fmt.aprintf("Alias not found: %s", name)
	}
	if !write_wayu_toml_aliases(updated[:]) {
		return false, strings.clone("I/O error: could not update wayu.toml")
	}

	regenerate_init_core_silently()

	print_success("Alias removed successfully from wayu.toml: %s", name)
	return true, ""
}

list_toml_aliases :: proc() {
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	entries := read_toml_alias_entries()
	defer cleanup_entries(&entries)

	// Snapshot current aliases for cross-reference
	aliases_env := snapshot_aliases()

	// Build set of wayu-managed aliases for fast lookup
	wayu_set := make(map[string]bool)
	defer delete(wayu_set)
	for entry in entries {
		wayu_set[entry.name] = true
	}

	// Find external aliases (in env but not in wayu.toml)
	external_aliases := make([dynamic]string)
	defer delete(external_aliases)
	for alias_name in aliases_env {
		if _, is_wayu := wayu_set[alias_name]; !is_wayu {
			append(&external_aliases, alias_name)
		}
	}

	if len(entries) == 0 && len(external_aliases) == 0 {
		print_info("No Aliases found")
		return
	}

	if wayu.json_output {
		print_aliases_json(entries[:], external_aliases[:])
		return
	}

	// Count sources
	active_count := 0
	inactive_count := 0
	for entry in entries {
		if _, has := aliases_env[entry.name]; has {
			active_count += 1
		} else {
			inactive_count += 1
		}
	}

	// Print summary
	fmt.printfln("  %d active · %d inactive · %d external", active_count, inactive_count, len(external_aliases))
	fmt.println()

	// Filter based on SOURCE_FILTER
	show_wayu := wayu.source_filter == "all" || wayu.source_filter == "wayu"
	show_external := wayu.source_filter == "all" || wayu.source_filter == "external"
	show_inactive := wayu.source_filter == "all" || wayu.source_filter == "inactive"

	headers := []string{"Alias", "Command", "Source"}
	table := new_table(headers)
	defer table_destroy(&table)

	table_style(&table, style_foreground(new_style(), "white"))
	table_header_style(&table, style_bold(style_foreground(new_style(), "cyan"), true))
	table_border(&table, .Normal)

	// Add wayu entries
	if show_wayu || show_inactive {
		for entry in entries {
			is_active := false
			if _, has := aliases_env[entry.name]; has {
				is_active = true
			}

			// Skip if not matching filter
			if is_active && !show_wayu {
				continue
			}
			if !is_active && !show_inactive {
				continue
			}

			source := "wayu"
			if !is_active {
				source = "wayu (inactive)"
			}
			row := []string{entry.name, entry.value, source}
			table_add_row(&table, row)
		}
	}

	// Add external entries
	if show_external {
		for alias_name in external_aliases {
			if value, has := aliases_env[alias_name]; has {
				row := []string{alias_name, value, "external"}
				table_add_row(&table, row)
			}
		}
	}

	output := table_render(table, get_cli_terminal_width())
	defer delete(output)
	fmt.print(output)
}

print_aliases_json :: proc(entries: []ConfigEntry, external_aliases: []string) {
	aliases_env := snapshot_aliases()

	// Build wayu set for fast lookup
	wayu_set := make(map[string]bool)
	defer delete(wayu_set)
	for entry in entries {
		wayu_set[entry.name] = true
	}

	// Determine if we show different source categories
	show_wayu := wayu.source_filter == "all" || wayu.source_filter == "wayu"
	show_external := wayu.source_filter == "all" || wayu.source_filter == "external"
	show_inactive := wayu.source_filter == "all" || wayu.source_filter == "inactive"

	fmt.println("{")
	fmt.println(`  "aliases": [`)

	first_entry := true

	// Output wayu entries
	if show_wayu || show_inactive {
		for entry, i in entries {
			is_active := false
			if _, has := aliases_env[entry.name]; has {
				is_active = true
			}

			// Skip if not matching filter
			if is_active && !show_wayu {
				continue
			}
			if !is_active && !show_inactive {
				continue
			}

			source := "wayu"
			if !is_active {
				source = "wayu (inactive)"
			}

			if !first_entry {
				fmt.println(",")
			}
			// Odin's fmt treats a literal `{` as a struct-verb opener, so
			// emit braces via %c. Values are JSON-escaped so backslashes,
			// quotes and control chars survive transport.
			name_j := json_escape(entry.name);  defer delete(name_j)
			val_j  := json_escape(entry.value); defer delete(val_j)
			src_j  := json_escape(source);      defer delete(src_j)
			fmt.printf("    %c\"alias\": \"%s\", \"command\": \"%s\", \"source\": \"%s\"%c", '{', name_j, val_j, src_j, '}')
			first_entry = false
		}
	}

	// Output external entries
	if show_external {
		for alias_name in external_aliases {
			if value, has := aliases_env[alias_name]; has {
				if !first_entry {
					fmt.println(",")
				}
				name_j := json_escape(alias_name); defer delete(name_j)
				val_j  := json_escape(value);      defer delete(val_j)
				fmt.printf("    %c\"alias\": \"%s\", \"command\": \"%s\", \"source\": \"external\"%c", '{', name_j, val_j, '}')
				first_entry = false
			}
		}
	}

	fmt.println()
	fmt.println("  ]")
	fmt.println("}")
}

get_toml_alias_value :: proc(name: string) {
	if len(strings.trim_space(name)) == 0 {
		print_cli_usage_error(&ALIAS_SPEC, "get")
		os.exit(EXIT_USAGE)
	}
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	entries := read_toml_alias_entries()

	// Try exact match first
	for entry in entries {
		if entry.name == name {
			fmt.println(entry.value)
			cleanup_entries(&entries)
			return
		}
	}

	// Fuzzy match fallback - do fuzzy matching on entries array directly
	fuzzy_matches := make([dynamic]FuzzyMatch)

	name_lower := strings.to_lower(name)

	for entry in entries {
		score := 0
		match_type := MatchType.Fuzzy

		// Check for exact match
		if strings.equal_fold(entry.name, name) {
			score = 10000
			match_type = .Exact
		} else if strings.has_prefix(strings.to_lower(entry.name), name_lower) {
			// Prefix match
			score = 5000 + fuzzy_score(entry.name, name)
			match_type = .Prefix
		} else if strings.contains(strings.to_lower(entry.name), name_lower) {
			// Substring match
			score = 3000 + fuzzy_score(entry.name, name)
			match_type = .Substring
		} else if is_acronym_match(entry.name, name) {
			// Acronym match
			score = 2000 + fuzzy_score(entry.name, name)
			match_type = .Acronym
		} else {
			// General fuzzy match
			score = fuzzy_score(entry.name, name)
			match_type = .Fuzzy
		}

		if score > 0 {
			append(&fuzzy_matches, FuzzyMatch{
				entry = clone_entry(entry),
				score = score,
				match_type = match_type,
			})
		}
	}

	cleanup_entries(&entries)

	if len(fuzzy_matches) > 0 {
		// Sort by score descending
		slice.sort_by(fuzzy_matches[:], proc(a, b: FuzzyMatch) -> bool {
			return a.score > b.score
		})

		if len(fuzzy_matches) == 1 {
			// Single fuzzy match: print value and exit 0
			fmt.println(fuzzy_matches[0].entry.value)
			// Clean up before returning
			delete(name_lower)
			for match in fuzzy_matches {
				cleanup_clone(match.entry)
			}
			delete(fuzzy_matches)
			return
		} else {
			// Multiple matches: show suggestions and exit with error
			print_fuzzy_suggestions(&ALIAS_SPEC, name, fuzzy_matches[:])
			// Clean up before exit
			delete(name_lower)
			for match in fuzzy_matches {
				cleanup_clone(match.entry)
			}
			delete(fuzzy_matches)
			os.exit(EXIT_DATAERR)
		}
	}

	// No matches at all - clean up
	delete(name_lower)
	for match in fuzzy_matches {
		cleanup_clone(match.entry)
	}
	delete(fuzzy_matches)

	print_error("Alias not found: %s", name)
	os.exit(EXIT_DATAERR)
}
ALIAS_SOURCES_FILE :: "alias-sources.conf"

// Represents one parsed line from alias-sources.conf
AliasSource :: struct {
	label:            string, // human-readable label (derived from path basename)
	path:             string, // expanded directory path
	command_template: string, // e.g. "fabric --pattern {name}"
}

// Read and parse alias-sources.conf. Returns owned slice — caller must call
// cleanup_alias_sources() when done.
read_alias_sources :: proc() -> []AliasSource {
	sources_file := fmt.aprintf("%s/%s", wayu.config, ALIAS_SOURCES_FILE)
	defer delete(sources_file)

	if !os.exists(sources_file) {
		return nil
	}

	data, read_err := os.read_entire_file(sources_file, context.allocator)
	if read_err != nil {
		return nil
	}
	defer delete(data)

	content := string(data)
	lines := strings.split_lines(content)
	defer delete(lines)

	result := make([dynamic]AliasSource)

	for raw_line in lines {
		line := strings.trim_space(raw_line)

		// Skip empty lines and comments
		if len(line) == 0 || strings.has_prefix(line, "#") {
			continue
		}

		// Only "dir" type supported for now
		if !strings.has_prefix(line, "dir ") {
			continue
		}

		// Parse: "dir <path> <command_template...>"
		rest := strings.trim_space(line[4:])
		if len(rest) == 0 {
			continue
		}

		// Split on first space to get path vs template
		space_idx := strings.index(rest, " ")
		if space_idx == -1 {
			continue // no command template — skip
		}

		raw_path := strings.trim_space(rest[:space_idx])
		cmd_template := strings.trim_space(rest[space_idx + 1:])

		if len(raw_path) == 0 || len(cmd_template) == 0 {
			continue
		}

		// Expand ~ in path
		expanded_path := expand_home(raw_path)

		// Derive label from the last path component
		label := path_basename(expanded_path)

		append(&result, AliasSource{
			label            = strings.clone(label),
			path             = expanded_path,
			command_template = strings.clone(cmd_template),
		})
	}

	return result[:]
}

cleanup_alias_sources :: proc(sources: []AliasSource) {
	for s in sources {
		delete(s.label)
		delete(s.path)
		delete(s.command_template)
	}
	delete(sources)
}

// Expand leading ~ to $HOME
expand_home :: proc(p: string) -> string {
	if strings.has_prefix(p, "~/") {
		home := os.get_env("HOME", context.allocator)
		defer delete(home)
		return fmt.aprintf("%s%s", home, p[1:])
	}
	return strings.clone(p)
}

// Return the last path component (basename)
path_basename :: proc(p: string) -> string {
	if len(p) == 0 {
		return p
	}
	// Strip trailing slash
	trimmed := strings.trim_right(p, "/")
	idx := strings.last_index(trimmed, "/")
	if idx == -1 {
		return trimmed
	}
	return trimmed[idx + 1:]
}

// Render one external alias source as a labelled table section.
// Silently skips if the directory doesn't exist.
print_alias_source :: proc(source: AliasSource) {
	if !os.exists(source.path) {
		return
	}

	dir_handle, err := os.open(source.path)
	if err != nil {
		return
	}
	defer os.close(dir_handle)

	file_infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil {
		return
	}
	defer os.file_info_slice_delete(file_infos, context.allocator)

	// Collect non-directory entry names, sorted
	names := make([dynamic]string)
	defer delete(names)

	// Collect names: prefer directories (e.g. fabric patterns), fall back to
	// files if no directories exist (allows flat-file sources too).
	has_dirs := false
	for info in file_infos {
		if info.type == .Directory {
			has_dirs = true
			break
		}
	}

	for info in file_infos {
		if has_dirs {
			// Directory-based source (e.g. fabric patterns): one alias per subdir
			if info.type != .Directory {
				continue
			}
		} else {
			// File-based source: one alias per file
			if info.type == .Directory {
				continue
			}
		}
		append(&names, info.name)
	}

	if len(names) == 0 {
		return
	}

	sort.sort(sort.Interface{
		len  = proc(it: sort.Interface) -> int { return len((cast(^[dynamic]string)it.collection)^) },
		less = proc(it: sort.Interface, i, j: int) -> bool {
			arr := (cast(^[dynamic]string)it.collection)^
			return arr[i] < arr[j]
		},
		swap = proc(it: sort.Interface, i, j: int) {
			arr := cast(^[dynamic]string)it.collection
			arr[i], arr[j] = arr[j], arr[i]
		},
		collection = &names,
	})

	// Print section header: "External: <label> (<path>)  [read-only]"
	fmt.printf("\n%s%sExternal: %s%s %s(%s)%s  %s[read-only]%s\n",
		BOLD, get_secondary(),
		source.label,
		RESET,
		MUTED, source.path, RESET,
		DIM, RESET,
	)
	fmt.println()

	// Build table
	headers := []string{"Alias", "Command"}
	table := new_table(headers)
	defer table_destroy(&table)

	table_style(&table, style_foreground(new_style(), "white"))
	table_header_style(&table, style_bold(style_foreground(new_style(), "cyan"), true))
	table_border(&table, .Normal)

	for name in names {
		cmd, _ := strings.replace(source.command_template, "{name}", name, 1)
		defer delete(cmd)
		row := []string{name, cmd}
		table_add_row(&table, row)
	}

	output := table_render(table, get_cli_terminal_width())
	defer delete(output)
	fmt.print(output)

	fmt.printf("%s  %d aliases  [read-only]%s\n", MUTED, len(names), RESET)
}

// Print all external alias sources. Called from handle_alias_command after
// the managed list is shown.
print_external_alias_sources :: proc() {
	sources := read_alias_sources()
	if sources == nil {
		return
	}
	defer cleanup_alias_sources(sources)

	for source in sources {
		print_alias_source(source)
	}
}
