// alias.odin - ALIAS entry management
//
// Aliases live in the entry store (<data>/entries.json, see entries.odin).

package wayu
import "core:fmt"
import "core:os"
import "core:sort"
import "core:strings"
// Main handler for ALIAS commands.
//
// Thin delegation to the generic entry dispatcher. The spec wires up
// toml_alias_add/remove/list/get + per-action hooks + the external-sources
// epilogue on LIST (see ALIAS_SPEC in config_specs.odin).
handle_alias_command :: proc(action: Action, args: []string) {
	handle_toml_entry_command(&ALIAS_SPEC, action, args)
}

// The store's aliases in order. Exits EXIT_CONFIG when entries.json is
// malformed. Free with cleanup_entries.
read_alias_entries :: proc() -> []ConfigEntry {
	store := entries_load()
	defer entries_store_destroy(&store)
	return entries_as_config_entries(&store, .ALIAS)
}

toml_alias_add :: proc(entry: ConfigEntry) -> (bool, string) {
	validation := validate_alias(entry.name, entry.value)
	if !validation.valid {
		err := strings.clone(validation.error_message)
		delete(validation.error_message)
		return false, err
	}
	return entries_entry_upsert(.ALIAS, entry.name, entry.value, "Alias")
}

toml_alias_remove :: proc(name: string) -> (bool, string) {
	return entries_entry_remove(.ALIAS, name, "Alias")
}

list_toml_aliases :: proc() {
	if !check_wayu_initialized() {
		wayu_exit(EXIT_CONFIG)
	}

	entries := read_alias_entries()
	defer cleanup_entries(&entries)

	// Determine if we need the expensive shell spawn.
	// Default source_filter is "wayu" — no need to cross-reference the
	// live shell environment. Only spawn when the user asks for external
	// aliases (--full / --source=all / --source=external / --source=inactive).
	needs_env := wayu.source_filter != "wayu"

	aliases_env: map[string]string
	if needs_env {
		aliases_env = snapshot_aliases()
	}

	// Build set of wayu-managed aliases for fast lookup
	wayu_set := make(map[string]bool)
	defer delete(wayu_set)
	for entry in entries {
		wayu_set[entry.name] = true
	}

	// Find external aliases (in env but not managed by wayu)
	external_aliases := make([dynamic]string)
	defer delete(external_aliases)
	if needs_env {
		for alias_name in aliases_env {
			if _, is_wayu := wayu_set[alias_name]; !is_wayu {
				append(&external_aliases, alias_name)
			}
		}
	}

	// JSON first: an empty list is still a JSON document (OKAMI-239).
	if wayu.json_output {
		print_aliases_json(entries[:], external_aliases[:])
		return
	}

	if len(entries) == 0 && len(external_aliases) == 0 {
		print_info("No Aliases found")
		return
	}

	print_header("Aliases (wayu)", ALIAS_SPEC.icon)
	fmt.println()

	// Count sources — when env is available, cross-reference; otherwise
	// treat all wayu entries as active (we can't tell without spawning).
	active_count := 0
	inactive_count := 0
	if needs_env {
		for entry in entries {
			if _, has := aliases_env[entry.name]; has {
				active_count += 1
			} else {
				inactive_count += 1
			}
		}
	} else {
		active_count = len(entries)
	}

	// Print summary
	if needs_env {
		fmt.printfln(
			"  %d active · %d inactive · %d external",
			active_count,
			inactive_count,
			len(external_aliases),
		)
	} else {
		fmt.printfln("  %d entries", active_count)
	}
	fmt.println()

	// Filter based on SOURCE_FILTER
	show_wayu := wayu.source_filter == "all" || wayu.source_filter == "wayu"
	show_external := wayu.source_filter == "all" || wayu.source_filter == "external"
	show_inactive := wayu.source_filter == "all" || wayu.source_filter == "inactive"

	has_multiple_sources := show_external || (show_wayu && show_inactive)
	headers: []string
	if has_multiple_sources {
		headers = []string{"Alias", "Command", "Source"}
	} else {
		headers = []string{"Alias", "Command"}
	}
	table := new_table(headers)
	defer table_destroy(&table)

	table_style(&table, style_foreground(new_style(), "white"))
	table_header_style(&table, style_bold(style_foreground(new_style(), "cyan"), true))
	table_border(&table, .Normal)

	// Add wayu entries
	if show_wayu || show_inactive {
		for entry in entries {
			// When env snapshot is available, cross-reference; otherwise
			// treat all wayu entries as active (fast path).
			is_active := true
			if needs_env {
				is_active = false
				if _, has := aliases_env[entry.name]; has {
					is_active = true
				}
			}

			// Skip if not matching filter
			if is_active && !show_wayu {
				continue
			}
			if !is_active && !show_inactive {
				continue
			}

			if has_multiple_sources {
				source := "wayu"
				if !is_active {
					source = "wayu (inactive)"
				}
				row := []string{entry.name, entry.value, source}
				table_add_row(&table, row)
			} else {
				row := []string{entry.name, entry.value}
				table_add_row(&table, row)
			}
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

	if !needs_env {
		fmt.printfln(
			"%sPass --full to cross-reference with shell environment%s",
			get_muted(),
			RESET,
		)
	} else if !show_external && len(external_aliases) > 0 {
		fmt.printfln(
			"%sPass --full to show %d external entries%s",
			get_muted(),
			len(external_aliases),
			RESET,
		)
	}
}

print_aliases_json :: proc(entries: []ConfigEntry, external_aliases: []string) {
	// Only spawn an interactive shell when we need external/inactive info.
	needs_env := wayu.source_filter != "wayu"
	aliases_env: map[string]string
	if needs_env {
		aliases_env = snapshot_aliases()
	}

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
		for entry in entries {
			is_active := true
			if needs_env {
				is_active = false
				if _, has := aliases_env[entry.name]; has {
					is_active = true
				}
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
			name_j := json_escape(entry.name); defer delete(name_j)
			val_j := json_escape(entry.value); defer delete(val_j)
			src_j := json_escape(source); defer delete(src_j)
			fmt.printf(
				"    %c\"alias\": \"%s\", \"command\": \"%s\", \"source\": \"%s\"%c",
				'{',
				name_j,
				val_j,
				src_j,
				'}',
			)
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
				val_j := json_escape(value); defer delete(val_j)
				fmt.printf(
					"    %c\"alias\": \"%s\", \"command\": \"%s\", \"source\": \"external\"%c",
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

get_toml_alias_value :: proc(name: string) {
	if len(strings.trim_space(name)) == 0 {
		print_cli_usage_error(&ALIAS_SPEC, "get")
		wayu_exit(EXIT_USAGE)
	}
	if !check_wayu_initialized() {
		wayu_exit(EXIT_CONFIG)
	}

	entries := read_alias_entries()

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
	for entry, i in entries {names[i] = entry.name}
	exit_get_not_found(&ALIAS_SPEC, name, names)
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

		append(
			&result,
			AliasSource {
				label = strings.clone(label),
				path = expanded_path,
				command_template = strings.clone(cmd_template),
			},
		)
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

	sort.sort(sort.Interface {
		len = proc(it: sort.Interface) -> int {return len((cast(^[dynamic]string)it.collection)^)},
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
	fmt.printf(
		"\n%s%sExternal: %s%s %s(%s)%s  %s[read-only]%s\n",
		BOLD,
		get_secondary(),
		term_safe(source.label),
		RESET,
		MUTED,
		term_safe(source.path),
		RESET,
		DIM,
		RESET,
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
		// strings.replace returns the input itself (allocated=false) when
		// there is nothing to replace — only free what it allocated.
		cmd, allocated := strings.replace(source.command_template, "{name}", name, 1)
		defer if allocated do delete(cmd)
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
	// Respect source filter — skip external alias sources when hidden
	if wayu.source_filter != "all" && wayu.source_filter != "external" {
		return
	}

	sources := read_alias_sources()
	if sources == nil {
		return
	}
	defer cleanup_alias_sources(sources)

	for source in sources {
		print_alias_source(source)
	}
}
