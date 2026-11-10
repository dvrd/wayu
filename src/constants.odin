// constants.odin - CONSTANTS entry management
//
// Constants live in the entry store (<data>/entries.json, see entries.odin).

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// Main handler for CONSTANTS commands.
//
// Thin delegation to the generic entry dispatcher. The spec wires up
// toml_constant_add/remove/list/get + per-action hooks (see CONSTANTS_SPEC
// in config_specs.odin).
handle_constants_command :: proc(action: Action, args: []string) {
	if action == .ADD && wayu.secret_flag {
		if !ensure_wayu_toml_exists() {
			print_error_simple("Failed to create wayu.toml")
			wayu_exit(EXIT_IOERR)
		}
		const_add_secret(args) // secrets_store.odin
		return
	}
	handle_toml_entry_command(&CONSTANTS_SPEC, action, args)
}

// The store's constants in order. Exits EXIT_CONFIG when entries.json is
// malformed. Free with cleanup_entries.
read_env_entries :: proc() -> []ConfigEntry {
	store := entries_load()
	defer entries_store_destroy(&store)
	return entries_as_config_entries(&store, .ENV)
}

// Unescape TOML basic-string escape sequences
unescape_toml_string :: proc(value: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// Work byte-wise and copy bytes verbatim: multi-byte UTF-8 sequences must
	// pass through untouched (write_rune(rune(b)) would re-encode each byte as
	// its own code point, turning `é` into `Ã©`).
	i := 0
	for i < len(value) {
		if value[i] == '\\' && i + 1 < len(value) {
			switch value[i + 1] {
			case '\\':
				strings.write_byte(&builder, '\\')
			case '"':
				strings.write_byte(&builder, '"')
			case 'n':
				strings.write_byte(&builder, '\n')
			case 'r':
				strings.write_byte(&builder, '\r')
			case 't':
				strings.write_byte(&builder, '\t')
			case 'b':
				strings.write_byte(&builder, '\b')
			case 'f':
				strings.write_byte(&builder, '\f')
			case 'u', 'U':
				// \uXXXX / \UXXXXXXXX → UTF-8. Malformed sequences are kept literally.
				width := 4 if value[i + 1] == 'u' else 8
				if cp, ok := parse_hex_codepoint(value, i + 2, width); ok {
					strings.write_rune(&builder, cp)
					i += 2 + width
					continue
				}
				strings.write_byte(&builder, '\\')
				strings.write_byte(&builder, value[i + 1])
			case:
				strings.write_byte(&builder, '\\')
				strings.write_byte(&builder, value[i + 1])
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
	if start + width > len(value) {
		return 0, false
	}
	cp: u32 = 0
	for j in start ..< start + width {
		c := value[j]
		d: u32
		switch c {
		case '0' ..= '9':
			d = u32(c - '0')
		case 'a' ..= 'f':
			d = u32(c - 'a' + 10)
		case 'A' ..= 'F':
			d = u32(c - 'A' + 10)
		case:
			return 0, false
		}
		cp = cp * 16 + d
	}
	if cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) {
		return 0, false
	}
	return rune(cp), true
}

toml_constant_add :: proc(entry: ConfigEntry) -> (bool, string) {
	// A secret never silently becomes plaintext again.
	if secrets_store_has_name_or_exit(entry.name) {
		return false, fmt.aprintf(
			"%s is an encrypted secret: change it with `wayu const add %s VALUE --secret`, or remove it first",
			entry.name,
			entry.name,
		)
	}
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
	return entries_entry_upsert(.ENV, entry.name, entry.value, "Constant")
}

toml_constant_remove :: proc(name: string) -> (bool, string) {
	if !secrets_store_has_name_or_exit(name) {
		return entries_entry_remove(.ENV, name, "Constant")
	}
	// Secret: drop the ciphertext (secrets.json) and the entries.json marker.
	if wayu.dry_run {
		print_info("[dry-run] Would remove secret %s from %s", name, secrets_store_path())
		return true, ""
	}
	config_lock_acquire_or_exit()
	defer config_lock_release()
	_ = const_remove_secret(name)
	regenerate_init_core_silently()
	print_success("Secret removed: %s", name)
	return true, ""
}

list_toml_constants :: proc() {
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	all_entries := read_env_entries()
	defer cleanup_entries(&all_entries)
	entries := all_entries

	// Encrypted constants: listed by name, value never shown.
	secret_store, _ := secrets_store_load_or_exit()
	defer secrets_store_destroy(&secret_store)
	secret_names := make([]string, len(secret_store.entries), context.temp_allocator)
	for e, i in secret_store.entries {secret_names[i] = e.name}
	run_only_set := make(map[string]bool, context.temp_allocator)
	for e in secret_store.entries {
		if e.run_only {
			run_only_set[e.name] = true
		}
	}
	// The entries.json markers of secrets carry no value: list them once,
	// from secrets.json, below the plain constants.
	{
		secret_set := make(map[string]bool, context.temp_allocator)
		for n in secret_names {secret_set[n] = true}
		kept := 0
		for &entry in all_entries {
			if entry.name in secret_set {
				cleanup_entry(&entry); continue
			}
			all_entries[kept] = entry
			kept += 1
		}
		for i in kept ..< len(all_entries) {all_entries[i] = {}}
		entries = all_entries[:kept]
	}

	// Build set of wayu-managed constants for fast lookup
	wayu_set := make(map[string]bool)
	defer delete(wayu_set)
	for entry in entries {
		wayu_set[entry.name] = true
	}
	for name in secret_names {wayu_set[name] = true}

	// Find external constants (in env but not managed by wayu)
	external_constants := make([dynamic]string)
	defer delete(external_constants)

	// Get all environment variables (zero-alloc name extraction)
	env_list, env_err := os.environ(context.allocator)
	// external_constants slice into these strings; both live until return.
	defer {
		if env_err == nil {
			for pair in env_list {delete(pair)}
		}
		delete(env_list)
	}
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

	// JSON first: an empty list is still a JSON document (OKAMI-239).
	if wayu.json_output {
		print_constants_json(entries[:], external_constants[:], secret_names, run_only_set)
		return
	}

	if len(entries) == 0 && len(external_constants) == 0 && len(secret_names) == 0 {
		print_info("No Constants found")
		return
	}

	print_header("Constants (wayu)", CONSTANTS_SPEC.icon)
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
	for name in secret_names {
		if snapshot_env_var(name) != nil {
			active_count += 1
		} else {
			inactive_count += 1
		}
	}

	// Print summary
	fmt.printfln(
		"  %d active · %d inactive · %d external",
		active_count,
		inactive_count,
		len(external_constants),
	)
	fmt.println()

	// Filter based on SOURCE_FILTER.
	// "wayu" shows ALL wayu-managed entries (active + inactive).
	show_wayu := wayu.source_filter == "all" || wayu.source_filter == "wayu"
	show_external := wayu.source_filter == "all" || wayu.source_filter == "external"
	show_inactive :=
		wayu.source_filter == "all" ||
		wayu.source_filter == "inactive" ||
		wayu.source_filter == "wayu"

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
		for v in stripped_values {delete(v)}
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
			if is_active && !show_wayu {
				continue
			}
			if !is_active && !show_inactive {
				continue
			}

			value := strip_ansi_codes(
				list_display_value(entry.name, entry.value, wayu.reveal_secrets),
				true,
			)
			append(&stripped_values, value)
			if value == SECRET_MASK && entry.value != SECRET_MASK {
				masked_count += 1
			}
			if has_multiple_sources {
				source := "wayu"
				if !is_active {
					source = "wayu (inactive)"
				}
				row := []string{entry.name, value, source}
				table_add_row(&table, row)
			} else {
				row := []string{entry.name, value}
				table_add_row(&table, row)
			}
		}
		// Secrets: always masked (`wayu const get NAME` decrypts one).
		for name in secret_names {
			is_active := snapshot_env_var(name) != nil
			if is_active && !show_wayu {
				continue
			}
			if !is_active && !show_inactive {
				continue
			}
			if has_multiple_sources {
				source := "wayu (secret)" if is_active else "wayu (secret, inactive)"
				if name in run_only_set {
					source = "wayu (run-only)"
				}
				table_add_row(&table, []string{name, SECRET_MASK, source})
			} else {
				table_add_row(&table, []string{name, SECRET_MASK})
			}
		}
	}

	// Add external entries
	if show_external {
		for ext_const_name in external_constants {
			if env_val := snapshot_env_var(ext_const_name); env_val != nil {
				real := env_val.(string)
				value := strip_ansi_codes(
					list_display_value(ext_const_name, real, wayu.reveal_secrets),
					true,
				)
				append(&stripped_values, value)
				if value == SECRET_MASK && real != SECRET_MASK {
					masked_count += 1
				}
				row := []string{ext_const_name, value, "external"}
				table_add_row(&table, row)
			}
		}
	}

	table_output := table_render(table, get_cli_terminal_width())
	defer delete(table_output)
	fmt.print(table_output)

	if !show_external && len(external_constants) > 0 {
		fmt.printfln(
			"%sPass --full to show %d external entries%s",
			get_muted(),
			len(external_constants),
			RESET,
		)
	}
	if masked_count > 0 {
		noun := "value" if masked_count == 1 else "values"
		fmt.printfln(
			"%s%d secret-looking %s masked; pass --reveal to show (or wayu const get NAME)%s",
			get_muted(),
			masked_count,
			noun,
			RESET,
		)
	}
}

print_constants_json :: proc(
	entries: []ConfigEntry,
	external_constants: []string,
	secret_names: []string = nil,
	run_only_set: map[string]bool = nil,
) {
	// Build wayu set for fast lookup
	wayu_set := make(map[string]bool)
	defer delete(wayu_set)
	for entry in entries {
		wayu_set[entry.name] = true
	}

	// Determine if we show different source categories (same logic as table view)
	show_wayu := wayu.source_filter == "all" || wayu.source_filter == "wayu"
	show_external := wayu.source_filter == "all" || wayu.source_filter == "external"
	show_inactive :=
		wayu.source_filter == "all" ||
		wayu.source_filter == "inactive" ||
		wayu.source_filter == "wayu"

	fmt.println("{")
	fmt.println(`  "constants": [`)

	first_entry := true

	// Output wayu entries
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

			if !first_entry {
				fmt.println(",")
			}
			name_j := json_escape(entry.name); defer delete(name_j)
			val_j := json_escape(list_display_value(entry.name, entry.value, wayu.reveal_secrets))
			defer delete(val_j)
			src_j := json_escape(source); defer delete(src_j)
			// `{` is a struct-verb opener in Odin's fmt — emit via %c.
			fmt.printf(
				"    %c\"constant\": \"%s\", \"value\": \"%s\", \"source\": \"%s\"%c",
				'{',
				name_j,
				val_j,
				src_j,
				'}',
			)
			first_entry = false
		}
		// Secrets: `"secret": true`, no value.
		for name in secret_names {
			is_active := snapshot_env_var(name) != nil
			if is_active && !show_wayu {
				continue
			}
			if !is_active && !show_inactive {
				continue
			}
			// Same source strings as the text view (OKAMI-356).
			source := "wayu (secret)" if is_active else "wayu (secret, inactive)"
			run_only := name in run_only_set
			if run_only {
				source = "wayu (run-only)"
			}
			if !first_entry {
				fmt.println(",")
			}
			name_j := json_escape(name); defer delete(name_j)
			fmt.printf(
				"    %c\"constant\": \"%s\", \"secret\": true, %s\"source\": \"%s\"%c",
				'{',
				name_j,
				"\"run_only\": true, " if run_only else "",
				source,
				'}',
			)
			first_entry = false
		}
	}

	// Output external entries
	if show_external {
		for ext_const_name in external_constants {
			if env_val := snapshot_env_var(ext_const_name); env_val != nil {
				name_j := json_escape(ext_const_name); defer delete(name_j)
				val_j := json_escape(
					list_display_value(ext_const_name, env_val.(string), wayu.reveal_secrets),
				); defer delete(val_j)
				if !first_entry {
					fmt.println(",")
				}
				fmt.printf(
					"    %c\"constant\": \"%s\", \"value\": \"%s\", \"source\": \"external\"%c",
					'{',
					name_j,
					val_j,
					'}',
				)
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

	if const_get_secret(name) {
		return
	} // decrypts (secrets_store.odin)
	const_get_exit_if_secret_missing(name)

	entries := read_env_entries()

	// Try exact match first
	for entry in entries {
		if entry.name == name {
			fmt.println(entry.value)
			cleanup_entries(&entries)
			return
		}
	}

	// Exact match only (OKAMI-207): never hand back a different entry.
	names := make([dynamic]string, 0, len(entries), context.temp_allocator)
	for entry in entries {append(&names, entry.name)}
	append(&names, ..secrets_names())
	exit_get_not_found(&CONSTANTS_SPEC, name, names[:])
}
