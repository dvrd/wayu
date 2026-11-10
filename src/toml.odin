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
//   6. Schema check             - unknown keys / wrong table shapes
//   7. CLI handlers             - wayu toml validate/show/keys
//
// wayu never edits wayu.toml (beyond creating the scaffold): PATH entries,
// aliases and constants are managed in the entry store (entries.odin).

package wayu

import "core:fmt"
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
// absent (path/alias/const dispatchers call it so a deleted wayu.toml doesn't
// read as "not initialized"). If the wayu config directory
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
	FLOAT, // str_val holds the text as written
	DATETIME, // str_val holds the text as written
}

// INTEGER also sets str_val (decimal) so every scalar has a text form.
TomlValue :: struct {
	type:      TomlValueType,
	str_val:   string,
	int_val:   int,
	bool_val:  bool,
	arr_val:   [dynamic]^TomlValue,
	table_val: map[string]^TomlValue,
}

make_toml_table :: proc() -> TomlValue {
	return TomlValue{type = .TABLE, table_val = make(map[string]^TomlValue)}
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
// (toml validate, doctor, backup restore).
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

// Validate TOML configuration
toml_validate :: proc(config: TomlConfig) -> ValidationResult {
	// Check version
	if config.version != "1.0" && config.version != "" {
		return ValidationResult {
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
			return ValidationResult {
				valid = false,
				error_message = fmt.aprintf(
					"Invalid shell: %s (must be zsh, bash, or fish)",
					config.shell,
				),
			}
		}
	}

	return ValidationResult{valid = true, error_message = ""}
}

// ============================================================================
// FILE OPERATIONS
// ============================================================================

TOML_CONFIG_FILE :: "wayu.toml"

// Get default config file path
toml_get_config_path :: proc() -> string {
	return fmt.aprintf("%s/%s", wayu.config, TOML_CONFIG_FILE)
}

// Parse one `key = value` line from a TOML table body into (key, value).
// The inline comment is stripped first, then exactly one MATCHING pair of
// quotes: "basic" strings are unescaped, 'literal' strings are taken
// verbatim, anything else (bare ints/bools) is returned trimmed. An empty
// quoted value (`FOO = ""`) is valid and returned as ok with value "".
// `value` is always heap-allocated (caller deletes); `key` aliases `line`.
toml_parse_kv_line :: proc(line: string) -> (key: string, value: string, ok: bool) {
	trimmed := strings.trim_space(line)
	if len(trimmed) == 0 || trimmed[0] == '#' || trimmed[0] == '[' {
		return
	}
	eq := strings.index_byte(trimmed, '=')
	if eq < 1 {
		return
	}
	key = strings.trim_space(trimmed[:eq])
	if len(key) == 0 {
		return
	}

	raw := strings.trim_space(trimmed[eq + 1:])
	if stripped, balanced := toml_strip_inline_comment_strict(raw); balanced {
		raw = strings.trim_space(stripped)
	}
	n := len(raw)
	switch {
	case n >= 2 && raw[0] == '"' && raw[n - 1] == '"':
		value = unescape_toml_string(raw[1:n - 1])
	case n >= 2 && raw[0] == '\'' && raw[n - 1] == '\'':
		value = strings.clone(raw[1:n - 1])
	case n == 0:
		return "", "", false
	case:
		value = strings.clone(raw)
	}
	return key, value, true
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

TOML_TABLES :: []string{"shell", "settings", "tools", "prompt", "secrets"}

// Tables wayu.toml no longer holds: their entries are managed with
// `wayu <cli> add` in the entry store. Strict validation reports them as
// errors (toml_schema_issues).
TOML_MOVED_TABLES :: [][2]string{{"paths", "path"}, {"aliases", "alias"}, {"env", "const"}}

// The `wayu <cli>` command managing moved table `name`, or "".
@(private = "file")
toml_moved_table_cli :: proc(name: string) -> string {
	for m in TOML_MOVED_TABLES {
		if m[0] == name {
			return m[1]
		}
	}
	return ""
}

@(private = "file")
toml_moved_table_msg :: proc(name: string) -> string {
	return fmt.tprintf(
		"[%s] is not read from wayu.toml: its entries are managed with 'wayu %s add' (stored in %s); move them there and delete the table",
		name,
		toml_moved_table_cli(name),
		entries_file_path(),
	)
}
@(private = "file")
TOML_TOOL_KEYS :: []string{"kind", "args", "eager", "login_only", "init_script", "hook_commands"}
@(private = "file")
TOML_PROMPT_TABLES :: []string {
	"username",
	"hostname",
	"localip",
	"dir",
	"git_branch",
	"character",
	"contexts",
	"interactive",
}

// One finding of toml_schema_issues. `msg` is temp-allocated.
TomlSchemaIssue :: struct {
	line:     int, // 1-based
	msg:      string,
	is_error: bool,
}

// Is the full key path `p` (table path + key) one wayu reads?
@(private = "file")
toml_key_known :: proc(p: []string) -> bool {
	if len(p) == 0 {
		return false
	}
	in_set :: proc(s: string, set: []string) -> bool {return slice.contains(set, s)}
	switch p[0] {
	case "version":
		return len(p) == 1
	case "shell":
		return len(p) == 2 && p[1] == "type"
	case "settings":
		if len(p) == 3 && p[1] == "highlight_styles" {
			return highlight_style_index(p[2]) >= 0
		}
		return(
			len(p) == 2 &&
			in_set(
				p[1],
				{
					"autosuggest",
					"autosuggest_style",
					"autosuggestions_accept_keys",
					"auto_optimize",
					"compinit_guard",
					"defer_plugins",
					"highlight",
					"highlight_styles",
					"lazy_compinit",
				},
			) \
		)
	case "scripts":
		return len(p) == 2 && p[1] == "default_lang"
	case "secrets":
		return len(p) == 2 && p[1] == "backend"
	case "tools":
		return len(p) == 2 || (len(p) == 3 && in_set(p[2], TOML_TOOL_KEYS))
	case "prompt":
		switch len(p) {
		case 2:
			return in_set(p[1], {"enabled", "vi_mode", "format"})
		case 3:
			switch p[1] {
			case "username":
				return in_set(p[2], {"format", "show_always"})
			case "hostname", "localip", "dir", "git_branch":
				return p[2] == "format"
			case "character":
				return in_set(
					p[2],
					{
						"success_symbol",
						"error_symbol",
						"vimcmd_symbol",
						"vimcmd_visual_symbol",
						"vimcmd_replace_symbol",
					},
				)
			case "interactive":
				return in_set(
					p[2],
					{
						"toggle_enabled",
						"toggle_key",
						"transient_enabled",
						"vi_mode_indicator",
						"context_aware",
						"async_rprompt",
						"rprompt_format",
					},
				)
			case "contexts":
				return true
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
	case 1:
		return slice.contains(TOML_TABLES, p[0]) || p[0] == "scripts"
	case 2:
		return(
			p[0] == "tools" ||
			(p[0] == "prompt" && slice.contains(TOML_PROMPT_TABLES, p[1])) ||
			(p[0] == "settings" && p[1] == "highlight_styles") \
		)
	}
	return false
}

// Keys and tables of a parsed wayu.toml that wayu does not read (warnings:
// they have no effect) and top-level tables in the wrong shape (errors: e.g.
// `[[paths]]` instead of `[paths]`), in file order. Unknown tables are
// reported once, not per key. Everything is temp-allocated.
toml_schema_issues :: proc(doc: ^TomlDoc) -> [dynamic]TomlSchemaIssue {
	issues := make([dynamic]TomlSchemaIssue, context.temp_allocator)
	dotted :: proc(p: []string) -> string {return strings.join(p, ".", context.temp_allocator)}

	header_ok := make([]bool, len(doc.headers), context.temp_allocator)
	for h, i in doc.headers {
		if h.invalid || len(h.path) == 0 {
			continue
		}
		name := dotted(h.path)
		switch {
		case len(toml_moved_table_cli(h.path[0])) > 0:
			append(&issues, TomlSchemaIssue{h.line + 1, toml_moved_table_msg(h.path[0]), true})
		case h.array && slice.contains(TOML_TABLES, h.path[0]):
			append(
				&issues,
				TomlSchemaIssue {
					h.line + 1,
					fmt.tprintf(
						"[[%s]]: %s must be a table ([%s]), not an array of tables",
						name,
						h.path[0],
						h.path[0],
					),
					true,
				},
			)
		case h.array:
			append(
				&issues,
				TomlSchemaIssue {
					h.line + 1,
					fmt.tprintf("unknown table [[%s]] (ignored)", name),
					false,
				},
			)
		case !toml_table_known(h.path):
			append(
				&issues,
				TomlSchemaIssue {
					h.line + 1,
					fmt.tprintf("unknown table [%s] (ignored)", name),
					false,
				},
			)
		case:
			header_ok[i] = true
		}
	}

	for e in doc.entries {
		if len(e.key) == 0 {
			continue
		}
		path := make([dynamic]string, context.temp_allocator)
		if e.header >= 0 {
			if !header_ok[e.header] {
				continue
			} // reported with its table
			append(&path, ..doc.headers[e.header].path)
		}
		append(&path, ..e.key)
		p := path[:]
		line := e.first + 1
		if e.header < 0 && len(toml_moved_table_cli(p[0])) > 0 {
			append(&issues, TomlSchemaIssue{line, toml_moved_table_msg(p[0]), true})
			continue
		}
		if len(p) == 1 && slice.contains(TOML_TABLES, p[0]) {
			append(
				&issues,
				TomlSchemaIssue{line, fmt.tprintf("%s must be a table ([%s])", p[0], p[0]), true},
			)
			continue
		}
		if !toml_key_known(p) {
			append(
				&issues,
				TomlSchemaIssue{line, fmt.tprintf("unknown key %s (ignored)", dotted(p)), false},
			)
			continue
		}
		if msg := script_default_lang_issue(p, e.value); len(msg) > 0 {
			append(&issues, TomlSchemaIssue{line, msg, true})
			continue
		}
		if len(p) == 2 && p[0] == "secrets" && p[1] == "backend" {
			word := e.value.str_val if e.value != nil && e.value.type == .STRING else ""
			if _, known := secrets_backend_parse(word); !known {
				append(
					&issues,
					TomlSchemaIssue {
						line,
						"secrets.backend must be one of \"auto\", \"keychain\", \"secret-service\", \"file\"",
						true,
					},
				)
			}
			continue
		}
		if len(p) == 2 &&
		   p[0] == "settings" &&
		   (p[1] == "autosuggest" || p[1] == "highlight") &&
		   (e.value == nil || e.value.type != .BOOLEAN) {
			append(
				&issues,
				TomlSchemaIssue {
					line,
					fmt.tprintf("settings.%s must be true or false", p[1]),
					true,
				},
			)
			continue
		}
		if len(p) == 2 && p[0] == "settings" && p[1] == "highlight_styles" {
			if e.value == nil || e.value.type != .TABLE {
				append(
					&issues,
					TomlSchemaIssue {
						line,
						"settings.highlight_styles must be a table of style = \"spec\" (e.g. { command = \"fg=green\" })",
						true,
					},
				)
				continue
			}
			names := make([dynamic]string, context.temp_allocator)
			for k in e.value.table_val {append(&names, k)}
			slice.sort(names[:])
			for k in names {
				if highlight_style_index(k) < 0 {
					append(
						&issues,
						TomlSchemaIssue {
							line,
							fmt.tprintf("unknown key settings.highlight_styles.%s (ignored)", k),
							false,
						},
					)
				} else if msg := highlight_style_issue(k, e.value.table_val[k]); len(msg) > 0 {
					append(&issues, TomlSchemaIssue{line, msg, true})
				}
			}
			continue
		}
		if len(p) == 3 && p[0] == "settings" && p[1] == "highlight_styles" {
			if msg := highlight_style_issue(p[2], e.value); len(msg) > 0 {
				append(&issues, TomlSchemaIssue{line, msg, true})
			}
			continue
		}
		if len(p) == 2 &&
		   p[0] == "settings" &&
		   p[1] == "autosuggest_style" &&
		   (e.value == nil ||
				   e.value.type != .STRING ||
				   !autosuggest_style_valid(e.value.str_val)) {
			append(
				&issues,
				TomlSchemaIssue {
					line,
					"settings.autosuggest_style must be a highlight spec string like \"fg=8\" (one line, at most 64 bytes)",
					true,
				},
			)
			continue
		}
		// Inline tables of [tools] / [prompt.contexts]: check their keys.
		inline :=
			(len(p) == 2 && p[0] == "tools") ||
			(len(p) == 3 && p[0] == "prompt" && p[1] == "contexts")
		if inline && e.value != nil && e.value.type == .TABLE {
			keys := make([dynamic]string, context.temp_allocator)
			for k in e.value.table_val {append(&keys, k)}
			slice.sort(keys[:])
			for k in keys {
				sub := make([dynamic]string, context.temp_allocator)
				append(&sub, ..p)
				append(&sub, k)
				if !toml_key_known(sub[:]) {
					append(
						&issues,
						TomlSchemaIssue {
							line,
							fmt.tprintf("unknown key %s (ignored)", dotted(sub[:])),
							false,
						},
					)
				}
			}
		}
	}
	slice.stable_sort_by(issues[:], proc(a, b: TomlSchemaIssue) -> bool {return a.line < b.line})
	return issues
}

// toml_schema_issues of `content` (parse errors are toml_check's job).
toml_content_schema_issues :: proc(content: string) -> [dynamic]TomlSchemaIssue {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return make([dynamic]TomlSchemaIssue, context.temp_allocator)
	}
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
		wayu_exit(EXIT_IOERR)
	}
	defer delete(content)

	fmt.print(string(content))
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
		wayu_exit(EXIT_IOERR)
	}
	defer delete(content)

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		wayu_exit(EXIT_IOERR)
	}
	defer virtual.arena_destroy(&arena)
	doc, ok := toml_doc_parse_alloc(string(content), virtual.arena_allocator(&arena))
	if !ok {
		e := doc.errors[0]
		print_error_simple("Failed to parse TOML file: %s (line %d: %s)", toml_file, e.line, e.msg)
		wayu_exit(EXIT_DATAERR)
	}

	// Root `key = value` statements and table headers interleave in file
	// order; a key is printed once however many headers name it.
	seen := make(map[string]bool, context.temp_allocator)
	h, i := 0, 0
	for h < len(doc.headers) || i < len(doc.entries) {
		key: string
		if i < len(doc.entries) &&
		   (h >= len(doc.headers) || doc.entries[i].first < doc.headers[h].line) {
			e := doc.entries[i]
			i += 1
			if e.header != -1 || len(e.key) == 0 {
				continue
			}
			key = e.key[0]
		} else {
			hd := doc.headers[h]
			h += 1
			if len(hd.path) == 0 {
				continue
			}
			key = hd.path[0]
		}
		if key in seen {
			continue
		}
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
			wayu_exit(EXIT_CONFIG)
		}
		if !handle_validate() {
			wayu_exit(EXIT_DATAERR)
		}
	case .LIST:
		// Show all TOML keys
		if !check_wayu_initialized() {
			wayu_exit(EXIT_CONFIG)
		}
		handle_toml_keys()
	case .GET:
		// Show TOML content
		if !check_wayu_initialized() {
			wayu_exit(EXIT_CONFIG)
		}
		handle_toml_show()
	case .HELP:
		print_toml_usage()
	case:
		fmt.eprintln("Unknown toml action")
		print_toml_usage()
		wayu_exit(EXIT_USAGE)
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
	fmt.printfln("  wayu toml show               Display wayu.toml")
	fmt.printfln("  wayu toml keys               List wayu.toml's top-level keys and tables")
	fmt.printfln("  wayu toml help               Show this help")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  Manage wayu configuration through TOML files.")
	fmt.println("  TOML enables declarative, version-controlled configs.")
	fmt.println()
	fmt.printfln("%sFILE LOCATIONS:%s", get_primary(), RESET)
	fmt.printfln("  %s/wayu.toml   Settings you edit by hand", wayu.config)
	fmt.printfln("  %s   PATH entries, aliases, constants (managed by wayu)", entries_file_path())
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  # Validate your TOML config")
	fmt.println("  wayu toml validate")
	fmt.println()
	fmt.println("  # Apply wayu.toml to shell (rebuild init script)")
	fmt.println("  wayu build")
	fmt.println()
	fmt.printfln("%sSee:%s docs/config-reference.md for every key", get_muted(), RESET)
}

// Properly free all memory in a TomlConfig
cleanup_toml_config :: proc(config: ^TomlConfig) {
	delete(config.version)
	delete(config.shell)
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
	for j := i - 1; j >= 0 && s[j] == '\\'; j -= 1 {bs += 1}
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

@(private = "file")
doc_parse_settings_section :: proc(doc: ^TomlDoc, config: ^TomlConfig) {
	val := get_toml_value(doc, "settings")
	if val == nil || val.type != .TABLE {
		return
	}
	if v, ok := val.table_val["autosuggestions_accept_keys"]; ok && v.type == .ARRAY {
		if keys, ok2 := get_string_array(v); ok2 {
			config.settings.autosuggestions_accept_keys = keys
		}
	}
	if config.settings.autosuggestions_accept_keys == nil ||
	   len(config.settings.autosuggestions_accept_keys) == 0 {
		config.settings.autosuggestions_accept_keys = default_autosuggest_keys()
	}
}

// Convert a parsed TomlDoc into the strongly-typed TomlConfig struct.
doc_to_config :: proc(doc: ^TomlDoc) -> (TomlConfig, bool) {
	config: TomlConfig

	doc_parse_base_fields(doc, &config)
	doc_parse_settings_section(doc, &config)

	return config, true
}
