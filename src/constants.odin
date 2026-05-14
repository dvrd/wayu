// constants.odin - CONSTANTS entry management
//
// Constants are always TOML-native; if wayu.toml is absent we create it.

package wayu

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// Filter out noisy system/shell environment variables that users don't need to see.
is_noisy_env :: proc(name: string) -> bool {
	// macOS / system internal vars (prefix-based)
	if strings.has_prefix(name, "__") { return true }
	if strings.has_prefix(name, "Apple_") { return true }
	if strings.has_prefix(name, "ZELLIJ_") { return true }
	if strings.has_prefix(name, "GHOSTTY_") { return true }
	if strings.has_prefix(name, "LC_") { return true }

	// Common shell / system vars
	noisy := []string{
		"HOME", "PATH", "USER", "SHELL", "LOGNAME", "LANG",
		"PWD", "OLDPWD", "SHLVL", "TERM", "TMPDIR", "_",
		"TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERMINFO",
		"SSH_AUTH_SOCK", "DISPLAY", "COLORTERM", "COMMAND_MODE",
		"XPC_FLAGS", "XPC_SERVICE_NAME",
		"Apple_PubSub_Socket_Render", "SECURITYSESSIONID",
		"WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS",
	}
	for n in noisy {
		if name == n { return true }
	}
	return false
}

// Main handler for CONSTANTS commands.
//
// Thin delegation to the generic TOML-entry dispatcher. The spec wires up
// toml_constant_add/remove/list/get + per-action hooks (see CONSTANTS_SPEC
// in config_specs.odin). wayu.toml is the single source of truth for
// constants; all per-type logic lives in toml_constant_* procs below.
handle_constants_command :: proc(action: Action, args: []string) {
	handle_toml_entry_command(&CONSTANTS_SPEC, action, args)
}

read_wayu_toml_constants :: proc() -> []ConfigEntry {
	config_path := fmt.aprintf("%s/wayu.toml", wayu.config)
	defer delete(config_path)

	content, ok := safe_read_file(config_path)
	if !ok { return {} }
	defer delete(content)

	entries := make([dynamic]ConfigEntry)
	lines := strings.split(string(content), "\n")
	defer delete(lines)

	in_env := false
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "[env]" { in_env = true; continue }
		if strings.has_prefix(trimmed, "[") { in_env = false; continue }
		if !in_env { continue }
		if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") { continue }

		eq_idx := strings.index_byte(trimmed, '=')
		if eq_idx < 1 { continue }

		name := strings.trim_space(trimmed[:eq_idx])
		value := strings.trim_space(trimmed[eq_idx+1:])
		value = strings.trim_prefix(value, `"`)
		value = strings.trim_suffix(value, `"`)
		value = strings.trim_prefix(value, "'")
		value = strings.trim_suffix(value, "'")
		if len(name) == 0 || len(value) == 0 { continue }
		unescaped := unescape_toml_string(value)
		defer delete(unescaped) // upsert clones into the entry; this temporary is ours
		upsert_toml_constant(&entries, name, unescaped)
	}
	return entries[:]
}

upsert_toml_constant :: proc(entries: ^[dynamic]ConfigEntry, name, value: string) {
	for &entry in entries {
		if entry.name == name {
			delete(entry.value)
			entry.value = strings.clone(value)
			delete(entry.line)
			entry.line = fmt.aprintf(`export %s="%s"`, name, value)
			return
		}
	}

	append(entries, ConfigEntry{
		type = .CONSTANT,
		name = strings.clone(name),
		value = strings.clone(value),
		line = fmt.aprintf(`export %s="%s"`, name, value),
	})
}

escape_toml_string :: proc(value: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	for c in value {
		switch c {
		case '\\': strings.write_string(&builder, "\\\\")
		case '"': strings.write_string(&builder, `\"`)
		case '\n': strings.write_string(&builder, `\n`)
		case '\r': strings.write_string(&builder, `\r`)
		case '\t': strings.write_string(&builder, `\t`)
		case: strings.write_rune(&builder, c)
		}
	}

	return strings.clone(strings.to_string(builder))
}

// Unescape TOML escape sequences (inverse of escape_toml_string)
unescape_toml_string :: proc(value: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	i := 0
	for i < len(value) {
		if value[i] == '\\' && i+1 < len(value) {
			switch value[i+1] {
			case '\\': strings.write_rune(&builder, '\\')
			case '"': strings.write_rune(&builder, '"')
			case 'n': strings.write_rune(&builder, '\n')
			case 'r': strings.write_rune(&builder, '\r')
			case 't': strings.write_rune(&builder, '\t')
			case:
				strings.write_rune(&builder, '\\')
				strings.write_rune(&builder, rune(value[i+1]))
			}
			i += 2
		} else {
			strings.write_rune(&builder, rune(value[i]))
			i += 1
		}
	}

	return strings.clone(strings.to_string(builder))
}

strip_toml_constant_sections :: proc(content: string) -> string {
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

		if trimmed == "[env]" {
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

write_wayu_toml_constants :: proc(entries: []ConfigEntry) -> bool {
	config_path := fmt.aprintf("%s/wayu.toml", wayu.config)
	defer delete(config_path)

	content, ok := safe_read_file(config_path)
	if !ok { return false }
	defer delete(content)

	base_content := strip_toml_constant_sections(string(content))
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

		strings.write_string(&builder, "[env]\n")
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
		fmt.printfln("%sWould update wayu.toml constants:%s", BRIGHT_CYAN, RESET)
		fmt.print(new_content)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return true
	}

	if !create_backup_cli(config_path) { return false }
	return safe_write_file(config_path, transmute([]byte)new_content)
}

toml_constant_add :: proc(entry: ConfigEntry) -> (bool, string) {
	validation := validate_constant(entry.name, entry.value)
	if !validation.valid {
		err := strings.clone(validation.error_message)
		delete(validation.error_message)
		return false, err
	}
	if len(validation.warning) > 0 {
		print_warning("%s", validation.warning)
		delete(validation.warning)
	}

	existing := read_wayu_toml_constants()
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
	upsert_toml_constant(&updated, entry.name, entry.value)

	if !write_wayu_toml_constants(updated[:]) {
		return false, strings.clone("I/O error: could not update wayu.toml")
	}

	regenerate_init_core_silently()

	if had_existing {
		print_success("Constant updated successfully in wayu.toml: %s", entry.name)
	} else {
		print_success("Constant added successfully to wayu.toml: %s", entry.name)
	}
	return true, ""
}

toml_constant_remove :: proc(name: string) -> (bool, string) {
	existing := read_wayu_toml_constants()
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
		return false, fmt.aprintf("Constant not found: %s", name)
	}
	if !write_wayu_toml_constants(updated[:]) {
		return false, strings.clone("I/O error: could not update wayu.toml")
	}

	regenerate_init_core_silently()

	print_success("Constant removed successfully from wayu.toml: %s", name)
	return true, ""
}

list_toml_constants :: proc() {
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	entries := read_wayu_toml_constants()
	defer cleanup_entries(&entries)

	// Build set of wayu-managed constants for fast lookup
	wayu_set := make(map[string]bool)
	defer delete(wayu_set)
	for entry in entries {
		wayu_set[entry.name] = true
	}

	// Find external constants (in env but not in wayu.toml)
	external_constants := make([dynamic]string)
	defer delete(external_constants)

	// Get all environment variables
	env_list, env_err := os.environ(context.allocator)
	defer delete(env_list)
	if env_err == nil {
		for pair in env_list {
			parts := strings.split(pair, "=", context.allocator)
			defer delete(parts)
			if len(parts) > 0 {
				const_name := parts[0]
				if _, is_wayu := wayu_set[const_name]; !is_wayu {
					if !is_noisy_env(const_name) {
						append(&external_constants, const_name)
					}
				}
			}
		}
	}

	if len(entries) == 0 && len(external_constants) == 0 {
		print_info("No Constants found")
		return
	}

	if wayu.json_output {
		print_constants_json(entries[:], external_constants[:])
		return
	}

	print_header("Constants (wayu.toml)", CONSTANTS_SPEC.icon)
	fmt.println()

	// Count sources
	active_count := 0
	inactive_count := 0
	for entry in entries {
		env_val := snapshot_env_var(entry.name)
		if env_val != nil {
			active_count += 1
		} else {
			inactive_count += 1
		}
	}

	// Print summary
	fmt.printfln("  %d active · %d inactive · %d external", active_count, inactive_count, len(external_constants))
	fmt.println()

	// Filter based on SOURCE_FILTER
	show_wayu := wayu.source_filter == "all" || wayu.source_filter == "wayu"
	show_external := wayu.source_filter == "all" || wayu.source_filter == "external"
	show_inactive := wayu.source_filter == "all" || wayu.source_filter == "inactive"

	headers := []string{"Constant", "Value", "Source"}
	table := new_table(headers)
	defer table_destroy(&table)

	table_style(&table, style_foreground(new_style(), "white"))
	table_header_style(&table, style_bold(style_foreground(new_style(), "cyan"), true))
	table_border(&table, .Normal)

	// Add wayu entries
	if show_wayu || show_inactive {
		for entry in entries {
			is_active := false
			env_val := snapshot_env_var(entry.name)
			if env_val != nil {
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
		for ext_const_name in external_constants {
			if env_val := snapshot_env_var(ext_const_name); env_val != nil {
				row := []string{ext_const_name, env_val.(string), "external"}
				table_add_row(&table, row)
			}
		}
	}

	table_output := table_render(table, get_cli_terminal_width())
	defer delete(table_output)
	fmt.print(table_output)

	if !show_external && len(external_constants) > 0 {
		fmt.printfln("%sPass --full to show %d external entries%s", get_muted(), len(external_constants), RESET)
	}
}

print_constants_json :: proc(entries: []ConfigEntry, external_constants: []string) {
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
	fmt.println(`  "constants": [`)

	first_entry := true

	// Output wayu entries
	if show_wayu || show_inactive {
		for entry, i in entries {
			is_active := false
			env_val := snapshot_env_var(entry.name)
			if env_val != nil {
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
			name_j := json_escape(entry.name);  defer delete(name_j)
			val_j  := json_escape(entry.value); defer delete(val_j)
			src_j  := json_escape(source);      defer delete(src_j)
			// `{` is a struct-verb opener in Odin's fmt — emit via %c.
			fmt.printf("    %c\"constant\": \"%s\", \"value\": \"%s\", \"source\": \"%s\"%c", '{', name_j, val_j, src_j, '}')
			first_entry = false
		}
	}

	// Output external entries
	if show_external {
		for ext_const_name in external_constants {
			if env_val := snapshot_env_var(ext_const_name); env_val != nil {
				name_j := json_escape(ext_const_name);       defer delete(name_j)
				val_j  := json_escape(env_val.(string));     defer delete(val_j)
				if !first_entry {
					fmt.println(",")
				}
				fmt.printf("    %c\"constant\": \"%s\", \"value\": \"%s\", \"source\": \"external\"%c", '{', name_j, val_j, '}')
				first_entry = false
			}
		}
	}

	fmt.println()
	fmt.println("  ]")
	fmt.println("}")
}

get_toml_constant_value :: proc(name: string) {
	if len(strings.trim_space(name)) == 0 {
		print_cli_usage_error(&CONSTANTS_SPEC, "get")
		os.exit(EXIT_USAGE)
	}
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	entries := read_wayu_toml_constants()

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
			print_fuzzy_suggestions(&CONSTANTS_SPEC, name, fuzzy_matches[:])
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

	print_error("Constant not found: %s", name)
	os.exit(EXIT_DATAERR)
}
