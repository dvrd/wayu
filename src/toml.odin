// toml.odin - TOML parsing, mapping, serialization, and `wayu toml` commands
//
// Single source of truth for everything TOML in wayu. Replaces the previous
// 5-file split (config_toml.odin / config_toml_simple.odin / toml_mapping.odin /
// toml_serialize.odin / toml_section_writer.odin) which fragmented one
// concept across files for no architectural reason.
//
// Layers, top to bottom:
//   1. TomlValue / TomlDoc      - parsed AST types
//   2. Parser                   - string -> TomlDoc (arena-backed)
//   3. Accessors                - TomlValue -> typed primitives
//   4. Mapping                  - TomlDoc -> TomlConfig (typed config)
//   5. File I/O                 - read_file / write_file + ensure_exists
//   6. Table editor             - line-level edits of one [section] entry
//   7. Serialization            - TomlConfig -> canonical TOML text
//   8. Profile merging          - pick + merge active profile
//   9. CLI handlers             - wayu toml init/show/keys/...

package wayu

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode"


// ============================================================================
// Merged from: config_toml.odin
// ============================================================================

// config_toml.odin - TOML configuration file support for wayu
//
// This module provides TOML parsing, validation, and serialization for wayu's
// configuration files. It supports profiles, nested structures, and all
// configuration types defined in interfaces.odin.



// ============================================================================
// WAYU.TOML BOOTSTRAP
// ============================================================================

// ensure_wayu_toml_exists creates a minimal wayu.toml scaffold if the file is
// absent. Used by alias/constants/path dispatchers so writes always land in
// TOML instead of the legacy shell-file path. If the wayu config directory
// itself doesn't exist we leave things untouched so downstream code can
// report the standard "wayu not initialized" error.
ensure_wayu_toml_exists :: proc() -> bool {
	if !os.exists(wayu.config) {
		return true
	}

	toml_file := fmt.aprintf("%s/wayu.toml", wayu.config)
	defer delete(toml_file)

	if os.exists(toml_file) {
		return true
	}

	shell_name := get_shell_name(wayu.shell)
	scaffold := fmt.aprintf(`[shell]
type = "%s"

[aliases]

[env]
`, shell_name)
	defer delete(scaffold)

	return init_config_file(toml_file, scaffold)
}

// Default autosuggest accept keys shared by toml_create_default and doc_to_config.
default_autosuggest_keys :: proc() -> []string {
	keys := make([]string, 2)
	keys[0] = strings.clone("^Y")
	keys[1] = strings.clone("^[[121;5u")
	return keys
}

// ============================================================================
// TOML VALUE TYPES
// ============================================================================

TomlValueType :: enum {
	STRING,
	INTEGER,
	BOOLEAN,
	ARRAY,
	TABLE,
}

TomlValue :: struct {
	type: TomlValueType,
	str_val: string,
	int_val: int,
	bool_val: bool,
	arr_val: [dynamic]TomlValue,
	table_val: map[string]^TomlValue,
}

make_toml_table :: proc() -> TomlValue {
	return TomlValue{
		type = .TABLE,
		table_val = make(map[string]^TomlValue),
	}
}


// ============================================================================
// TOML DOCUMENT
// ============================================================================

TomlDoc :: struct {
	values: map[string]^TomlValue,
}

// Get value from doc by key path (e.g., "path.entries")
get_toml_value :: proc(doc: ^TomlDoc, key: string) -> ^TomlValue {
	parts := strings.split(key, ".")
	defer delete(parts)

	if len(parts) == 0 {
		return nil
	}

	// First level
	val, ok := doc.values[parts[0]]
	if !ok {
		return nil
	}

	// Nested levels
	for i := 1; i < len(parts); i += 1 {
		if val.type != .TABLE {
			return nil
		}
		val, ok = val.table_val[parts[i]]
		if !ok {
			return nil
		}
	}

	return val
}

// ============================================================================
// PUBLIC API (from interfaces.odin)
// ============================================================================

// Parse TOML content into TomlConfig
toml_parse :: proc(content: string) -> (TomlConfig, bool) {
	if !toml_content_is_sane(content) {
		return {}, false
	}

	// Arena-backed parse. A *growing* virtual arena: the previous fixed
	// buffer (capped at 1MB) overflowed on large configs (~3000 aliases),
	// returning nil allocations and crashing. doc_to_config copies what it
	// keeps, so the whole AST is released in one go below.
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		return {}, false
	}
	defer virtual.arena_destroy(&arena)

	doc, ok := toml_doc_parse_alloc(content, virtual.arena_allocator(&arena))
	if !ok {
		return {}, false
	}

	return doc_to_config(&doc)
}

// Validate TOML configuration
toml_validate :: proc(config: TomlConfig) -> ValidationResult {
	// Check version
	if config.version != "1.0" && config.version != "" {
		return ValidationResult{
			valid = false,
			error_message = fmt.aprintf("Unsupported config version: %s", config.version),
		}
	}

	// Check shell
	if config.shell != "" {
		valid_shells := []string{"zsh", "bash", "fish"}
		found := false
		for s in valid_shells {
			if config.shell == s {
				found = true
				break
			}
		}
		if !found {
			return ValidationResult{
				valid = false,
				error_message = fmt.aprintf("Invalid shell: %s (must be zsh, bash, or fish)", config.shell),
			}
		}
	}

	// Validate aliases. validate_alias allocates result.error_message on
	// failure - wrap the message with aprintf and free the inner copy so
	// we don't leak the 'reserved word' error (tracked by leak report at
	// builder.odin:170 when tests set up an invalid alias).
	for alias in config.aliases {
		result := validate_alias(alias.name, alias.command)
		if !result.valid {
			wrapped := fmt.aprintf("Invalid alias '%s': %s", alias.name, result.error_message)
			delete(result.error_message)
			return ValidationResult{valid = false, error_message = wrapped}
		}
		if result.warning != "" {
			delete(result.warning)
		}
	}

	// Validate constants - same leak shape as aliases above.
	for constant in config.constants {
		result := validate_constant(constant.name, constant.value)
		if !result.valid {
			wrapped := fmt.aprintf("Invalid constant '%s': %s", constant.name, result.error_message)
			delete(result.error_message)
			return ValidationResult{valid = false, error_message = wrapped}
		}
		if result.warning != "" {
			delete(result.warning)
		}
	}

	// Validate path entries - same pattern.
	for entry in config.path.entries {
		result := validate_path(entry)
		if !result.valid {
			wrapped := fmt.aprintf("Invalid path entry '%s': %s", entry, result.error_message)
			delete(result.error_message)
			return ValidationResult{valid = false, error_message = wrapped}
		}
	}

	return ValidationResult{valid = true, error_message = ""}
}

// ============================================================================
// FILE OPERATIONS
// ============================================================================

TOML_CONFIG_FILE :: "wayu.toml"

// Read TOML config from file
toml_read_file :: proc(path: string) -> (TomlConfig, bool) {
	content, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return {}, false
	}
	defer delete(content)

	return toml_parse(string(content))
}

// Get default config file path
toml_get_config_path :: proc() -> string {
	return fmt.aprintf("%s/%s", wayu.config, TOML_CONFIG_FILE)
}

// True when `trimmed` (an already-trimmed line) is the `[section]` header,
// tolerating an inline comment and inner whitespace: `[env]  # vars` and
// `[ env ]` both match "env". Array-of-tables (`[[x]]`) never matches.
toml_line_is_section :: proc(trimmed: string, section: string) -> bool {
	if !strings.has_prefix(trimmed, "[") || strings.has_prefix(trimmed, "[[") { return false }
	no_comment, _ := toml_strip_inline_comment_strict(trimmed)
	h := strings.trim_space(no_comment)
	if len(h) < 2 || h[len(h)-1] != ']' { return false }
	return strings.trim_space(h[1:len(h)-1]) == section
}

// Parse one `key = value` line from a TOML table body into (key, value).
// The inline comment is stripped first, then exactly one MATCHING pair of
// quotes: "basic" strings are unescaped, 'literal' strings are taken
// verbatim, anything else (bare ints/bools) is returned trimmed. An empty
// quoted value (`FOO = ""`) is valid and returned as ok with value "".
// `value` is always heap-allocated (caller deletes); `key` aliases `line`.
toml_parse_kv_line :: proc(line: string) -> (key: string, value: string, ok: bool) {
	trimmed := strings.trim_space(line)
	if len(trimmed) == 0 || trimmed[0] == '#' || trimmed[0] == '[' { return }
	eq := strings.index_byte(trimmed, '=')
	if eq < 1 { return }
	key = strings.trim_space(trimmed[:eq])
	if len(key) == 0 { return }

	raw := strings.trim_space(trimmed[eq+1:])
	if stripped, balanced := toml_strip_inline_comment_strict(raw); balanced {
		raw = strings.trim_space(stripped)
	}
	n := len(raw)
	switch {
	case n >= 2 && raw[0] == '"' && raw[n-1] == '"':
		value = unescape_toml_string(raw[1:n-1])
	case n >= 2 && raw[0] == '\'' && raw[n-1] == '\'':
		value = strings.clone(raw[1:n-1])
	case n == 0:
		return "", "", false
	case:
		value = strings.clone(raw)
	}
	return key, value, true
}

// Return `content` with the entire `[section]` table removed (header + body),
// preserving every other line verbatim. Single source of truth for the
// section-rewrite used by alias + constant management.
strip_toml_section :: proc(content: string, section: string) -> string {
	builder := strings.builder_make(0, len(content))
	defer strings.builder_destroy(&builder)

	it := make_line_iter(content)
	skip_section := false
	first := true
	for line in line_iter_next(&it) {
		trimmed := strings.trim_space(line)

		if toml_line_is_section(trimmed, section) {
			skip_section = true
			continue
		}

		if skip_section && strings.has_prefix(trimmed, "[") {
			skip_section = false
		}

		if skip_section {
			continue
		}

		if !first { strings.write_byte(&builder, '\n') }
		strings.write_string(&builder, line)
		first = false
	}

	return strings.clone(strings.to_string(builder))
}

// Read wayu.toml straight from disk (never the startup cache: a writer must
// see what concurrent processes committed). Caller deletes.
read_wayu_toml_fresh :: proc() -> (content: []byte, ok: bool) {
	config_path := fmt.tprintf("%s/%s", wayu.config, TOML_CONFIG_FILE)
	return safe_read_file(config_path)
}

// Persist a new wayu.toml: backup, atomic replace, invalidate the cache.
// Caller holds the config lock and has already handled --dry-run.
commit_wayu_toml :: proc(new_content: string) -> bool {
	config_path := fmt.tprintf("%s/%s", wayu.config, TOML_CONFIG_FILE)
	if !create_backup_cli(config_path) { return false }
	if !safe_write_file(config_path, transmute([]byte)new_content) { return false }
	clear_toml_content_cache()
	return true
}

@(private = "file")
print_toml_dry_run :: proc(dry_label, new_content: string) {
	print_header("DRY RUN - No changes will be made", EMOJI_INFO)
	fmt.println()
	fmt.printfln("%sWould update wayu.toml %s:%s", BRIGHT_CYAN, dry_label, RESET)
	fmt.print(new_content)
	fmt.println()
	fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
}

TomlEditResult :: enum {
	OK,
	NOT_FOUND, // delete: no such key
	MALFORMED, // table holds an unterminated value; nothing written
	IO_ERROR,
}

// Upsert `name = "value"` into `[section]` of wayu.toml, editing only that
// entry's line(s). Honors --dry-run. Caller holds the config lock.
// `dry_label` is the human word shown in dry-run output (e.g. "aliases").
toml_kv_upsert :: proc(section, dry_label, name, value: string) -> (res: TomlEditResult, existed: bool) {
	content, ok := read_wayu_toml_fresh()
	if !ok { return .IO_ERROR, false }
	defer delete(content)

	escaped := escape_toml_string(value)
	defer delete(escaped)
	line := fmt.aprintf(`%s = "%s"`, name, escaped)
	defer delete(line)

	new_content, had, bad := toml_table_set(string(content), section, name, line)
	if bad > 0 {
		toml_print_bad_line(section, bad)
		return .MALFORMED, false
	}
	defer delete(new_content)

	if wayu.dry_run {
		print_toml_dry_run(dry_label, new_content)
		return .OK, had
	}
	if !commit_wayu_toml(new_content) { return .IO_ERROR, had }
	return .OK, had
}

// Delete the entries named in `names` from `[section]` of wayu.toml (all
// lines of each, nothing else). Honors --dry-run. Caller holds the lock.
toml_kv_delete :: proc(section, dry_label: string, names: []string) -> TomlEditResult {
	content, ok := read_wayu_toml_fresh()
	if !ok { return .IO_ERROR }
	defer delete(content)

	new_content, removed, bad := toml_table_delete(string(content), section, names)
	if bad > 0 {
		toml_print_bad_line(section, bad)
		return .MALFORMED
	}
	defer delete(new_content)
	if removed == 0 { return .NOT_FOUND }

	if wayu.dry_run {
		print_toml_dry_run(dry_label, new_content)
		return .OK
	}
	if !commit_wayu_toml(new_content) { return .IO_ERROR }
	return .OK
}

// Remove the entry named `name` from a TOML-backed key/value table, persist,
// and regenerate the shell core. `noun` is the display word
// ("Alias"/"Constant"). Single source of truth shared by alias + constant
// removal. Holds the config lock across write + regeneration.
toml_entry_remove :: proc(name, noun, section, dry_label: string) -> (bool, string) {
	if !config_lock_acquire() {
		return false, strings.clone("could not lock wayu config")
	}
	defer config_lock_release()

	switch toml_kv_delete(section, dry_label, {name}) {
	case .NOT_FOUND: return false, fmt.aprintf("%s not found: %s", noun, name)
	case .MALFORMED: return false, strings.clone("wayu.toml is malformed: nothing was written")
	case .IO_ERROR:  return false, strings.clone("I/O error: could not update wayu.toml")
	case .OK:
	}
	// Dry-run: the preview was printed; nothing was written so there is
	// nothing to regenerate and no success to report.
	if wayu.dry_run { return true, "" }

	regenerate_init_core_silently()

	print_success("%s removed successfully from wayu.toml: %s", noun, name)
	return true, ""
}

// Upsert one alias/constant under the config lock, then regenerate. Shared
// tail of toml_alias_add + toml_constant_add.
toml_entry_upsert :: proc(name, value, noun, section, dry_label: string) -> (bool, string) {
	if !config_lock_acquire() {
		return false, strings.clone("could not lock wayu config")
	}
	defer config_lock_release()

	res, existed := toml_kv_upsert(section, dry_label, name, value)
	switch res {
	case .MALFORMED: return false, strings.clone("wayu.toml is malformed: nothing was written")
	case .IO_ERROR, .NOT_FOUND: return false, strings.clone("I/O error: could not update wayu.toml")
	case .OK:
	}
	if wayu.dry_run { return true, "" }

	regenerate_init_core_silently()

	if existed {
		print_success("%s updated successfully in wayu.toml: %s", noun, name)
	} else {
		print_success("%s added successfully to wayu.toml: %s", noun, name)
	}
	return true, ""
}

// ============================================================================
// COMMAND HANDLERS
// ============================================================================

// Handle `wayu validate`
handle_validate :: proc() -> bool {
	config_path := toml_get_config_path()
	defer delete(config_path)

	if !os.exists(config_path) {
		fmt.eprintfln("Error: No TOML config found at %s", config_path)
		fmt.println("Run 'wayu init --toml' to create one")
		return false
	}

	config, ok := toml_read_file(config_path)
	if !ok {
		fmt.eprintfln("Error: Failed to parse %s", config_path)
		return false
	}
	defer cleanup_toml_config(&config)

	result := toml_validate(config)

	if !result.valid {
		fmt.eprintfln("Validation failed: %s", result.error_message)
		delete(result.error_message)
		return false
	}

	fmt.println("✓ TOML config is valid")
	return true
}

// `wayu toml convert` is now an alias for `wayu migrate`. The original
// implementation was a scaffolding stub that created an empty wayu.toml
// and printed "Migration not yet implemented". The real migration path
// lives in migrate_legacy_to_toml (see main.odin).
handle_convert_to_toml :: proc() -> bool {
	fmt.println()
	print_info("`wayu toml convert` now runs `wayu migrate` under the hood.")
	fmt.println()
	migrate_legacy_to_toml(wayu.dry_run)
	return true
}

// Handle 'wayu toml show' - display TOML content
handle_toml_show :: proc() {
	toml_file := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	defer delete(toml_file)

	content, err := os.read_entire_file_from_path(toml_file, context.allocator)
	if err != nil {
		fmt.eprintfln("Failed to read TOML file: %s", toml_file)
		os.exit(EXIT_IOERR)
	}
	defer delete(content)

	fmt.print(string(content))
}

// Handle 'wayu toml keys' - display TOML keys
handle_toml_keys :: proc() {
	toml_file := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	defer delete(toml_file)

	// Parse TOML to check it's valid
	config, ok := toml_read_file(toml_file)
	if !ok {
		fmt.eprintfln("Failed to parse TOML file: %s", toml_file)
		os.exit(EXIT_DATAERR)
	}

	// Print all top-level keys in sorted order
	keys := []string{"shell", "path", "aliases", "constants", "plugins", "hooks"}
	for key in keys {
		fmt.println(key)
	}
}

// Main handler for TOML command (wayu toml <action>)
handle_toml_command :: proc(action: Action) {
	#partial switch action {
	case .CHECK:
		// Validate TOML config
		if !check_wayu_initialized() {
			os.exit(EXIT_CONFIG)
		}
		if !handle_validate() {
			os.exit(EXIT_DATAERR)
		}
	case .LIST:
		// Show all TOML keys
		if !check_wayu_initialized() {
			os.exit(EXIT_CONFIG)
		}
		handle_toml_keys()
	case .GET:
		// Show TOML content
		if !check_wayu_initialized() {
			os.exit(EXIT_CONFIG)
		}
		handle_toml_show()
	case .UPDATE:
		// `toml convert` - legacy shell configs → wayu.toml. This runs even
		// when the regular essential-files gate would fail, because the whole
		// point of migration is to bootstrap an incomplete setup into the
		// TOML layout.
		if !handle_convert_to_toml() {
			os.exit(EXIT_CANTCREAT)
		}
	case .HELP, .UNKNOWN:
		print_toml_usage()
	case:
		print_toml_usage()
	}
}

// Print TOML command usage
print_toml_usage :: proc() {
	fmt.println()
	fmt.printfln("%swayu toml - TOML configuration management%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.printfln("  wayu toml                    Validate TOML config (default)")
	fmt.printfln("  wayu toml validate           Validate wayu.toml syntax")
	fmt.printfln("  wayu toml show               Display TOML content")
	fmt.printfln("  wayu toml keys               List TOML keys")
	fmt.printfln("  wayu toml convert            Convert legacy shell configs → wayu.toml (alias of `wayu migrate`)")
	fmt.printfln("  wayu toml help               Show this help")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  Manage wayu configuration through TOML files.")
	fmt.println("  TOML enables declarative, version-controlled configs.")
	fmt.println()
	fmt.printfln("%sFILE LOCATIONS:%s", get_primary(), RESET)
	fmt.printfln("  ~/.config/wayu/wayu.toml         Main config (check into git)")
	fmt.printfln("  ~/.config/wayu/wayu.local.toml   Local overrides (gitignored)")
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  # Validate your TOML config")
	fmt.println("  wayu toml validate")
	fmt.println()
	fmt.println("  # Convert legacy shell configs to wayu.toml (same as `wayu migrate`)")
	fmt.println("  wayu toml convert")
	fmt.println()
	fmt.println("  # Apply wayu.toml to shell (rebuild init script)")
	fmt.println("  wayu build")
	fmt.println()
	fmt.printfln("%sSee:%s ~/.config/wayu/wayu.toml for example configuration", get_muted(), RESET)
}

// Properly free all memory in a TomlConfig
cleanup_toml_config :: proc(config: ^TomlConfig) {
	delete(config.version)
	delete(config.shell)
	delete(config.wayu_version)
	for e in config.path.entries {
		delete(e)
	}
	delete(config.path.entries)
	for alias in config.aliases {
		delete(alias.name)
		delete(alias.command)
		delete(alias.description)
	}
	delete(config.aliases)
	for constant in config.constants {
		delete(constant.name)
		delete(constant.value)
		delete(constant.description)
	}
	delete(config.constants)
	for plugin in config.plugins {
		delete(plugin.name)
		delete(plugin.source)
		delete(plugin.version)
		delete(plugin.condition)
		delete(plugin.description)
		for u in plugin.use {
			delete(u)
		}
		delete(plugin.use)
	}
	delete(config.plugins)
	for key, profile in config.profiles {
		delete(key)
		for a in profile.aliases {
			delete(a.name)
			delete(a.command)
			delete(a.description)
		}
		delete(profile.aliases)
		for c in profile.constants {
			delete(c.name)
			delete(c.value)
			delete(c.description)
		}
		delete(profile.constants)
		for p in profile.plugins {
			delete(p.name)
			delete(p.source)
			delete(p.version)
			delete(p.condition)
			delete(p.description)
			for u in p.use {
				delete(u)
			}
			delete(p.use)
		}
		delete(profile.plugins)
		if profile.path != nil {
			for e in profile.path.entries {
				delete(e)
			}
			delete(profile.path.entries)
			free(profile.path)
		}
		delete(profile.condition)
	}
	delete(config.profiles)
	if config.settings.autosuggestions_accept_keys != nil {
		for k in config.settings.autosuggestions_accept_keys {
			delete(k)
		}
		delete(config.settings.autosuggestions_accept_keys)
	}
}

// ============================================================================
// Merged from: config_toml_simple.odin
// ============================================================================

// config_toml_simple.odin - Simplified TOML parser using arenas
// This is a drop-in replacement for the complex pointer-based parser



// Reject malformed TOML before the permissive legacy parser builds the AST.
// This keeps wayu from silently accepting corrupt configs or unknown bare values.
toml_content_is_sane :: proc(content: string) -> bool {
	lines := strings.split(content, "\n")
	defer delete(lines)

	current_section := make(map[string]bool)
	defer delete(current_section)

	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") { continue }

		line_no_comment, ok := toml_strip_inline_comment_strict(trimmed)
		if !ok { return false }
		trimmed = strings.trim_space(line_no_comment)
		if len(trimmed) == 0 { continue }

		if strings.has_prefix(trimmed, "[") {
			array_table := strings.has_prefix(trimmed, "[[")
			if array_table {
				if !strings.has_suffix(trimmed, "]]") || len(trimmed) <= 4 { return false }
				section := strings.trim_space(trimmed[2:len(trimmed)-2])
				if !toml_key_path_is_plain(section) { return false }
				continue
			}

			if !strings.has_suffix(trimmed, "]") || strings.has_prefix(trimmed, "[[") || len(trimmed) <= 2 { return false }
			section := strings.trim_space(trimmed[1:len(trimmed)-1])
			if !toml_key_path_is_plain(section) { return false }
			if current_section[section] { return false }
			current_section[section] = true
			continue
		}

		eq_idx := strings.index(trimmed, "=")
		if eq_idx <= 0 { return false }
		key := strings.trim_space(trimmed[:eq_idx])
		value := strings.trim_space(trimmed[eq_idx+1:])
		if !toml_key_is_plain(key) || !toml_value_is_sane(value) { return false }
	}
	return true
}

toml_strip_inline_comment_strict :: proc(line: string) -> (string, bool) {
	in_string := false
	string_char: byte = 0
	for i := 0; i < len(line); i += 1 {
		c := line[i]
		if in_string {
			if c == string_char {
				if string_char == '\'' || !toml_is_escaped_quote(line, i) {
					in_string = false
				}
			}
			continue
		}
		switch c {
		case '"', '\'':
			in_string = true
			string_char = c
		case '#':
			return line[:i], true
		}
	}
	return line, !in_string
}

toml_is_escaped_quote :: proc(s: string, i: int) -> bool {
	bs := 0
	for j := i - 1; j >= 0 && s[j] == '\\'; j -= 1 { bs += 1 }
	return bs % 2 == 1
}

toml_key_is_plain :: proc(key: string) -> bool {
	if len(key) == 0 { return false }
	for c in key {
		ok := (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
		if !ok { return false }
	}
	return true
}

toml_key_path_is_plain :: proc(path: string) -> bool {
	if len(path) == 0 { return false }
	parts := strings.split(path, ".")
	defer delete(parts)
	for part in parts {
		if !toml_key_is_plain(strings.trim_space(part)) { return false }
	}
	return true
}

toml_value_is_sane :: proc(value: string) -> bool {
	if len(value) == 0 { return false }

	if strings.has_prefix(value, "\"") {
		return toml_basic_string_is_sane(value)
	}
	if strings.has_prefix(value, "'") {
		return len(value) >= 2 && strings.has_suffix(value, "'")
	}
	if value == "true" || value == "false" { return true }
	if _, ok := strconv.parse_int(value); ok { return true }
	if strings.has_prefix(value, "[") {
		if !strings.has_suffix(value, "]") { return false }
		return toml_collection_is_balanced(value)
	}
	if strings.has_prefix(value, "{") {
		if !strings.has_suffix(value, "}") { return false }
		return toml_collection_is_balanced(value)
	}
	return false
}

toml_basic_string_is_sane :: proc(value: string) -> bool {
	if len(value) < 2 || !strings.has_suffix(value, "\"") { return false }
	for i := 1; i < len(value) - 1; i += 1 {
		c := value[i]
		if c == '"' && !toml_is_escaped_quote(value, i) { return false }
		if c == '\\' {
			if i + 1 >= len(value) - 1 { return false }
			switch value[i+1] {
			case 'b', 't', 'n', 'f', 'r', '"', '\\', 'u', 'U':
				i += 1
			case:
				return false
			}
		}
	}
	return true
}

toml_collection_is_balanced :: proc(value: string) -> bool {
	depth_brk, depth_brc := 0, 0
	in_string := false
	string_char: byte = 0
	for i := 0; i < len(value); i += 1 {
		c := value[i]
		if in_string {
			if c == string_char {
				if string_char == '\'' || !toml_is_escaped_quote(value, i) { in_string = false }
			}
			continue
		}
		switch c {
		case '"', '\'':
			in_string = true
			string_char = c
		case '[':
			depth_brk += 1
		case ']':
			depth_brk -= 1
			if depth_brk < 0 { return false }
		case '{':
			depth_brc += 1
		case '}':
			depth_brc -= 1
			if depth_brc < 0 { return false }
		}
	}
	return !in_string && depth_brk == 0 && depth_brc == 0
}

// TomlDocSimple uses an arena for all allocations
toml_doc_parse_simple :: proc(content: string, arena: ^mem.Arena) -> (TomlDoc, bool) {
	return toml_doc_parse_alloc(content, mem.arena_allocator(arena))
}

// Parse with any allocator; every AST node and string lives in `alloc`.
toml_doc_parse_alloc :: proc(content: string, alloc: mem.Allocator) -> (TomlDoc, bool) {
    doc: TomlDoc
    doc.values = make(map[string]^TomlValue, allocator = alloc)

    lines := strings.split(content, "\n")
    defer delete(lines)

    current_section := ""
    current_array_idx := -1  // -1 means not in an array of tables

    for line, line_num in lines {
        line_trimmed := strings.trim_space(line)

        // Skip empty lines and full-line comments
        if len(line_trimmed) == 0 || strings.has_prefix(line_trimmed, "#") {
            continue
        }

        // Remove inline comments (but not inside strings)
        in_string := false
        string_char: byte = 0
        comment_start := -1

        for i := 0; i < len(line_trimmed); i += 1 {
            c := line_trimmed[i]

            if !in_string && (c == '"' || c == '\'') {
                in_string = true
                string_char = c
            } else if in_string && c == string_char {
				if string_char == '\'' || !toml_is_escaped_quote(line_trimmed, i) {
					in_string = false
				}
            } else if !in_string && c == '#' {
                comment_start = i
                break
            }
        }

        if comment_start >= 0 {
            line_trimmed = strings.trim_space(line_trimmed[:comment_start])
        }

        // Check for array of tables [[section]] or [[section.sub.array]]
        if strings.has_prefix(line_trimmed, "[[") && strings.has_suffix(line_trimmed, "]]") {
            section_name := line_trimmed[2:len(line_trimmed)-2]
            current_section = strings.clone(section_name, allocator = alloc)

            // Handle dotted array names like [[profile.work.aliases]]
            if strings.contains(section_name, ".") {
                parts := strings.split(section_name, ".")
                defer delete(parts)

                current_map := &doc.values
                for i := 0; i < len(parts) - 1; i += 1 {
                    part := parts[i]

                    if existing, ok := current_map[part]; ok {
                        if existing.type != .TABLE {
                            existing.type = .TABLE
                            existing.table_val = make(map[string]^TomlValue, allocator = alloc)
                        }
                        current_map = &existing.table_val
                    } else {
                        new_table := new(TomlValue, allocator = alloc)
                        new_table.type = .TABLE
                        new_table.table_val = make(map[string]^TomlValue, allocator = alloc)
                        current_map[part] = new_table
                        current_map = &new_table.table_val
                    }
                }

                array_name := parts[len(parts) - 1]

                arr_val, ok := current_map[array_name]
                if !ok {
                    arr_val = new(TomlValue, allocator = alloc)
                    arr_val.type = .ARRAY
                    arr_val.arr_val = make([dynamic]TomlValue, allocator = alloc)
                    current_map[array_name] = arr_val
                } else if arr_val.type != .ARRAY {
                    arr_val.type = .ARRAY
                    arr_val.arr_val = make([dynamic]TomlValue, allocator = alloc)
                }

                new_table: TomlValue
                new_table.type = .TABLE
                new_table.table_val = make(map[string]^TomlValue, allocator = alloc)
                append(&arr_val.arr_val, new_table)
                current_array_idx = len(arr_val.arr_val) - 1
            } else {
                arr_val, ok := doc.values[current_section]
                if !ok {
                    arr_val = new(TomlValue, allocator = alloc)
                    arr_val.type = .ARRAY
                    arr_val.arr_val = make([dynamic]TomlValue, allocator = alloc)
                    doc.values[current_section] = arr_val
                } else if arr_val.type != .ARRAY {
                    arr_val.type = .ARRAY
                    arr_val.arr_val = make([dynamic]TomlValue, allocator = alloc)
                }

                new_table: TomlValue
                new_table.type = .TABLE
                new_table.table_val = make(map[string]^TomlValue, allocator = alloc)
                append(&arr_val.arr_val, new_table)
                current_array_idx = len(arr_val.arr_val) - 1
            }
            continue
        }

        // Check for regular table [section] or [section.subsection]
        if strings.has_prefix(line_trimmed, "[") && strings.has_suffix(line_trimmed, "]") && !strings.has_prefix(line_trimmed, "[[") {
            section_name := line_trimmed[1:len(line_trimmed)-1]
            current_section = strings.clone(section_name, allocator = alloc)
            current_array_idx = -1

            if strings.contains(section_name, ".") {
                parts := strings.split(section_name, ".")
                defer delete(parts)

                current_map := &doc.values
                for i := 0; i < len(parts); i += 1 {
                    part := parts[i]

                    if existing, ok := current_map[part]; ok {
                        if existing.type != .TABLE {
                            existing.type = .TABLE
                            existing.table_val = make(map[string]^TomlValue, allocator = alloc)
                        }
                        current_map = &existing.table_val
                    } else {
                        new_table := new(TomlValue, allocator = alloc)
                        new_table.type = .TABLE
                        new_table.table_val = make(map[string]^TomlValue, allocator = alloc)
                        current_map[part] = new_table
                        current_map = &new_table.table_val
                    }
                }
            } else {
                if _, ok := doc.values[current_section]; !ok {
                    table_val := new(TomlValue, allocator = alloc)
                    table_val.type = .TABLE
                    table_val.table_val = make(map[string]^TomlValue, allocator = alloc)
                    doc.values[current_section] = table_val
                }
            }
            continue
        }

        // Parse key = value
        if strings.contains(line_trimmed, "=") {
            eq_idx := strings.index(line_trimmed, "=")
            if eq_idx > 0 {
                key := strings.trim_space(line_trimmed[:eq_idx])
                value_str := strings.trim_space(line_trimmed[eq_idx+1:])

                val := parse_toml_value_simple(value_str, alloc)
				if val == nil { return {}, false }

                if current_array_idx >= 0 && len(current_section) > 0 {
                    if strings.contains(current_section, ".") {
                        parts := strings.split(current_section, ".")
                        defer delete(parts)

                        current_map := &doc.values
                        for i := 0; i < len(parts) - 1; i += 1 {
                            part := parts[i]
                            if existing, ok := current_map[part]; ok && existing.type == .TABLE {
                                current_map = &existing.table_val
                            } else {
                                break
                            }
                        }

                        array_name := parts[len(parts) - 1]
                        if arr_val, ok := current_map[array_name]; ok && arr_val.type == .ARRAY {
                            if current_array_idx < len(arr_val.arr_val) {
                                table_ptr := &arr_val.arr_val[current_array_idx]
                                table_ptr.table_val[key] = val
                            }
                        }
                    } else {
                        arr_val := doc.values[current_section]
                        if arr_val != nil && arr_val.type == .ARRAY && current_array_idx < len(arr_val.arr_val) {
                            table_ptr := &arr_val.arr_val[current_array_idx]
                            table_ptr.table_val[key] = val
                        }
                    }
                } else if len(current_section) > 0 {
                    if strings.contains(current_section, ".") {
                        parts := strings.split(current_section, ".")
                        defer delete(parts)

                        current_map := &doc.values
                        for part in parts {
                            if existing, ok := current_map[part]; ok && existing.type == .TABLE {
                                current_map = &existing.table_val
                            } else {
                                break
                            }
                        }
                        current_map[key] = val
                    } else {
                        table_val := doc.values[current_section]
                        if table_val != nil && table_val.type == .TABLE {
                            table_val.table_val[key] = val
                        }
                    }
                } else {
                    doc.values[key] = val
                }
            }
        }
    }

    return doc, true
}

parse_toml_value_simple :: proc(value_str: string, alloc: mem.Allocator) -> ^TomlValue {
    val := new(TomlValue, allocator = alloc)

    s := strings.trim_space(value_str)

	if strings.has_prefix(s, "\"") && strings.has_suffix(s, "\"") {
		val.type = .STRING
		if len(s) >= 2 {
			unescaped := unescape_toml_string(s[1:len(s)-1])
			defer delete(unescaped)
			val.str_val = strings.clone(unescaped, allocator = alloc)
		} else {
			val.str_val = ""
		}
		return val
	}

	if strings.has_prefix(s, "'") && strings.has_suffix(s, "'") {
		val.type = .STRING
		if len(s) >= 2 {
			val.str_val = strings.clone(s[1:len(s)-1], allocator = alloc)
		} else {
			val.str_val = ""
		}
		return val
	}

    if s == "true" {
        val.type = .BOOLEAN
        val.bool_val = true
        return val
    }
    if s == "false" {
        val.type = .BOOLEAN
        val.bool_val = false
        return val
    }

    if n, ok := strconv.parse_int(s); ok {
        val.type = .INTEGER
        val.int_val = n
        return val
    }

    if strings.has_prefix(s, "[") && strings.has_suffix(s, "]") {
        val.type = .ARRAY
        val.arr_val = make([dynamic]TomlValue, allocator = alloc)
        inner := strings.trim_space(s[1:len(s)-1])
        if len(inner) > 0 {
            // Use bracket/quote-aware splitting so nested arrays, inline
            // tables and strings containing commas survive intact.
            elements := split_toml_top_level(inner, alloc)
            defer delete(elements)
            for elem in elements {
                if len(elem) > 0 {
                    parsed_elem := parse_toml_value_simple(elem, alloc)
					if parsed_elem == nil { return nil }
                    append(&val.arr_val, parsed_elem^)
                }
            }
        }
        return val
    }

    // Inline table: { key = value, key2 = value2, ... }
    // Standard TOML inline-table syntax. Nested arrays/tables and quoted
    // strings (which may contain commas) are handled by split_toml_top_level.
    if strings.has_prefix(s, "{") && strings.has_suffix(s, "}") {
        val.type = .TABLE
        val.table_val = make(map[string]^TomlValue, allocator = alloc)
        inner := strings.trim_space(s[1:len(s)-1])
        if len(inner) > 0 {
            pairs := split_toml_top_level(inner, alloc)
            defer delete(pairs)
            for pair in pairs {
                if len(pair) == 0 { continue }
                eq_idx := strings.index(pair, "=")
                if eq_idx <= 0 { continue }
                key := strings.trim_space(pair[:eq_idx])
                value_str := strings.trim_space(pair[eq_idx+1:])
                if len(key) == 0 { continue }
                child := parse_toml_value_simple(value_str, alloc)
				if child == nil { return nil }
                key_clone := strings.clone(key, allocator = alloc)
                val.table_val[key_clone] = child
            }
        }
        return val
    }

	return nil
}

// Split a TOML value-list at top-level commas, ignoring commas that appear
// inside quoted strings, [arrays], or {inline tables}. The returned slice
// header is allocated with the default allocator so callers can release it
// with a plain `delete(parts)`. Substrings are zero-copy views into `s`
// (which lives in the arena), so no per-element cleanup is required.
split_toml_top_level :: proc(s: string, alloc: mem.Allocator) -> []string {
    parts := make([dynamic]string)
    depth_brk := 0   // [ ] depth
    depth_brc := 0   // { } depth
    in_string := false
    string_char: byte = 0
    start := 0

    for i := 0; i < len(s); i += 1 {
        c := s[i]
        if in_string {
            // Quote closes the string only if it's not preceded by an odd
            // number of backslashes - that catches `\"` (escaped) and
            // `\\"` (literal backslash followed by closing quote) correctly.
            if c == string_char {
                bs := 0
                for j := i - 1; j >= 0 && s[j] == '\\'; j -= 1 { bs += 1 }
                if bs % 2 == 0 {
                    in_string = false
                }
            }
            continue
        }
        switch c {
        case '"', '\'':
            in_string = true
            string_char = c
        case '[':
            depth_brk += 1
        case ']':
            if depth_brk > 0 { depth_brk -= 1 }
        case '{':
            depth_brc += 1
        case '}':
            if depth_brc > 0 { depth_brc -= 1 }
        case ',':
            if depth_brk == 0 && depth_brc == 0 {
                segment := strings.trim_space(s[start:i])
                append(&parts, segment)
                start = i + 1
            }
        }
    }
    if start <= len(s) {
        tail := strings.trim_space(s[start:])
        if len(tail) > 0 {
            append(&parts, tail)
        }
    }
    return parts[:]
}

// ============================================================================
// Merged from: toml_mapping.odin
// ============================================================================

// toml_mapping.odin - TomlDoc → TomlConfig mapping and value accessors
//
// Extracted from config_toml.odin (2026-04-24) per code review L2.
// This file owns the translation from the parsed TOML AST (TomlDoc/TomlValue,
// defined in config_toml.odin) into the strongly-typed `TomlConfig` struct
// that the rest of wayu consumes. Pure data-shape translation; no I/O,
// no serialization, no command-handler logic.



// ============================================================================
// TOML TO CONFIG CONVERSION
// ============================================================================

// Extract string array from TOML value
get_string_array :: proc(val: ^TomlValue) -> ([]string, bool) {
	if val == nil || val.type != .ARRAY {
		return nil, false
	}

	n := 0
	for elem in val.arr_val {
		if elem.type == .STRING {
			n += 1
		}
	}

	result := make([]string, n)
	i := 0
	for elem in val.arr_val {
		if elem.type == .STRING {
			result[i] = strings.clone(elem.str_val)
			i += 1
		}
	}

	return result, true
}

// Extract string from TOML value
get_string :: proc(val: ^TomlValue, default: string = "") -> string {
	if val == nil || val.type != .STRING {
		return strings.clone(default)
	}
	return strings.clone(val.str_val)
}

// Extract int from TOML value
get_int :: proc(val: ^TomlValue, default: int = 0) -> int {
	if val == nil || val.type != .INTEGER {
		return default
	}
	return val.int_val
}

// Extract bool from TOML value
get_bool :: proc(val: ^TomlValue, default: bool = false) -> bool {
	if val == nil {
		return default
	}
	if val.type == .BOOLEAN {
		return val.bool_val
	}
	if val.type == .STRING {
		return val.str_val == "true"
	}
	return default
}

// Convert TomlDoc to TomlConfig
// Section parsers used by doc_to_config. Each extracts one [section]
// from the parsed TomlDoc into the typed TomlConfig struct.

@(private = "file")
doc_parse_base_fields :: proc(doc: ^TomlDoc, config: ^TomlConfig) {
	config.version = get_string(get_toml_value(doc, "version"), "1.0")
	config.shell = get_string(get_toml_value(doc, "shell"), "zsh")
	config.wayu_version = get_string(get_toml_value(doc, "wayu_version"), VERSION)
}

@(private = "file")
doc_parse_paths_section :: proc(doc: ^TomlDoc, config: ^TomlConfig) {
	paths_val := get_toml_value(doc, "paths")
	if paths_val != nil && paths_val.type == .TABLE {
		paths_entries := make([dynamic]string)
		names := make([dynamic]string)
		defer delete(names)
		for name, _ in paths_val.table_val { append(&names, name) }
		for i := 1; i < len(names); i += 1 {
			j := i
			for j > 0 && names[j-1] > names[j] {
				names[j-1], names[j] = names[j], names[j-1]
				j -= 1
			}
		}
		for n in names {
			v := paths_val.table_val[n]
			if v != nil && v.type == .STRING {
				append(&paths_entries, strings.clone(v.str_val))
			}
		}
		config.path.entries = paths_entries[:]
	}
	config.path.dedup = get_bool(get_toml_value(doc, "path.dedup"), true)
	config.path.clean = get_bool(get_toml_value(doc, "path.clean"), false)
}

@(private = "file")
doc_parse_aliases_section :: proc(doc: ^TomlDoc, aliases: ^[dynamic]TomlAlias) {
	val := get_toml_value(doc, "aliases")
	if val == nil || val.type != .TABLE { return }
	for name, cmd in val.table_val {
		if cmd == nil || cmd.type != .STRING { continue }
		append(aliases, TomlAlias{
			name = strings.clone(name),
			command = strings.clone(cmd.str_val),
		})
	}
}

@(private = "file")
doc_parse_env_section :: proc(doc: ^TomlDoc, constants: ^[dynamic]TomlConstant) {
	val := get_toml_value(doc, "env")
	if val == nil || val.type != .TABLE { return }
	for name, v in val.table_val {
		if v == nil || v.type != .STRING { continue }
		append(constants, TomlConstant{
			name = strings.clone(name),
			value = strings.clone(v.str_val),
			export = true,
		})
	}
}

@(private = "file")
doc_parse_plugins_section :: proc(doc: ^TomlDoc, plugins: ^[dynamic]TomlPlugin) {
	val := get_toml_value(doc, "plugins")
	if val == nil || val.type != .ARRAY { return }
	for t in val.arr_val {
		if t.type != .TABLE { continue }
		p: TomlPlugin
		if v, ok := t.table_val["name"]; ok && v.type == .STRING { p.name = strings.clone(v.str_val) }
		if v, ok := t.table_val["source"]; ok && v.type == .STRING { p.source = strings.clone(v.str_val) }
		if v, ok := t.table_val["version"]; ok && v.type == .STRING { p.version = strings.clone(v.str_val) }
		if v, ok := t.table_val["defer"]; ok { p.defer_load = get_bool(v, false) }
		if v, ok := t.table_val["priority"]; ok { p.priority = get_int(v, 100) } else { p.priority = 100 }
		if v, ok := t.table_val["condition"]; ok && v.type == .STRING { p.condition = strings.clone(v.str_val) }
		if v, ok := t.table_val["description"]; ok && v.type == .STRING { p.description = strings.clone(v.str_val) }
		if v, ok := t.table_val["use"]; ok && v.type == .ARRAY {
			use_files, _ := get_string_array(v)
			p.use = use_files
		}
		if len(p.name) > 0 { append(plugins, p) }
	}
}

@(private = "file")
doc_parse_profile_aliases :: proc(val: ^TomlValue, out: ^[dynamic]TomlAlias) {
	if val == nil { return }
	if val.type == .TABLE {
		for name, cmd in val.table_val {
			if cmd.type == .STRING {
				append(out, TomlAlias{name = strings.clone(name), command = strings.clone(cmd.str_val)})
			}
		}
	} else if val.type == .ARRAY {
		for t in val.arr_val {
			if t.type != .TABLE { continue }
			a: TomlAlias
			if v, ok := t.table_val["name"]; ok && v.type == .STRING { a.name = strings.clone(v.str_val) }
			if v, ok := t.table_val["command"]; ok && v.type == .STRING { a.command = strings.clone(v.str_val) }
			if len(a.name) > 0 { append(out, a) }
		}
	}
}

@(private = "file")
doc_parse_profile_constants :: proc(val: ^TomlValue, out: ^[dynamic]TomlConstant) {
	if val == nil { return }
	if val.type == .TABLE {
		for name, v in val.table_val {
			if v.type == .STRING {
				append(out, TomlConstant{name = strings.clone(name), value = strings.clone(v.str_val), export = true})
			}
		}
	} else if val.type == .ARRAY {
		for t in val.arr_val {
			if t.type != .TABLE { continue }
			c: TomlConstant
			if v, ok := t.table_val["name"]; ok && v.type == .STRING { c.name = strings.clone(v.str_val) }
			if v, ok := t.table_val["value"]; ok && v.type == .STRING { c.value = strings.clone(v.str_val) }
			if len(c.name) > 0 { append(out, c) }
		}
	}
}

@(private = "file")
doc_parse_profile_plugins :: proc(val: ^TomlValue, out: ^[dynamic]TomlPlugin) {
	if val == nil || val.type != .ARRAY { return }
	for t in val.arr_val {
		if t.type != .TABLE { continue }
		p: TomlPlugin
		if v, ok := t.table_val["name"]; ok && v.type == .STRING { p.name = strings.clone(v.str_val) }
		if len(p.name) > 0 { append(out, p) }
	}
}

@(private = "file")
doc_parse_profiles_section :: proc(doc: ^TomlDoc, config: ^TomlConfig) {
	val := get_toml_value(doc, "profile")
	if val == nil || val.type != .TABLE { return }
	for name, t in val.table_val {
		if t.type != .TABLE { continue }
		profile: ProfileConfig
		if path_val, ok := t.table_val["path"]; ok && path_val.type == .TABLE {
			profile.path = new(TomlPathConfig)
			if v, ok2 := path_val.table_val["entries"]; ok2 && v.type == .ARRAY {
				profile.path.entries, _ = get_string_array(v)
			}
			profile.path.dedup = get_bool(path_val.table_val["dedup"], true)
			profile.path.clean = get_bool(path_val.table_val["clean"], false)
		}
		aliases_dyn := make([dynamic]TomlAlias)
		constants_dyn := make([dynamic]TomlConstant)
		plugins_dyn := make([dynamic]TomlPlugin)
		doc_parse_profile_aliases(t.table_val["aliases"], &aliases_dyn)
		doc_parse_profile_constants(t.table_val["constants"], &constants_dyn)
		doc_parse_profile_plugins(t.table_val["plugins"], &plugins_dyn)
		profile.aliases = make([]TomlAlias, len(aliases_dyn)); copy(profile.aliases, aliases_dyn[:])
		profile.constants = make([]TomlConstant, len(constants_dyn)); copy(profile.constants, constants_dyn[:])
		profile.plugins = make([]TomlPlugin, len(plugins_dyn)); copy(profile.plugins, plugins_dyn[:])
		delete(aliases_dyn); delete(constants_dyn); delete(plugins_dyn)
		if v, ok := t.table_val["condition"]; ok && v.type == .STRING { profile.condition = strings.clone(v.str_val) }
		config.profiles[strings.clone(name)] = profile
	}
}

@(private = "file")
doc_parse_settings_section :: proc(doc: ^TomlDoc, config: ^TomlConfig) {
	val := get_toml_value(doc, "settings")
	if val == nil || val.type != .TABLE { return }
	if v, ok := val.table_val["auto_backup"]; ok { config.settings.auto_backup = get_bool(v, true) }
	if v, ok := val.table_val["fuzzy_fallback"]; ok { config.settings.fuzzy_fallback = get_bool(v, true) }
	if v, ok := val.table_val["dry_run_default"]; ok { config.settings.dry_run_default = get_bool(v, false) }
	if v, ok := val.table_val["autosuggestions_accept_keys"]; ok && v.type == .ARRAY {
		if keys, ok2 := get_string_array(v); ok2 { config.settings.autosuggestions_accept_keys = keys }
	}
	if config.settings.autosuggestions_accept_keys == nil || len(config.settings.autosuggestions_accept_keys) == 0 {
		config.settings.autosuggestions_accept_keys = default_autosuggest_keys()
	}
}

// Convert a parsed TomlDoc into the strongly-typed TomlConfig struct.
doc_to_config :: proc(doc: ^TomlDoc) -> (TomlConfig, bool) {
	config: TomlConfig

	doc_parse_base_fields(doc, &config)
	doc_parse_paths_section(doc, &config)

	aliases_dyn := make([dynamic]TomlAlias)
	constants_dyn := make([dynamic]TomlConstant)
	plugins_dyn := make([dynamic]TomlPlugin)
	doc_parse_aliases_section(doc, &aliases_dyn)
	doc_parse_env_section(doc, &constants_dyn)
	doc_parse_plugins_section(doc, &plugins_dyn)

	config.aliases = make([]TomlAlias, len(aliases_dyn)); copy(config.aliases, aliases_dyn[:])
	config.constants = make([]TomlConstant, len(constants_dyn)); copy(config.constants, constants_dyn[:])
	config.plugins = make([]TomlPlugin, len(plugins_dyn)); copy(config.plugins, plugins_dyn[:])
	delete(aliases_dyn); delete(constants_dyn); delete(plugins_dyn)

	doc_parse_profiles_section(doc, &config)
	doc_parse_settings_section(doc, &config)

	return config, true
}

// ============================================================================
// Table editor - line-level, in-place edits of one `[section]` table
// ============================================================================
//
// Mutations never re-serialise a table. They locate the physical lines of the
// one entry being changed and splice only those, so everything else —
// declaration order (PATH precedence!), comments, blank lines, multi-line
// strings, arrays, ints, keys wayu doesn't understand — stays byte-identical.

// Physical line range [first, last] (0-based, inclusive) of one
// `key = value` entry. A multi-line string or array spans several lines.
// `key` is unquoted and aliases the scanned content.
TomlEntrySpan :: struct {
	key:   string,
	first: int,
	last:  int,
}

TomlTableScan :: struct {
	header:   int, // line index of the `[section]` header, -1 when absent
	end:      int, // exclusive line index where the table ends
	entries:  [dynamic]TomlEntrySpan,
	bad_line: int, // 1-based line of a value that never terminates, 0 when ok
}

// Multi-line value tracking across physical lines.
@(private = "file")
TomlValueScan :: struct {
	depth: int,  // open `[` / `{` outside strings
	ml:    byte, // 0, or the quote char of an open `"""` / `'''` string
}

// Advance `st` over one physical line of a value. Single-line strings cannot
// span lines, so they are skipped within the line; `#` outside a string ends
// the line.
@(private = "file")
toml_value_scan_line :: proc(s: string, st: ^TomlValueScan) {
	i := 0
	for i < len(s) {
		c := s[i]
		if st.ml != 0 {
			if c == '\\' && st.ml == '"' { i += 2; continue }
			if c == st.ml && i + 2 < len(s) && s[i+1] == c && s[i+2] == c {
				st.ml = 0
				i += 3
				// Up to two quotes may directly precede the closing delimiter.
				for i < len(s) && s[i] == c { i += 1 }
				continue
			}
			i += 1
			continue
		}
		switch c {
		case '#':
			return
		case '"', '\'':
			if i + 2 < len(s) && s[i+1] == c && s[i+2] == c {
				st.ml = c
				i += 3
				continue
			}
			j := i + 1
			for j < len(s) && s[j] != c {
				if c == '"' && s[j] == '\\' { j += 1 }
				j += 1
			}
			i = j + 1
			continue
		case '[', '{':
			st.depth += 1
		case ']', '}':
			if st.depth > 0 { st.depth -= 1 }
		}
		i += 1
	}
}

// `"my key"` → `my key`; bare keys are returned as-is.
@(private = "file")
toml_unquote_key :: proc(key: string) -> string {
	n := len(key)
	if n >= 2 && (key[0] == '"' || key[0] == '\'') && key[n-1] == key[0] {
		return key[1:n-1]
	}
	return key
}

// Locate `[section]` in `lines` and every entry inside it. Lines that are not
// `key = value` (comments, blanks, junk) are not entries and are never
// touched by the editors below. Caller deletes `entries`.
toml_scan_table :: proc(lines: []string, section: string, allocator := context.allocator) -> TomlTableScan {
	scan := TomlTableScan{header = -1, end = len(lines)}
	scan.entries = make([dynamic]TomlEntrySpan, allocator)

	for line, i in lines {
		if toml_line_is_section(strings.trim_space(line), section) {
			scan.header = i
			break
		}
	}
	if scan.header < 0 { return scan }

	for i := scan.header + 1; i < len(lines); i += 1 {
		trimmed := strings.trim_space(lines[i])
		if strings.has_prefix(trimmed, "[") {
			scan.end = i
			return scan
		}
		if len(trimmed) == 0 || trimmed[0] == '#' { continue }
		eq := strings.index_byte(trimmed, '=')
		if eq < 1 { continue }

		first := i
		st: TomlValueScan
		toml_value_scan_line(trimmed[eq+1:], &st)
		for st.ml != 0 || st.depth > 0 {
			i += 1
			if i >= len(lines) {
				// Unterminated value: refuse to guess where it ends.
				scan.bad_line = first + 1
				scan.end = len(lines)
				return scan
			}
			toml_value_scan_line(lines[i], &st)
		}
		append(&scan.entries, TomlEntrySpan{
			key   = toml_unquote_key(strings.trim_space(trimmed[:eq])),
			first = first,
			last  = i,
		})
	}
	return scan
}

// Set `key` in `[section]` to `entry_line` (a full `key = value` line).
// An existing entry is replaced where it stands, keeping its indentation and,
// for a single-line entry, its inline comment. A new key is appended after
// the table's last entry; a missing table is appended at the end of the file.
// Returns bad_line > 0 (and no output) when the table holds an unterminated
// value. Caller deletes `out`.
toml_table_set :: proc(content, section, key, entry_line: string) -> (out: string, existed: bool, bad_line: int) {
	lines := strings.split(content, "\n")
	defer delete(lines)
	scan := toml_scan_table(lines, section)
	defer delete(scan.entries)
	if scan.bad_line > 0 { return "", false, scan.bad_line }

	if scan.header < 0 {
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		strings.write_string(&b, content)
		if len(content) > 0 {
			if !strings.has_suffix(content, "\n") { strings.write_byte(&b, '\n') }
			if !strings.has_suffix(content, "\n\n") { strings.write_byte(&b, '\n') }
		}
		fmt.sbprintfln(&b, "[%s]", section)
		fmt.sbprintln(&b, entry_line)
		return strings.clone(strings.to_string(b)), false, 0
	}

	out_lines := make([dynamic]string, 0, len(lines) + 1)
	defer delete(out_lines)

	for e in scan.entries {
		if e.key != key { continue }
		old := lines[e.first]
		indent := old[:len(old) - len(strings.trim_left_space(old))]
		comment := ""
		if e.first == e.last {
			if code, balanced := toml_strip_inline_comment_strict(old); balanced && len(code) < len(old) {
				comment = old[len(strings.trim_right_space(code)):]
			}
		}
		replacement := strings.concatenate({indent, entry_line, comment})
		defer delete(replacement)

		append(&out_lines, ..lines[:e.first])
		append(&out_lines, replacement)
		append(&out_lines, ..lines[e.last+1:])
		return strings.join(out_lines[:], "\n"), true, 0
	}

	insert_at := scan.header + 1
	if n := len(scan.entries); n > 0 {
		insert_at = scan.entries[n-1].last + 1
	} else {
		// Empty table: keep documentation comments right under the header.
		for insert_at < scan.end && strings.has_prefix(strings.trim_space(lines[insert_at]), "#") {
			insert_at += 1
		}
	}
	append(&out_lines, ..lines[:insert_at])
	append(&out_lines, entry_line)
	append(&out_lines, ..lines[insert_at:])
	return strings.join(out_lines[:], "\n"), false, 0
}

// Delete every entry of `[section]` whose key is in `keys`, including all
// continuation lines of multi-line values. Everything else is untouched.
// Returns bad_line > 0 (and no output) when the table holds an unterminated
// value. Caller deletes `out` (also when removed == 0).
toml_table_delete :: proc(content, section: string, keys: []string) -> (out: string, removed: int, bad_line: int) {
	lines := strings.split(content, "\n")
	defer delete(lines)
	scan := toml_scan_table(lines, section)
	defer delete(scan.entries)
	if scan.bad_line > 0 { return "", 0, scan.bad_line }

	drop := make([]bool, len(lines))
	defer delete(drop)
	for e in scan.entries {
		if !slice.contains(keys, e.key) { continue }
		for i in e.first..=e.last { drop[i] = true }
		removed += 1
	}

	out_lines := make([dynamic]string, 0, len(lines))
	defer delete(out_lines)
	for line, i in lines {
		if !drop[i] { append(&out_lines, line) }
	}
	return strings.join(out_lines[:], "\n"), removed, 0
}

// Explain an unterminated value and that nothing was written.
toml_print_bad_line :: proc(section: string, bad_line: int) {
	print_error("wayu.toml line %d: unterminated multi-line value in [%s] — fix it by hand; nothing was written",
		bad_line, section)
}
