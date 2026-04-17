// constants.odin - CONSTANTS entry management
//
// Shell-file constants still use the generic config_entry system, but when
// ~/.config/wayu/wayu.toml exists we treat it as the source of truth for read
// operations so `wayu const ls/get` reflects declarative config.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// Main handler for CONSTANTS commands.
// When wayu.toml exists it becomes the source of truth for constants.
handle_constants_command :: proc(action: Action, args: []string) {
	toml_file := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG)
	defer delete(toml_file)

	if os.exists(toml_file) {
		#partial switch action {
		case .ADD:
			if len(args) == 0 {
				print_cli_usage_error(&CONSTANTS_SPEC, "add")
				os.exit(EXIT_USAGE)
			}
			entry := parse_args_to_entry(&CONSTANTS_SPEC, args)
			defer cleanup_entry(&entry)
			if !is_entry_complete(entry) {
				print_cli_usage_error(&CONSTANTS_SPEC, "add")
				os.exit(EXIT_USAGE)
			}
			hook_pre_constant_add(entry.name)
			ok, err := toml_constant_add(entry)
			if !ok {
				print_error_simple(err)
				delete(err)
				os.exit(EXIT_DATAERR)
			}
			hook_post_constant_add(entry.name)
			return
		case .REMOVE:
			if len(args) == 0 {
				print_cli_usage_error(&CONSTANTS_SPEC, "remove")
				os.exit(EXIT_USAGE)
			}
			hook_pre_constant_remove(args[0])
			ok, err := toml_constant_remove(args[0])
			if !ok {
				print_error_simple(err)
				delete(err)
				os.exit(EXIT_DATAERR)
			}
			hook_post_constant_remove(args[0])
			return
		case .LIST:
			list_toml_constants()
			return
		case .GET:
			if len(args) == 0 {
				print_cli_usage_error(&CONSTANTS_SPEC, "get")
				os.exit(EXIT_USAGE)
			}
			get_toml_constant_value(args[0])
			return
		case:
		}
	}

	handle_config_command(&CONSTANTS_SPEC, action, args)
}

read_wayu_toml_constants :: proc() -> []ConfigEntry {
	config_path := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG)
	defer delete(config_path)

	content, ok := safe_read_file(config_path)
	if !ok { return {} }
	defer delete(content)

	entries := make([dynamic]ConfigEntry)
	lines := strings.split(string(content), "\n")
	defer delete(lines)

	in_env := false
	in_constants_table := false
	in_constants_array := false
	current_name := ""
	current_value := ""

	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") {
			continue
		}

		if trimmed == "[env]" {
			flush_toml_constant(&entries, &current_name, &current_value)
			in_env = true
			in_constants_table = false
			in_constants_array = false
			continue
		}
		if trimmed == "[constants]" {
			flush_toml_constant(&entries, &current_name, &current_value)
			in_env = false
			in_constants_table = true
			in_constants_array = false
			continue
		}
		if trimmed == "[[constants]]" {
			flush_toml_constant(&entries, &current_name, &current_value)
			in_env = false
			in_constants_table = false
			in_constants_array = true
			continue
		}
		if strings.has_prefix(trimmed, "[") {
			flush_toml_constant(&entries, &current_name, &current_value)
			in_env = false
			in_constants_table = false
			in_constants_array = false
			continue
		}

		eq_idx := strings.index(trimmed, "=")
		if eq_idx < 1 {
			continue
		}

		name := strings.trim_space(trimmed[:eq_idx])
		value := strings.trim_space(trimmed[eq_idx+1:])
		value = strings.trim_prefix(value, `"`)
		value = strings.trim_suffix(value, `"`)
		value = strings.trim_prefix(value, "'")
		value = strings.trim_suffix(value, "'")
		// Unescape TOML escape sequences in the value
		value = unescape_toml_string(value)

		// Add entries from both [env] and [constants] sections
		// Both sections represent wayu-declared environment variables
		if in_env || in_constants_table {
			if len(name) > 0 && len(value) > 0 {
				upsert_toml_constant(&entries, name, value)
			}
			continue
		}

		if in_constants_array {
			switch name {
			case "name":
				current_name = value
			case "value":
				current_value = value
			}
		}
	}

	flush_toml_constant(&entries, &current_name, &current_value)
	return entries[:]
}

flush_toml_constant :: proc(entries: ^[dynamic]ConfigEntry, current_name, current_value: ^string) {
	if len(current_name^) == 0 || len(current_value^) == 0 {
		current_name^ = ""
		current_value^ = ""
		return
	}
	upsert_toml_constant(entries, current_name^, current_value^)
	current_name^ = ""
	current_value^ = ""
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

		// Only skip [constants] and [[constants]], preserve [env]
		if trimmed == "[constants]" || trimmed == "[[constants]]" {
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
	config_path := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG)
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

		strings.write_string(&builder, "[constants]\n")
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
					append(&external_constants, const_name)
				}
			}
		}
	}

	if len(entries) == 0 && len(external_constants) == 0 {
		print_info("No Constants found")
		return
	}

	if JSON_OUTPUT {
		print_constants_json(entries[:], external_constants[:])
		return
	}

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
	show_wayu := SOURCE_FILTER == "all" || SOURCE_FILTER == "wayu"
	show_external := SOURCE_FILTER == "all" || SOURCE_FILTER == "external"
	show_inactive := SOURCE_FILTER == "all" || SOURCE_FILTER == "inactive"

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
}

print_constants_json :: proc(entries: []ConfigEntry, external_constants: []string) {
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
			fmt.printf(`    {"constant": "%s", "value": "%s", "source": "%s"}`, entry.name, entry.value, source)
			first_entry = false
		}
	}

	// Output external entries
	if show_external {
		for ext_const_name in external_constants {
			if env_val := snapshot_env_var(ext_const_name); env_val != nil {
				if !first_entry {
					fmt.println(",")
				}
				fmt.printf(`    {"constant": "%s", "value": "%s", "source": "external"}`, ext_const_name, env_val.(string))
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

	for entry in entries {
		if entry.name == name {
			fmt.println(entry.value)
			cleanup_entries(&entries)
			return
		}
	}

	cleanup_entries(&entries)
	print_error("Constant not found: %s", name)
	os.exit(EXIT_DATAERR)
}
