// alias.odin - ALIAS entry management
//
// When wayu.toml exists, aliases become TOML-native. Otherwise we fall back
// to the legacy shell-file implementation.

package wayu

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// Main handler for ALIAS commands.
// For LIST, external alias source sections are still appended.
handle_alias_command :: proc(action: Action, args: []string) {
	toml_file := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG)
	defer delete(toml_file)

	if os.exists(toml_file) {
		#partial switch action {
		case .ADD:
			if len(args) == 0 {
				print_cli_usage_error(&ALIAS_SPEC, "add")
				os.exit(EXIT_USAGE)
			}
			entry := parse_args_to_entry(&ALIAS_SPEC, args)
			defer cleanup_entry(&entry)
			if !is_entry_complete(entry) {
				print_cli_usage_error(&ALIAS_SPEC, "add")
				os.exit(EXIT_USAGE)
			}
			hook_pre_alias_add(entry.name)
			ok, err := toml_alias_add(entry)
			if !ok {
				print_error_simple(err)
				delete(err)
				os.exit(EXIT_DATAERR)
			}
			hook_post_alias_add(entry.name)
			return
		case .REMOVE:
			if len(args) == 0 {
				print_cli_usage_error(&ALIAS_SPEC, "remove")
				os.exit(EXIT_USAGE)
			}
			hook_pre_alias_remove(args[0])
			ok, err := toml_alias_remove(args[0])
			if !ok {
				print_error_simple(err)
				delete(err)
				os.exit(EXIT_DATAERR)
			}
			hook_post_alias_remove(args[0])
			return
		case .LIST:
			list_toml_aliases()
			print_external_alias_sources()
			return
		case .GET:
			if len(args) == 0 {
				print_cli_usage_error(&ALIAS_SPEC, "get")
				os.exit(EXIT_USAGE)
			}
			get_toml_alias_value(args[0])
			return
		case:
		}
	}

	handle_config_command(&ALIAS_SPEC, action, args)

	if action == .LIST {
		print_external_alias_sources()
	}
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
	config_path := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG)
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

		strings.write_string(&builder, "[aliases]\n")
		for entry in entries {
			escaped := escape_toml_string(entry.value)
			fmt.sbprintfln(&builder, "%s = \"%s\"", entry.name, escaped)
			delete(escaped)
		}
		strings.write_string(&builder, "\n")
	}

	new_content := strings.clone(strings.to_string(builder))
	defer delete(new_content)

	if DRY_RUN {
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

		if trimmed == "[aliases]" || trimmed == "[[aliases]]" {
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

	if JSON_OUTPUT {
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
	show_wayu := SOURCE_FILTER == "all" || SOURCE_FILTER == "wayu"
	show_external := SOURCE_FILTER == "all" || SOURCE_FILTER == "external"
	show_inactive := SOURCE_FILTER == "all" || SOURCE_FILTER == "inactive"

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
	show_wayu := SOURCE_FILTER == "all" || SOURCE_FILTER == "wayu"
	show_external := SOURCE_FILTER == "all" || SOURCE_FILTER == "external"
	show_inactive := SOURCE_FILTER == "all" || SOURCE_FILTER == "inactive"

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
			fmt.printf(`    {"alias": "%s", "command": "%s", "source": "%s"}`, entry.name, entry.value, source)
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
				fmt.printf(`    {"alias": "%s", "command": "%s", "source": "external"}`, alias_name, value)
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
