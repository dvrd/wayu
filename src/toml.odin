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
//   7. Schema check             - unknown keys / wrong table shapes
//   8. CLI handlers             - wayu toml validate/show/keys

package wayu

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"


// ============================================================================
// Merged from: config_toml.odin
// ============================================================================

// config_toml.odin - TOML configuration file support for wayu
//
// This module provides TOML parsing and validation for wayu's configuration
// file (the types are in interfaces.odin).



// ============================================================================
// WAYU.TOML BOOTSTRAP
// ============================================================================

// ensure_wayu_toml_exists creates a minimal wayu.toml scaffold if the file is
// absent. Used by alias/constants/path dispatchers so writes always land in
// wayu.toml. If the wayu config directory
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

	scaffold := wayu_toml_scaffold(wayu.shell)
	defer delete(scaffold)

	return init_config_file(toml_file, scaffold)
}

// The one wayu.toml scaffold (ensure_wayu_toml_exists, `wayu init`,
// `wayu config edit`). Caller owns the returned string.
wayu_toml_scaffold :: proc(shell: ShellType) -> string {
	return fmt.aprintf(`[shell]
type = "%s"

[aliases]

[env]
`, shell_config_name(shell))
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
	FLOAT,    // str_val holds the text as written
	DATETIME, // str_val holds the text as written
}

// INTEGER also sets str_val (decimal) so every scalar has a text form.
TomlValue :: struct {
	type: TomlValueType,
	str_val: string,
	int_val: int,
	bool_val: bool,
	arr_val: [dynamic]^TomlValue,
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

// Parsed document (see toml_parse.odin): the value tree plus every header
// and `key = value` statement in file order, and the errors recovered from.
TomlDoc :: struct {
	values:  map[string]^TomlValue,
	headers: [dynamic]TomlHeader,
	entries: [dynamic]TomlEntry,
	errors:  [dynamic]TomlParseError,
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

// Parse TOML content into TomlConfig. Strict: any syntax error fails
// (toml validate, doctor, backup restore). See toml_parse_lenient.
toml_parse :: proc(content: string) -> (TomlConfig, bool) {
	// Growing virtual arena (a fixed 1MB buffer overflowed on ~3000 aliases);
	// doc_to_config copies what it keeps, so the AST is released in one go.
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

// Like toml_parse, but a file with syntax errors still yields everything
// the parser recovered - the same entries `alias list`, the generator etc.
// see. For views (TUI) that must agree with the CLI.
toml_parse_lenient :: proc(content: string) -> TomlConfig {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		return {}
	}
	defer virtual.arena_destroy(&arena)

	doc, _ := toml_doc_parse_alloc(content, virtual.arena_allocator(&arena))
	config, _ := doc_to_config(&doc)
	return config
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

// toml_read_file with toml_parse_lenient. ok=false only when unreadable.
toml_read_file_lenient :: proc(path: string) -> (TomlConfig, bool) {
	content, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return {}, false
	}
	defer delete(content)
	return toml_parse_lenient(string(content)), true
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
print_toml_dry_run :: proc(section, dry_label: string, removed: []string, name := "", value := "", existed := false) {
	// Only the changed keys, values masked if secret-looking. Never dump the
	// whole file: it holds every [env] secret (OKAMI-208).
	// The TUI sets print_quiet; writing here would draw over its screen.
	if print_quiet do return
	print_header("DRY RUN - No changes will be made", EMOJI_INFO)
	fmt.println()
	fmt.printfln("%sWould update wayu.toml [%s] (%s):%s", BRIGHT_CYAN, section, dry_label, RESET)
	for n in removed {
		fmt.printfln("  %s- %s%s", get_error(), n, RESET)
	}
	if len(removed) == 0 {
		fmt.printfln("  %s%c %s = \"%s\"%s", existed ? get_warning() : get_success(),
			existed ? '~' : '+', name, mask_secret_value(name, value), RESET)
	}
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
	key := toml_format_key(name)
	defer delete(key)
	line := fmt.aprintf(`%s = "%s"`, key, escaped)
	defer delete(line)

	new_content, had, bad := toml_table_set(string(content), section, name, line)
	if bad > 0 {
		toml_print_bad_line(section, bad)
		return .MALFORMED, false
	}
	defer delete(new_content)

	if wayu.dry_run {
		print_toml_dry_run(section, dry_label, nil, name, value, had)
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
		print_toml_dry_run(section, dry_label, names)
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
		fmt.eprintln("Run 'wayu init' to create one")
		return false
	}

	content, read_err := os.read_entire_file_from_path(config_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("Error: Failed to read %s", config_path)
		return false
	}
	defer delete(content)
	if valid, perr := toml_check(string(content)); !valid {
		defer delete(perr.msg)
		fmt.eprintfln("Error: Failed to parse %s: line %d: %s", config_path, perr.line, perr.msg)
		return false
	}
	issues := toml_content_schema_issues(string(content))
	for is in issues {
		if is.is_error {
			fmt.eprintfln("Validation failed: line %d: %s", is.line, is.msg)
			return false
		}
	}

	config, _ := toml_parse(string(content))
	defer cleanup_toml_config(&config)

	result := toml_validate(config)

	if !result.valid {
		fmt.eprintfln("Validation failed: %s", result.error_message)
		delete(result.error_message)
		return false
	}

	for is in issues {
		print_warning("line %d: %s", is.line, is.msg)
	}
	fmt.println("✓ TOML config is valid")
	return true
}

// ============================================================================
// Schema check: keys wayu reads (docs/config-reference.md)
// ============================================================================

TOML_TABLES :: []string{"shell", "paths", "aliases", "env", "settings", "tools", "prompt"}
@(private = "file")
TOML_TOOL_KEYS :: []string{"kind", "args", "eager", "login_only", "init_script", "hook_commands"}
@(private = "file")
TOML_PROMPT_TABLES :: []string{"username", "hostname", "localip", "dir", "git_branch", "character", "contexts", "interactive"}

// One finding of toml_schema_issues. `msg` is temp-allocated.
TomlSchemaIssue :: struct {
	line:     int, // 1-based
	msg:      string,
	is_error: bool,
}

// Is the full key path `p` (table path + key) one wayu reads?
@(private = "file")
toml_key_known :: proc(p: []string) -> bool {
	if len(p) == 0 { return false }
	in_set :: proc(s: string, set: []string) -> bool { return slice.contains(set, s) }
	switch p[0] {
	case "version":
		return len(p) == 1
	case "shell":
		return len(p) == 2 && p[1] == "type"
	case "paths", "aliases", "env":
		return len(p) >= 2
	case "settings":
		return len(p) == 2 && p[1] == "autosuggestions_accept_keys"
	case "tools":
		return len(p) == 2 || (len(p) == 3 && in_set(p[2], TOML_TOOL_KEYS))
	case "prompt":
		switch len(p) {
		case 2:
			return in_set(p[1], {"enabled", "vi_mode", "format"})
		case 3:
			switch p[1] {
			case "username":   return in_set(p[2], {"format", "show_always"})
			case "hostname", "localip", "dir", "git_branch": return p[2] == "format"
			case "character":  return in_set(p[2], {"success_symbol", "error_symbol", "vimcmd_symbol", "vimcmd_visual_symbol", "vimcmd_replace_symbol"})
			case "interactive": return in_set(p[2], {"toggle_enabled", "toggle_key", "transient_enabled", "vi_mode_indicator", "context_aware", "async_rprompt", "rprompt_format"})
			case "contexts":   return true
			}
		case 4:
			return p[1] == "contexts" && in_set(p[3], {"format", "detect"})
		}
	}
	return false
}

// Is `[p]` a table header wayu reads?
@(private = "file")
toml_table_known :: proc(p: []string) -> bool {
	switch len(p) {
	case 1: return slice.contains(TOML_TABLES, p[0])
	case 2: return p[0] == "tools" || (p[0] == "prompt" && slice.contains(TOML_PROMPT_TABLES, p[1]))
	}
	return false
}

// Keys and tables of a parsed wayu.toml that wayu does not read (warnings:
// they have no effect) and top-level tables in the wrong shape (errors: e.g.
// `[[paths]]` instead of `[paths]`), in file order. Unknown tables are
// reported once, not per key. Everything is temp-allocated.
toml_schema_issues :: proc(doc: ^TomlDoc) -> [dynamic]TomlSchemaIssue {
	issues := make([dynamic]TomlSchemaIssue, context.temp_allocator)
	dotted :: proc(p: []string) -> string { return strings.join(p, ".", context.temp_allocator) }

	header_ok := make([]bool, len(doc.headers), context.temp_allocator)
	for h, i in doc.headers {
		if h.invalid || len(h.path) == 0 { continue }
		name := dotted(h.path)
		switch {
		case h.array && slice.contains(TOML_TABLES, h.path[0]):
			append(&issues, TomlSchemaIssue{h.line + 1, fmt.tprintf("[[%s]]: %s must be a table ([%s]), not an array of tables", name, h.path[0], h.path[0]), true})
		case h.array:
			append(&issues, TomlSchemaIssue{h.line + 1, fmt.tprintf("unknown table [[%s]] (ignored)", name), false})
		case !toml_table_known(h.path):
			append(&issues, TomlSchemaIssue{h.line + 1, fmt.tprintf("unknown table [%s] (ignored)", name), false})
		case:
			header_ok[i] = true
		}
	}

	for e in doc.entries {
		if len(e.key) == 0 { continue }
		path := make([dynamic]string, context.temp_allocator)
		if e.header >= 0 {
			if !header_ok[e.header] { continue } // reported with its table
			append(&path, ..doc.headers[e.header].path)
		}
		append(&path, ..e.key)
		p := path[:]
		line := e.first + 1
		if len(p) == 1 && slice.contains(TOML_TABLES, p[0]) {
			append(&issues, TomlSchemaIssue{line, fmt.tprintf("%s must be a table ([%s])", p[0], p[0]), true})
			continue
		}
		if !toml_key_known(p) {
			append(&issues, TomlSchemaIssue{line, fmt.tprintf("unknown key %s (ignored)", dotted(p)), false})
			continue
		}
		// Inline tables of [tools] / [prompt.contexts]: check their keys.
		inline := (len(p) == 2 && p[0] == "tools") || (len(p) == 3 && p[0] == "prompt" && p[1] == "contexts")
		if inline && e.value != nil && e.value.type == .TABLE {
			keys := make([dynamic]string, context.temp_allocator)
			for k in e.value.table_val { append(&keys, k) }
			slice.sort(keys[:])
			for k in keys {
				sub := make([dynamic]string, context.temp_allocator)
				append(&sub, ..p)
				append(&sub, k)
				if !toml_key_known(sub[:]) {
					append(&issues, TomlSchemaIssue{line, fmt.tprintf("unknown key %s (ignored)", dotted(sub[:])), false})
				}
			}
		}
	}
	slice.stable_sort_by(issues[:], proc(a, b: TomlSchemaIssue) -> bool { return a.line < b.line })
	return issues
}

// toml_schema_issues of `content` (parse errors are toml_check's job).
toml_content_schema_issues :: proc(content: string) -> [dynamic]TomlSchemaIssue {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { return make([dynamic]TomlSchemaIssue, context.temp_allocator) }
	defer virtual.arena_destroy(&arena)
	doc, _ := toml_doc_parse_alloc(content, virtual.arena_allocator(&arena))
	return toml_schema_issues(&doc)
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

	// Same policy as `const list`: secret-looking [env] values are masked
	// unless --reveal.
	if wayu.reveal_secrets {
		fmt.print(string(content))
		return
	}
	masked := mask_toml_env_section(string(content))
	defer delete(masked)
	fmt.print(masked)
}

// Handle 'wayu toml keys': the top-level keys and tables of wayu.toml, in
// file order, one per line. A file that doesn't parse exits 65 (like
// `toml validate`).
handle_toml_keys :: proc() {
	toml_file := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	defer delete(toml_file)

	content, err := os.read_entire_file_from_path(toml_file, context.allocator)
	if err != nil {
		print_error_simple("Failed to read TOML file: %s", toml_file)
		os.exit(EXIT_IOERR)
	}
	defer delete(content)

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { os.exit(EXIT_IOERR) }
	defer virtual.arena_destroy(&arena)
	doc, ok := toml_doc_parse_alloc(string(content), virtual.arena_allocator(&arena))
	if !ok {
		e := doc.errors[0]
		print_error_simple("Failed to parse TOML file: %s (line %d: %s)", toml_file, e.line, e.msg)
		os.exit(EXIT_DATAERR)
	}

	// Root `key = value` statements and table headers interleave in file
	// order; a key is printed once however many headers name it.
	seen := make(map[string]bool, context.temp_allocator)
	h, i := 0, 0
	for h < len(doc.headers) || i < len(doc.entries) {
		key: string
		if i < len(doc.entries) && (h >= len(doc.headers) || doc.entries[i].first < doc.headers[h].line) {
			e := doc.entries[i]
			i += 1
			if e.header != -1 || len(e.key) == 0 { continue }
			key = e.key[0]
		} else {
			hd := doc.headers[h]
			h += 1
			if len(hd.path) == 0 { continue }
			key = hd.path[0]
		}
		if key in seen { continue }
		seen[key] = true
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
	case .HELP:
		print_toml_usage()
	case:
		fmt.eprintln("Unknown toml action")
		print_toml_usage()
		os.exit(EXIT_USAGE)
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
	fmt.printfln("  wayu toml show               Display TOML content (secrets masked)")
	fmt.printfln("  wayu toml show --reveal      Display TOML content with real [env] values")
	fmt.printfln("  wayu toml keys               List wayu.toml's top-level keys and tables")
	fmt.printfln("  wayu toml help               Show this help")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  Manage wayu configuration through TOML files.")
	fmt.println("  TOML enables declarative, version-controlled configs.")
	fmt.println()
	fmt.printfln("%sFILE LOCATIONS:%s", get_primary(), RESET)
	fmt.printfln("  ~/.config/wayu/wayu.toml         The config (safe to check into git)")
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  # Validate your TOML config")
	fmt.println("  wayu toml validate")
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
	for e in config.path.entries {
		delete(e)
	}
	delete(config.path.entries)
	for alias in config.aliases {
		delete(alias.name)
		delete(alias.command)
	}
	delete(config.aliases)
	for constant in config.constants {
		delete(constant.name)
		delete(constant.value)
	}
	delete(config.constants)
	if config.settings.autosuggestions_accept_keys != nil {
		for k in config.settings.autosuggestions_accept_keys {
			delete(k)
		}
		delete(config.settings.autosuggestions_accept_keys)
	}
}

// ============================================================================
// Single-line helpers (the parser itself lives in toml_parse.odin)
// ============================================================================

// Cut `line` at the first `#` outside a string. ok=false when a string is
// left open on the line.
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
	raw_shell := get_string(get_toml_value(doc, "shell.type"), "zsh")
	config.shell = strings.to_lower(raw_shell)
	delete(raw_shell)
}

// [paths] / [aliases] / [env] go through toml_doc_section_kvs, the reader
// every CLI command and the generator use, so all consumers agree on keys,
// values and FILE ORDER (= PATH priority; the old map walk sorted by key).
@(private = "file")
doc_parse_paths_section :: proc(doc: ^TomlDoc, config: ^TomlConfig) {
	kvs := toml_doc_section_kvs(doc, "paths")
	defer destroy_toml_kvs(&kvs)
	entries := make([dynamic]string)
	for kv in kvs {
		if len(kv.value) == 0 { continue } // an empty PATH entry is meaningless
		append(&entries, strings.clone(kv.value))
	}
	config.path.entries = entries[:]
}

// Duplicate keys (invalid TOML, kept when recovering) resolve like the CLI
// readers: last value, first position. Returns the kept indices into kvs
// paired with the index whose value wins. Caller deletes.
@(private = "file")
kv_dedupe :: proc(kvs: []TomlKV) -> [dynamic][2]int {
	out := make([dynamic][2]int)
	seen := make(map[string]int)
	defer delete(seen)
	for kv, i in kvs {
		if at, dup := seen[kv.key]; dup {
			out[at][1] = i
			continue
		}
		seen[kv.key] = len(out)
		append(&out, [2]int{i, i})
	}
	return out
}

@(private = "file")
doc_parse_aliases_section :: proc(doc: ^TomlDoc, aliases: ^[dynamic]TomlAlias) {
	kvs := toml_doc_section_kvs(doc, "aliases")
	defer destroy_toml_kvs(&kvs)
	kept := kv_dedupe(kvs[:])
	defer delete(kept)
	for k in kept {
		append(aliases, TomlAlias{name = strings.clone(kvs[k[0]].key), command = strings.clone(kvs[k[1]].value)})
	}
}

@(private = "file")
doc_parse_env_section :: proc(doc: ^TomlDoc, constants: ^[dynamic]TomlConstant) {
	kvs := toml_doc_section_kvs(doc, "env")
	defer destroy_toml_kvs(&kvs)
	kept := kv_dedupe(kvs[:])
	defer delete(kept)
	for k in kept {
		append(constants, TomlConstant{name = strings.clone(kvs[k[0]].key), value = strings.clone(kvs[k[1]].value)})
	}
}

@(private = "file")
doc_parse_settings_section :: proc(doc: ^TomlDoc, config: ^TomlConfig) {
	val := get_toml_value(doc, "settings")
	if val == nil || val.type != .TABLE { return }
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
	doc_parse_aliases_section(doc, &aliases_dyn)
	doc_parse_env_section(doc, &constants_dyn)

	config.aliases = make([]TomlAlias, len(aliases_dyn)); copy(config.aliases, aliases_dyn[:])
	config.constants = make([]TomlConstant, len(constants_dyn)); copy(config.constants, constants_dyn[:])
	delete(aliases_dyn); delete(constants_dyn)

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
// `key` is decoded (quotes/escapes; dotted parts joined with '.').
TomlEntrySpan :: struct {
	key:   string,
	first: int,
	last:  int,
}

TomlTableScan :: struct {
	header:   int, // line index of the `[section]` header, -1 when absent
	end:      int, // exclusive line index where the table ends
	entries:  [dynamic]TomlEntrySpan,
	bad_line: int,    // 1-based line of a broken multi-line value, 0 when ok
	bad_msg:  string, // the parser's reason for bad_line
}

// Locate `[section]` and every entry inside it, using the same parser as
// every reader (so keys and value extents agree with what was read). Lines
// that are not `key = value` (comments, blanks, junk) are not entries and
// are never touched by the editors below. A value that opens a multi-line
// construct and does not parse sets bad_line: its extent is unknown, so the
// editors refuse to write. Everything is allocated in `allocator` (pass an
// arena).
toml_scan_table :: proc(content: string, n_lines: int, section: string, allocator: mem.Allocator) -> TomlTableScan {
	scan := TomlTableScan{header = -1, end = n_lines}
	scan.entries = make([dynamic]TomlEntrySpan, allocator)

	doc, _ := toml_doc_parse_alloc(content, allocator)
	hidx := -1
	for h, i in doc.headers {
		if !h.invalid && !h.array && len(h.path) == 1 && h.path[0] == section {
			hidx = i
			scan.header = h.line
			break
		}
	}
	if hidx < 0 { return scan }
	if hidx + 1 < len(doc.headers) { scan.end = doc.headers[hidx + 1].line }

	for e in doc.errors {
		if e.multiline && e.stmt_line > scan.header && e.stmt_line < scan.end {
			scan.bad_line = e.stmt_line + 1
			scan.bad_msg = e.msg
			return scan
		}
	}
	for e in doc.entries {
		if e.header != hidx { continue }
		append(&scan.entries, TomlEntrySpan{key = toml_entry_name(e, allocator), first = e.first, last = e.last})
	}
	return scan
}

// Set `key` in `[section]` to `entry_line` (a full `key = value` line).
// An existing entry is replaced where it stands, keeping its indentation and,
// for a single-line entry, its inline comment. A new key is appended after
// the table's last entry; a missing table is appended at the end of the file.
// Returns bad_line > 0 (and no output) when the table holds a broken
// multi-line value. Caller deletes `out`.
toml_table_set :: proc(content, section, key, entry_line: string) -> (out: string, existed: bool, bad_line: int) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { return "", false, 1 }
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

	lines := strings.split(content, "\n", scratch)
	scan := toml_scan_table(content, len(lines), section, scratch)
	if scan.bad_line > 0 {
		toml_last_bad_msg_set(scan.bad_msg)
		return "", false, scan.bad_line
	}

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

	out_lines := make([dynamic]string, 0, len(lines) + 1, scratch)

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
		replacement := strings.concatenate({indent, entry_line, comment}, scratch)

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
// Returns bad_line > 0 (and no output) when the table holds a broken
// multi-line value. Caller deletes `out` (also when removed == 0).
toml_table_delete :: proc(content, section: string, keys: []string) -> (out: string, removed: int, bad_line: int) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { return "", 0, 1 }
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

	lines := strings.split(content, "\n", scratch)
	scan := toml_scan_table(content, len(lines), section, scratch)
	if scan.bad_line > 0 {
		toml_last_bad_msg_set(scan.bad_msg)
		return "", 0, scan.bad_line
	}

	drop := make([]bool, len(lines), scratch)
	for e in scan.entries {
		if !slice.contains(keys, e.key) { continue }
		for i in e.first..=e.last { drop[i] = true }
		removed += 1
	}

	out_lines := make([dynamic]string, 0, len(lines), scratch)
	for line, i in lines {
		if !drop[i] { append(&out_lines, line) }
	}
	return strings.join(out_lines[:], "\n"), removed, 0
}

// Parser reason for the last bad_line returned by the editors (shown by
// toml_print_bad_line).
@(private = "file")
toml_last_bad_msg: [256]byte
@(private = "file")
toml_last_bad_msg_len: int

@(private = "file")
toml_last_bad_msg_set :: proc(msg: string) {
	toml_last_bad_msg_len = copy(toml_last_bad_msg[:], msg)
}

// Explain a broken multi-line value and that nothing was written.
toml_print_bad_line :: proc(section: string, bad_line: int) {
	reason := string(toml_last_bad_msg[:toml_last_bad_msg_len])
	if len(reason) == 0 { reason = "unterminated multi-line value" }
	print_error("wayu.toml line %d: %s in [%s] — fix it by hand; nothing was written",
		bad_line, reason, section)
}
