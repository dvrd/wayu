// constants.odin - CONSTANTS entry management
//
// Constants are always TOML-native; if wayu.toml is absent we create it.

package wayu

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

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
	// Use cached TOML content when available (populated by main pre-dispatch)
	content_str, cached := get_cached_toml_content()
	uncached_raw: []byte
	if !cached {
		config_path := fmt.aprintf("%s/wayu.toml", wayu.config)
		defer delete(config_path)
		ok: bool
		uncached_raw, ok = safe_read_file(config_path)
		if !ok { return {} }
		content_str = string(uncached_raw)
	}
	defer if len(uncached_raw) > 0 { delete(uncached_raw) }

	// Shared parser (toml_read_section). Empty values (`FOO = ""`) are kept
	// so a later rewrite of [env] doesn't silently drop them.
	kvs := toml_read_section(content_str, "env")
	defer destroy_toml_kvs(&kvs)
	entries := make([dynamic]ConfigEntry)
	for kv in kvs {
		upsert_toml_constant(&entries, kv.key, kv.value)
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

	// Byte-wise: UTF-8 (even invalid UTF-8) is copied verbatim. Other
	// control characters are not allowed raw in a TOML basic string.
	for i in 0..<len(value) {
		c := value[i]
		switch c {
		case '\\': strings.write_string(&builder, "\\\\")
		case '"': strings.write_string(&builder, `\"`)
		case '\n': strings.write_string(&builder, `\n`)
		case '\r': strings.write_string(&builder, `\r`)
		case '\t': strings.write_string(&builder, `\t`)
		case 0x00..=0x1f, 0x7f: fmt.sbprintf(&builder, `\u%04X`, c)
		case: strings.write_byte(&builder, c)
		}
	}

	return strings.clone(strings.to_string(builder))
}

// Unescape TOML escape sequences (inverse of escape_toml_string)
unescape_toml_string :: proc(value: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// Work byte-wise and copy bytes verbatim: multi-byte UTF-8 sequences must
	// pass through untouched (write_rune(rune(b)) would re-encode each byte as
	// its own code point, turning `é` into `Ã©`).
	i := 0
	for i < len(value) {
		if value[i] == '\\' && i+1 < len(value) {
			switch value[i+1] {
			case '\\': strings.write_byte(&builder, '\\')
			case '"': strings.write_byte(&builder, '"')
			case 'n': strings.write_byte(&builder, '\n')
			case 'r': strings.write_byte(&builder, '\r')
			case 't': strings.write_byte(&builder, '\t')
			case 'b': strings.write_byte(&builder, '\b')
			case 'f': strings.write_byte(&builder, '\f')
			case 'u', 'U':
				// \uXXXX / \UXXXXXXXX → UTF-8. Malformed sequences are kept literally.
				width := 4 if value[i+1] == 'u' else 8
				if cp, ok := parse_hex_codepoint(value, i+2, width); ok {
					strings.write_rune(&builder, cp)
					i += 2 + width
					continue
				}
				strings.write_byte(&builder, '\\')
				strings.write_byte(&builder, value[i+1])
			case:
				strings.write_byte(&builder, '\\')
				strings.write_byte(&builder, value[i+1])
			}
			i += 2
		} else {
			strings.write_byte(&builder, value[i])
			i += 1
		}
	}

	return strings.clone(strings.to_string(builder))
}

// Parse `width` hex digits of value starting at `start` into a valid Unicode
// scalar value (surrogates and out-of-range values are rejected).
@(private = "file")
parse_hex_codepoint :: proc(value: string, start, width: int) -> (rune, bool) {
	if start + width > len(value) { return 0, false }
	cp: u32 = 0
	for j in start..<start+width {
		c := value[j]
		d: u32
		switch c {
		case '0'..='9': d = u32(c - '0')
		case 'a'..='f': d = u32(c - 'a' + 10)
		case 'A'..='F': d = u32(c - 'A' + 10)
		case: return 0, false
		}
		cp = cp * 16 + d
	}
	if cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) { return 0, false }
	return rune(cp), true
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
	// Edits only this constant's line in [env] (see toml_kv_upsert).
	return toml_entry_upsert(entry.name, entry.value, "Constant", "env", "constants")
}

toml_constant_remove :: proc(name: string) -> (bool, string) {
	return toml_entry_remove(name, "Constant", "env", "constants")
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

	// Get all environment variables (zero-alloc name extraction)
	env_list, env_err := os.environ(context.allocator)
	defer delete(env_list)
	if env_err == nil {
		for pair in env_list {
			eq := strings.index_byte(pair, '=')
			const_name := pair[:eq] if eq > 0 else pair
			if len(const_name) > 0 {
				if _, seen := wayu_set[const_name]; !seen {
					append(&external_constants, const_name)
					// os.environ can repeat a name (Odin's posix _environ returns
					// environ[0] twice); list each variable once.
					wayu_set[const_name] = true
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

	// Filter based on SOURCE_FILTER.
	// "wayu" shows ALL wayu-managed entries (active + inactive).
	show_wayu := wayu.source_filter == "all" || wayu.source_filter == "wayu"
	show_external := wayu.source_filter == "all" || wayu.source_filter == "external"
	show_inactive := wayu.source_filter == "all" || wayu.source_filter == "inactive" || wayu.source_filter == "wayu"

	has_multiple_sources := show_external || (show_wayu && show_inactive)
	headers: []string
	if has_multiple_sources {
		headers = []string{"Constant", "Value", "Source"}
	} else {
		headers = []string{"Constant", "Value"}
	}
	table := new_table(headers)
	defer table_destroy(&table)

	table_style(&table, style_foreground(new_style(), "white"))
	table_header_style(&table, style_bold(style_foreground(new_style(), "cyan"), true))
	table_border(&table, .Normal)

	// Secret-looking values shown as SECRET_MASK (hint printed below).
	masked_count := 0

	// Collect stripped values to defer freeing until after table_render
	stripped_values := make([dynamic]string)
	defer {
		for v in stripped_values { delete(v) }
		delete(stripped_values)
	}

	// Add wayu entries
	if show_wayu || show_inactive {
		for entry in entries {
			is_active := false
			env_val := snapshot_env_var(entry.name)
			if env_val != nil {
				is_active = true
			}

			// Skip if not matching filter
			if is_active && !show_wayu { continue }
			if !is_active && !show_inactive { continue }

			value := strip_ansi_codes(list_display_value(entry.name, entry.value, wayu.reveal_secrets), true)
			append(&stripped_values, value)
			if value == SECRET_MASK && entry.value != SECRET_MASK { masked_count += 1 }
			if has_multiple_sources {
				source := "wayu"
				if !is_active { source = "wayu (inactive)" }
				row := []string{entry.name, value, source}
				table_add_row(&table, row)
			} else {
				row := []string{entry.name, value}
				table_add_row(&table, row)
			}
		}
	}

	// Add external entries
	if show_external {
		for ext_const_name in external_constants {
			if env_val := snapshot_env_var(ext_const_name); env_val != nil {
				real := env_val.(string)
				value := strip_ansi_codes(list_display_value(ext_const_name, real, wayu.reveal_secrets), true)
				append(&stripped_values, value)
				if value == SECRET_MASK && real != SECRET_MASK { masked_count += 1 }
				row := []string{ext_const_name, value, "external"}
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
	if masked_count > 0 {
		noun := "value" if masked_count == 1 else "values"
		fmt.printfln("%s%d secret-looking %s masked; pass --reveal to show (or wayu const get NAME)%s",
			get_muted(), masked_count, noun, RESET)
	}
}

print_constants_json :: proc(entries: []ConfigEntry, external_constants: []string) {
	// Build wayu set for fast lookup
	wayu_set := make(map[string]bool)
	defer delete(wayu_set)
	for entry in entries {
		wayu_set[entry.name] = true
	}

	// Determine if we show different source categories (same logic as table view)
	show_wayu := wayu.source_filter == "all" || wayu.source_filter == "wayu"
	show_external := wayu.source_filter == "all" || wayu.source_filter == "external"
	show_inactive := wayu.source_filter == "all" || wayu.source_filter == "inactive" || wayu.source_filter == "wayu"

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
			val_j  := json_escape(list_display_value(entry.name, entry.value, wayu.reveal_secrets)); defer delete(val_j)
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
				val_j  := json_escape(list_display_value(ext_const_name, env_val.(string), wayu.reveal_secrets)); defer delete(val_j)
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

	// Exact match only (OKAMI-207): never hand back a different entry.
	names := make([]string, len(entries), context.temp_allocator)
	for entry, i in entries { names[i] = entry.name }
	exit_get_not_found(&CONSTANTS_SPEC, name, names)
}
