// toml.odin - TOML parsing, mapping, serialization, and `wayu toml` commands
//
// Single source of truth for everything TOML in wayu. Replaces the previous
// 5-file split (config_toml.odin / config_toml_simple.odin / toml_mapping.odin /
// toml_serialize.odin / toml_section_writer.odin) which fragmented one
// concept across files for no architectural reason.
//
// Layers, top to bottom:
//   1. TomlValue / TomlDoc      — parsed AST types
//   2. Parser                   — string -> TomlDoc (arena-backed)
//   3. Accessors                — TomlValue -> typed primitives
//   4. Mapping                  — TomlDoc -> TomlConfig (typed config)
//   5. File I/O                 — read_file / write_file + ensure_exists
//   6. Section writer           — replace one [section] in-place
//   7. Serialization            — TomlConfig -> canonical TOML text
//   8. Profile merging          — pick + merge active profile
//   9. CLI handlers             — wayu toml init/show/keys/...

package wayu

import "core:fmt"
import "core:mem"
import "core:os"
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
	if !os.exists(g_ctx.wayu_config) {
		return true
	}

	toml_file := fmt.aprintf("%s/wayu.toml", g_ctx.wayu_config)
	defer delete(toml_file)

	if os.exists(toml_file) {
		return true
	}

	shell_name := get_shell_name(g_ctx.shell)
	scaffold := fmt.aprintf(`[shell]
type = "%s"

[aliases]

[env]
`, shell_name)
	defer delete(scaffold)

	return init_config_file(toml_file, scaffold)
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

make_toml_string :: proc(s: string) -> TomlValue {
	return TomlValue{
		type = .STRING,
		str_val = strings.clone(s),
	}
}

make_toml_int :: proc(i: int) -> TomlValue {
	return TomlValue{
		type = .INTEGER,
		int_val = i,
	}
}

make_toml_bool :: proc(b: bool) -> TomlValue {
	return TomlValue{
		type = .BOOLEAN,
		bool_val = b,
	}
}

make_toml_array :: proc() -> TomlValue {
	return TomlValue{
		type = .ARRAY,
		arr_val = make([dynamic]TomlValue),
	}
}

make_toml_table :: proc() -> TomlValue {
	return TomlValue{
		type = .TABLE,
		table_val = make(map[string]^TomlValue),
	}
}

destroy_toml_value :: proc(v: ^TomlValue) {
	switch v.type {
	case .STRING:
		delete(v.str_val)
	case .ARRAY:
		for &elem in v.arr_val {
			destroy_toml_value(&elem)
		}
		delete(v.arr_val)
	case .TABLE:
		for _, val in v.table_val {
			destroy_toml_value(val)
			free(val)
		}
		delete(v.table_val)
	case .INTEGER, .BOOLEAN:
		// Nothing to free
	}
}

// ============================================================================
// TOML DOCUMENT
// ============================================================================

TomlDoc :: struct {
	values: map[string]^TomlValue,
}

make_toml_doc :: proc() -> TomlDoc {
	return TomlDoc{
		values = make(map[string]^TomlValue),
	}
}

destroy_toml_doc :: proc(doc: ^TomlDoc) {
	for _, val in doc.values {
		destroy_toml_value(val)
		free(val)
	}
	delete(doc.values)
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

// Set value in doc by key path
set_toml_value :: proc(doc: ^TomlDoc, key: string, value: ^TomlValue) {
	parts := strings.split(key, ".")
	defer delete(parts)
	
	if len(parts) == 0 {
		return
	}
	
	if len(parts) == 1 {
		// Top-level key
		if existing, ok := doc.values[key]; ok {
			destroy_toml_value(existing)
			free(existing)
		}
		doc.values[key] = value
		return
	}
	
	// Create nested tables as needed
	current_table := doc.values
	for i := 0; i < len(parts) - 1; i += 1 {
		part := parts[i]
		
		next_table: map[string]^TomlValue
		if existing, ok := current_table[part]; ok {
			if existing.type == .TABLE {
				next_table = existing.table_val
			} else {
				// Replace with table
				destroy_toml_value(existing)
				table_val := make_toml_table()
				existing^ = table_val
				next_table = existing.table_val
			}
		} else {
			new_table := new(TomlValue)
			new_table^ = make_toml_table()
			current_table[part] = new_table
			next_table = new_table.table_val
		}
		
		// Move to next level
		current_table = next_table
	}
	
	// Set final value
	last_key := parts[len(parts) - 1]
	if existing, ok := current_table[last_key]; ok {
		destroy_toml_value(existing)
		free(existing)
	}
	current_table[last_key] = value
}

// ============================================================================
// PUBLIC API (from interfaces.odin)
// ============================================================================

// Parse TOML content into TomlConfig
toml_parse :: proc(content: string) -> (TomlConfig, bool) {
	// Use arena-based simple parser for reliability
	arena: mem.Arena
	arena_buffer := make([]byte, 1024*1024, context.allocator)
	defer delete(arena_buffer)
	mem.arena_init(&arena, arena_buffer)
	
	doc, ok := toml_doc_parse_simple(content, &arena)
	if !ok {
		return {}, false
	}
	// Note: arena is freed automatically via defer, no need for destroy_toml_doc
	
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
	// failure — wrap the message with aprintf and free the inner copy so
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
	
	// Validate constants — same leak shape as aliases above.
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
	
	// Validate path entries — same pattern.
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

// Write TOML config to file
toml_write_file :: proc(path: string, config: TomlConfig) -> bool {
	content := toml_to_string(config)
	defer delete(content)
	
	err := os.write_entire_file(path, transmute([]byte)content)
	return err == nil
}

// Get default config file path
toml_get_config_path :: proc() -> string {
	return fmt.aprintf("%s/%s", g_ctx.wayu_config, TOML_CONFIG_FILE)
}

// Create default TOML config
toml_create_default :: proc() -> TomlConfig {
	accept_keys := make([]string, 2)
	accept_keys[0] = strings.clone("^Y")
	accept_keys[1] = strings.clone("^[[121;5u")

	config := TomlConfig{
		version = "1.0",
		shell = "zsh",
		wayu_version = VERSION,
		path = TomlPathConfig{
			entries = make([]string, 0),
			dedup = true,
			clean = false,
		},
		aliases = make([]TomlAlias, 0),
		constants = make([]TomlConstant, 0),
		plugins = make([]TomlPlugin, 0),
		profiles = make(map[string]ProfileConfig),
		settings = WayuSettings{
			auto_backup = true,
			fuzzy_fallback = true,
			dry_run_default = false,
			autosuggestions_accept_keys = accept_keys,
		},
	}
	return config
}

// ============================================================================
// COMMAND HANDLERS
// ============================================================================

// Handle `wayu init --toml`
handle_init_toml :: proc() -> bool {
	config_path := toml_get_config_path()
	defer delete(config_path)
	
	// Check if file already exists
	if os.exists(config_path) {
		fmt.printfln("TOML config already exists: %s", config_path)
		fmt.println("Use --force to overwrite")
		return false
	}
	
	// Create default config
	config := toml_create_default()
	defer {
		delete(config.path.entries)
		delete(config.aliases)
		delete(config.constants)
		delete(config.plugins)
		for key in config.settings.autosuggestions_accept_keys {
			delete(key)
		}
		delete(config.settings.autosuggestions_accept_keys)
		for _, profile in config.profiles {
			delete(profile.aliases)
			delete(profile.constants)
			delete(profile.plugins)
			if profile.path != nil {
				delete(profile.path.entries)
				free(profile.path)
			}
		}
		delete(config.profiles)
	}
	
	// Write file
	if !toml_write_file(config_path, config) {
		fmt.eprintfln("Error: Failed to write %s", config_path)
		return false
	}
	
	fmt.printfln("Created TOML config: %s", config_path)
	return true
}

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
	defer {
		delete(config.version)
		delete(config.shell)
		delete(config.wayu_version)
		delete(config.path.entries)
		for key in config.settings.autosuggestions_accept_keys {
			delete(key)
		}
		delete(config.settings.autosuggestions_accept_keys)
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
			delete(plugin.use)
		}
		delete(config.plugins)
		for _, profile in config.profiles {
			delete(profile.aliases)
			delete(profile.constants)
			delete(profile.plugins)
			if profile.path != nil {
				delete(profile.path.entries)
				free(profile.path)
			}
			delete(profile.condition)
		}
		delete(config.profiles)
	}
	
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
	migrate_legacy_to_toml(g_ctx.dry_run)
	return true
}

// Handle 'wayu toml show' - display TOML content
handle_toml_show :: proc() {
	toml_file := fmt.aprintf("%s/%s", g_ctx.wayu_config, WAYU_TOML)
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
	toml_file := fmt.aprintf("%s/%s", g_ctx.wayu_config, WAYU_TOML)
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
		// `toml convert` — legacy shell configs → wayu.toml. This runs even
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



// TomlDocSimple uses an arena for all allocations
toml_doc_parse_simple :: proc(content: string, arena: ^mem.Arena) -> (TomlDoc, bool) {
    doc: TomlDoc
    doc.values = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
    
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
                in_string = false
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
            current_section = strings.clone(section_name, allocator = mem.arena_allocator(arena))
            
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
                            existing.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
                        }
                        current_map = &existing.table_val
                    } else {
                        new_table := new(TomlValue, allocator = mem.arena_allocator(arena))
                        new_table.type = .TABLE
                        new_table.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
                        current_map[part] = new_table
                        current_map = &new_table.table_val
                    }
                }
                
                array_name := parts[len(parts) - 1]
                
                arr_val, ok := current_map[array_name]
                if !ok {
                    arr_val = new(TomlValue, allocator = mem.arena_allocator(arena))
                    arr_val.type = .ARRAY
                    arr_val.arr_val = make([dynamic]TomlValue, allocator = mem.arena_allocator(arena))
                    current_map[array_name] = arr_val
                } else if arr_val.type != .ARRAY {
                    arr_val.type = .ARRAY
                    arr_val.arr_val = make([dynamic]TomlValue, allocator = mem.arena_allocator(arena))
                }
                
                new_table: TomlValue
                new_table.type = .TABLE
                new_table.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
                append(&arr_val.arr_val, new_table)
                current_array_idx = len(arr_val.arr_val) - 1
            } else {
                arr_val, ok := doc.values[current_section]
                if !ok {
                    arr_val = new(TomlValue, allocator = mem.arena_allocator(arena))
                    arr_val.type = .ARRAY
                    arr_val.arr_val = make([dynamic]TomlValue, allocator = mem.arena_allocator(arena))
                    doc.values[current_section] = arr_val
                } else if arr_val.type != .ARRAY {
                    arr_val.type = .ARRAY
                    arr_val.arr_val = make([dynamic]TomlValue, allocator = mem.arena_allocator(arena))
                }
                
                new_table: TomlValue
                new_table.type = .TABLE
                new_table.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
                append(&arr_val.arr_val, new_table)
                current_array_idx = len(arr_val.arr_val) - 1
            }
            continue
        }
        
        // Check for regular table [section] or [section.subsection]
        if strings.has_prefix(line_trimmed, "[") && strings.has_suffix(line_trimmed, "]") && !strings.has_prefix(line_trimmed, "[[") {
            section_name := line_trimmed[1:len(line_trimmed)-1]
            current_section = strings.clone(section_name, allocator = mem.arena_allocator(arena))
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
                            existing.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
                        }
                        current_map = &existing.table_val
                    } else {
                        new_table := new(TomlValue, allocator = mem.arena_allocator(arena))
                        new_table.type = .TABLE
                        new_table.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
                        current_map[part] = new_table
                        current_map = &new_table.table_val
                    }
                }
            } else {
                if _, ok := doc.values[current_section]; !ok {
                    table_val := new(TomlValue, allocator = mem.arena_allocator(arena))
                    table_val.type = .TABLE
                    table_val.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
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
                
                val := parse_toml_value_simple(value_str, arena)
                
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

parse_toml_value_simple :: proc(value_str: string, arena: ^mem.Arena) -> ^TomlValue {
    val := new(TomlValue, allocator = mem.arena_allocator(arena))
    
    s := strings.trim_space(value_str)
    
    if (strings.has_prefix(s, "\"") && strings.has_suffix(s, "\"")) ||
       (strings.has_prefix(s, "'") && strings.has_suffix(s, "'")) {
        val.type = .STRING
        if len(s) >= 2 {
            val.str_val = strings.clone(s[1:len(s)-1], allocator = mem.arena_allocator(arena))
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
        val.arr_val = make([dynamic]TomlValue, allocator = mem.arena_allocator(arena))
        inner := strings.trim_space(s[1:len(s)-1])
        if len(inner) > 0 {
            // Use bracket/quote-aware splitting so nested arrays, inline
            // tables and strings containing commas survive intact.
            elements := split_toml_top_level(inner, arena)
            defer delete(elements)
            for elem in elements {
                if len(elem) > 0 {
                    parsed_elem := parse_toml_value_simple(elem, arena)
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
        val.table_val = make(map[string]^TomlValue, allocator = mem.arena_allocator(arena))
        inner := strings.trim_space(s[1:len(s)-1])
        if len(inner) > 0 {
            pairs := split_toml_top_level(inner, arena)
            defer delete(pairs)
            for pair in pairs {
                if len(pair) == 0 { continue }
                eq_idx := strings.index(pair, "=")
                if eq_idx <= 0 { continue }
                key := strings.trim_space(pair[:eq_idx])
                value_str := strings.trim_space(pair[eq_idx+1:])
                if len(key) == 0 { continue }
                child := parse_toml_value_simple(value_str, arena)
                key_clone := strings.clone(key, allocator = mem.arena_allocator(arena))
                val.table_val[key_clone] = child
            }
        }
        return val
    }

    val.type = .STRING
    val.str_val = strings.clone(s, allocator = mem.arena_allocator(arena))
    return val
}

// Split a TOML value-list at top-level commas, ignoring commas that appear
// inside quoted strings, [arrays], or {inline tables}. The returned slice
// header is allocated with the default allocator so callers can release it
// with a plain `delete(parts)`. Substrings are zero-copy views into `s`
// (which lives in the arena), so no per-element cleanup is required.
split_toml_top_level :: proc(s: string, arena: ^mem.Arena) -> []string {
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
            // number of backslashes — that catches `\"` (escaped) and
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

get_toml_value_simple :: proc(doc: ^TomlDoc, key: string) -> ^TomlValue {
    if strings.contains(key, ".") {
        parts := strings.split(key, ".")
        defer delete(parts)
        
        current_map := &doc.values
        for part in parts {
            if val, ok := current_map[part]; ok {
                if val.type == .TABLE {
                    current_map = &val.table_val
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }
        return nil
    }
    
    if val, ok := doc.values[key]; ok {
        return val
    }
    return nil
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
doc_to_config :: proc(doc: ^TomlDoc) -> (TomlConfig, bool) {
	config: TomlConfig
	
	// Temp dynamic arrays for building slices
	aliases_dyn := make([dynamic]TomlAlias)
	constants_dyn := make([dynamic]TomlConstant)
	plugins_dyn := make([dynamic]TomlPlugin)
	
	// Basic fields
	version_val := get_toml_value(doc, "version")
	config.version = get_string(version_val, "1.0")
	
	shell_val := get_toml_value(doc, "shell")
	config.shell = get_string(shell_val, "zsh")
	
	wayu_version_val := get_toml_value(doc, "wayu_version")
	config.wayu_version = get_string(wayu_version_val, VERSION)
	
	// [paths] table: name = "/path/to/dir".
	paths_val := get_toml_value(doc, "paths")
	if paths_val != nil && paths_val.type == .TABLE {
		paths_entries := make([dynamic]string)
		names := make([dynamic]string)
		defer delete(names)
		for name, _ in paths_val.table_val { append(&names, name) }
		// Sort by key for deterministic order.
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

	path_dedup_val := get_toml_value(doc, "path.dedup")
	config.path.dedup = get_bool(path_dedup_val, true)

	path_clean_val := get_toml_value(doc, "path.clean")
	config.path.clean = get_bool(path_clean_val, false)
	
	// [aliases] table: name = "command".
	aliases_val := get_toml_value(doc, "aliases")
	if aliases_val != nil && aliases_val.type == .TABLE {
		for name, cmd_val in aliases_val.table_val {
			if cmd_val == nil || cmd_val.type != .STRING { continue }
			alias: TomlAlias
			alias.name = strings.clone(name)
			alias.command = strings.clone(cmd_val.str_val)
			append(&aliases_dyn, alias)
		}
	}
	
	// [env] table: NAME = "value". Always exported (no per-entry flags).
	env_val := get_toml_value(doc, "env")
	if env_val != nil && env_val.type == .TABLE {
		for name, val_val in env_val.table_val {
			if val_val == nil || val_val.type != .STRING { continue }
			constant: TomlConstant
			constant.name = strings.clone(name)
			constant.value = strings.clone(val_val.str_val)
			constant.export = true
			append(&constants_dyn, constant)
		}
	}
	
	// Parse plugins
	plugins_val := get_toml_value(doc, "plugins")
	if plugins_val != nil && plugins_val.type == .ARRAY {
		for plugin_table in plugins_val.arr_val {
			if plugin_table.type != .TABLE {
				continue
			}
			
			plugin: TomlPlugin
			if name_val, ok := plugin_table.table_val["name"]; ok && name_val.type == .STRING {
				plugin.name = strings.clone(name_val.str_val)
			}
			if source_val, ok := plugin_table.table_val["source"]; ok && source_val.type == .STRING {
				plugin.source = strings.clone(source_val.str_val)
			}
			if version_val, ok := plugin_table.table_val["version"]; ok && version_val.type == .STRING {
				plugin.version = strings.clone(version_val.str_val)
			}
			if defer_val, ok := plugin_table.table_val["defer"]; ok {
				plugin.defer_load = get_bool(defer_val, false)
			}
			if priority_val, ok := plugin_table.table_val["priority"]; ok {
				plugin.priority = get_int(priority_val, 100)
			} else {
				plugin.priority = 100
			}
			if cond_val, ok := plugin_table.table_val["condition"]; ok && cond_val.type == .STRING {
				plugin.condition = strings.clone(cond_val.str_val)
			}
			if desc_val, ok := plugin_table.table_val["description"]; ok && desc_val.type == .STRING {
				plugin.description = strings.clone(desc_val.str_val)
			}
			
			// Parse use array
			if use_val, ok := plugin_table.table_val["use"]; ok && use_val.type == .ARRAY {
				use_files, _ := get_string_array(use_val)
				plugin.use = use_files
			}
			
			if len(plugin.name) > 0 {
				append(&plugins_dyn, plugin)
			}
		}
	}
	
	// Extract slices from dynamics and free dynamic metadata
	aliases_slice := make([]TomlAlias, len(aliases_dyn))
	copy(aliases_slice, aliases_dyn[:])
	delete(aliases_dyn)
	config.aliases = aliases_slice
	
	constants_slice := make([]TomlConstant, len(constants_dyn))
	copy(constants_slice, constants_dyn[:])
	delete(constants_dyn)
	config.constants = constants_slice
	
	plugins_slice := make([]TomlPlugin, len(plugins_dyn))
	copy(plugins_slice, plugins_dyn[:])
	delete(plugins_dyn)
	config.plugins = plugins_slice
	
	// Parse profiles
	profiles_val := get_toml_value(doc, "profile")
	if profiles_val != nil && profiles_val.type == .TABLE {
		for profile_name, profile_table in profiles_val.table_val {
			if profile_table.type != .TABLE {
				continue
			}
			
			profile: ProfileConfig
			
			// Parse profile path overrides
			if path_val, ok := profile_table.table_val["path"]; ok && path_val.type == .TABLE {
				profile.path = new(TomlPathConfig)
				if entries_val, ok2 := path_val.table_val["entries"]; ok2 && entries_val.type == .ARRAY {
					entries, _ := get_string_array(entries_val)
					profile.path.entries = entries
				}
				if dedup_val, ok2 := path_val.table_val["dedup"]; ok2 {
					profile.path.dedup = get_bool(dedup_val, true)
				}
				if clean_val, ok2 := path_val.table_val["clean"]; ok2 {
					profile.path.clean = get_bool(clean_val, false)
				}
			}
			
			// Temp dynamic arrays for profile
			profile_aliases_dyn := make([dynamic]TomlAlias)
			profile_constants_dyn := make([dynamic]TomlConstant)
			profile_plugins_dyn := make([dynamic]TomlPlugin)
			
			// Parse profile aliases - support both formats
			if aliases_val, ok := profile_table.table_val["aliases"]; ok {
				if aliases_val.type == .TABLE {
					// New format: simple table
					for name, cmd_val in aliases_val.table_val {
						if cmd_val.type == .STRING {
							alias: TomlAlias
							alias.name = strings.clone(name)
							alias.command = strings.clone(cmd_val.str_val)
							append(&profile_aliases_dyn, alias)
						}
					}
				} else if aliases_val.type == .ARRAY {
					// Old format: array of tables
					for alias_table in aliases_val.arr_val {
						if alias_table.type != .TABLE {
							continue
						}
						alias: TomlAlias
						if name_val, ok2 := alias_table.table_val["name"]; ok2 && name_val.type == .STRING {
							alias.name = strings.clone(name_val.str_val)
						}
						if cmd_val, ok2 := alias_table.table_val["command"]; ok2 && cmd_val.type == .STRING {
							alias.command = strings.clone(cmd_val.str_val)
						}
						if len(alias.name) > 0 {
							append(&profile_aliases_dyn, alias)
						}
					}
				}
			}
			
			// Parse profile constants - support both formats
			if constants_val, ok := profile_table.table_val["constants"]; ok {
				if constants_val.type == .TABLE {
					// New format: simple table
					for name, val_val in constants_val.table_val {
						if val_val.type == .STRING {
							constant: TomlConstant
							constant.name = strings.clone(name)
							constant.value = strings.clone(val_val.str_val)
							constant.export = true
							append(&profile_constants_dyn, constant)
						}
					}
				} else if constants_val.type == .ARRAY {
					// Old format: array of tables
					for const_table in constants_val.arr_val {
						if const_table.type != .TABLE {
							continue
						}
						constant: TomlConstant
						if name_val, ok2 := const_table.table_val["name"]; ok2 && name_val.type == .STRING {
							constant.name = strings.clone(name_val.str_val)
						}
						if val_val, ok2 := const_table.table_val["value"]; ok2 && val_val.type == .STRING {
							constant.value = strings.clone(val_val.str_val)
						}
						if len(constant.name) > 0 {
							append(&profile_constants_dyn, constant)
						}
					}
				}
			}
			
			// Parse profile plugins
			if plugins_val, ok := profile_table.table_val["plugins"]; ok && plugins_val.type == .ARRAY {
				for plugin_table in plugins_val.arr_val {
					if plugin_table.type != .TABLE {
						continue
					}
					plugin: TomlPlugin
					if name_val, ok2 := plugin_table.table_val["name"]; ok2 && name_val.type == .STRING {
						plugin.name = strings.clone(name_val.str_val)
					}
					if len(plugin.name) > 0 {
						append(&profile_plugins_dyn, plugin)
					}
				}
			}
			
			// Assign dynamic arrays to profile slices
			pa_slice := make([]TomlAlias, len(profile_aliases_dyn))
			copy(pa_slice, profile_aliases_dyn[:])
			delete(profile_aliases_dyn)
			profile.aliases = pa_slice
			
			pc_slice := make([]TomlConstant, len(profile_constants_dyn))
			copy(pc_slice, profile_constants_dyn[:])
			delete(profile_constants_dyn)
			profile.constants = pc_slice
			
			pp_slice := make([]TomlPlugin, len(profile_plugins_dyn))
			copy(pp_slice, profile_plugins_dyn[:])
			delete(profile_plugins_dyn)
			profile.plugins = pp_slice
			
			// Parse profile condition
			if cond_val, ok := profile_table.table_val["condition"]; ok && cond_val.type == .STRING {
				profile.condition = strings.clone(cond_val.str_val)
			}
			
			config.profiles[profile_name] = profile
		}
	}
	
	// Parse settings
	settings_val := get_toml_value(doc, "settings")
	if settings_val != nil && settings_val.type == .TABLE {
		if auto_backup_val, ok := settings_val.table_val["auto_backup"]; ok {
			config.settings.auto_backup = get_bool(auto_backup_val, true)
		}
		if fuzzy_val, ok := settings_val.table_val["fuzzy_fallback"]; ok {
			config.settings.fuzzy_fallback = get_bool(fuzzy_val, true)
		}
		if dry_run_val, ok := settings_val.table_val["dry_run_default"]; ok {
			config.settings.dry_run_default = get_bool(dry_run_val, false)
		}
		if accept_keys_val, ok := settings_val.table_val["autosuggestions_accept_keys"]; ok && accept_keys_val.type == .ARRAY {
			accept_keys, ok2 := get_string_array(accept_keys_val)
			if ok2 {
				config.settings.autosuggestions_accept_keys = accept_keys
			}
		}
	}
	if config.settings.autosuggestions_accept_keys == nil || len(config.settings.autosuggestions_accept_keys) == 0 {
		keys := make([]string, 2)
		keys[0] = strings.clone("^Y")
		keys[1] = strings.clone("^[[121;5u")
		config.settings.autosuggestions_accept_keys = keys
	}
	
	return config, true
}


// ============================================================================
// Merged from: toml_section_writer.odin
// ============================================================================

// toml_section_writer.odin - Replace a single `[section]` table in a TOML
// file in place. Used by path/alias/env writers so each mutation rewrites
// only its own section and leaves the rest of wayu.toml byte-identical.



// Replace the existing `[<section>]` table (header + body up to the next
// section header) with the supplied body. When `body` is empty, the
// section is removed entirely. When the section doesn't exist yet, it's
// appended at the end. Caller owns the returned string.
//
// `body_lines` is rendered verbatim under a freshly emitted `[<section>]`
// header. Caller is responsible for ordering and formatting; this proc
// just splices.
replace_toml_table_section :: proc(content: string, section: string, body_lines: []string) -> string {
	header := fmt.aprintf("[%s]", section)
	defer delete(header)

	lines := strings.split(content, "\n")
	defer delete(lines)

	out := strings.builder_make()
	defer strings.builder_destroy(&out)

	emit_new_section :: proc(b: ^strings.Builder, section: string, body_lines: []string) {
		fmt.sbprintfln(b, "[%s]", section)
		for line in body_lines {
			fmt.sbprintln(b, line)
		}
	}

	in_target := false
	replaced := false
	for i := 0; i < len(lines); i += 1 {
		trimmed := strings.trim_space(lines[i])

		if trimmed == header {
			in_target = true
			if len(body_lines) > 0 {
				emit_new_section(&out, section, body_lines)
				replaced = true
			} else {
				replaced = true // we're "replacing" with nothing
			}
			continue
		}

		// Closing the target on the next section header (any `[...]`).
		if in_target && strings.has_prefix(trimmed, "[") {
			in_target = false
		}

		if in_target { continue }
		fmt.sbprintln(&out, lines[i])
	}

	result := strings.to_string(out)

	if !replaced && len(body_lines) > 0 {
		// Section didn't exist — append at end with a separator blank line.
		needs_nl := !strings.has_suffix(result, "\n")
		appended := strings.builder_make()
		defer strings.builder_destroy(&appended)
		fmt.sbprint(&appended, result)
		if needs_nl { fmt.sbprint(&appended, "\n") }
		fmt.sbprintln(&appended, "")
		emit_new_section(&appended, section, body_lines)
		return strings.clone(strings.to_string(appended))
	}

	// Tidy: collapse three+ consecutive blank lines into two and trim
	// trailing whitespace so repeated edits don't grow the file.
	return tidy_blank_runs(result)
}

// Collapse runs of 3+ consecutive blank lines into two. Caller owns return.
tidy_blank_runs :: proc(s: string) -> string {
	lines := strings.split(s, "\n")
	defer delete(lines)
	out := strings.builder_make()
	defer strings.builder_destroy(&out)
	blanks := 0
	for line in lines {
		if len(strings.trim_space(line)) == 0 {
			blanks += 1
			if blanks > 2 { continue }
		} else {
			blanks = 0
		}
		fmt.sbprintln(&out, line)
	}
	return strings.clone(strings.to_string(out))
}

// ============================================================================
// Merged from: toml_serialize.odin
// ============================================================================

// toml_serialize.odin - TomlConfig serialization and profile merging
//
// Extracted from config_toml.odin (2026-04-24) per code review L2. Contains:
//   - toml_to_string       — render TomlConfig back to canonical TOML text
//   - toml_merge_profiles  — merge a profile override into a base config
//   - toml_get_active_profile — choose the profile for the current shell env
//
// Pure transforms on TomlConfig values; no I/O and no command dispatch.



// ============================================================================
// SERIALIZATION
// ============================================================================

// Serialize TomlConfig to TOML string
toml_to_string :: proc(config: TomlConfig) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	
	// Header
	fmt.sbprintln(&builder, "# wayu configuration file")
	fmt.sbprintln(&builder, "# Documentation: https://github.com/dvrd/wayu")
	fmt.sbprintln(&builder)
	
	// Basic settings
	fmt.sbprintfln(&builder, "version = \"%s\"", config.version != "" ? config.version : "1.0")
	fmt.sbprintfln(&builder, "shell = \"%s\"", config.shell != "" ? config.shell : "zsh")
	fmt.sbprintfln(&builder, "wayu_version = \"%s\"", VERSION)
	fmt.sbprintln(&builder)
	
	// [paths] table: derived-key = "path"
	if len(config.path.entries) > 0 {
		fmt.sbprintln(&builder, "[paths]")
		taken := make(map[string]bool); defer delete(taken)
		lines := make([dynamic]string); defer { for l in lines { delete(l) }; delete(lines) }
		for entry in config.path.entries {
			k := derive_path_key(entry, taken)
			taken[k] = true
			escaped := escape_toml_string(entry)
			append(&lines, fmt.aprintf("%s = \"%s\"", k, escaped))
			delete(escaped)
		}
		// Sort alphabetically by emitted line (key prefix is the key).
		for i := 1; i < len(lines); i += 1 {
			j := i
			for j > 0 && lines[j-1] > lines[j] {
				lines[j-1], lines[j] = lines[j], lines[j-1]
				j -= 1
			}
		}
		for l in lines { fmt.sbprintln(&builder, l) }
		fmt.sbprintln(&builder)
	}

	// [aliases] table: name = "command"
	if len(config.aliases) > 0 {
		fmt.sbprintln(&builder, "[aliases]")
		lines := make([dynamic]string); defer { for l in lines { delete(l) }; delete(lines) }
		for alias in config.aliases {
			escaped := escape_toml_string(alias.command)
			append(&lines, fmt.aprintf("%s = \"%s\"", alias.name, escaped))
			delete(escaped)
		}
		for i := 1; i < len(lines); i += 1 {
			j := i
			for j > 0 && lines[j-1] > lines[j] {
				lines[j-1], lines[j] = lines[j], lines[j-1]
				j -= 1
			}
		}
		for l in lines { fmt.sbprintln(&builder, l) }
		fmt.sbprintln(&builder)
	}

	// [env] table: NAME = "value". The legacy `export`/`secret`/`description`
	// per-entry flags are dropped — every entry is exported, plain string.
	if len(config.constants) > 0 {
		fmt.sbprintln(&builder, "[env]")
		lines := make([dynamic]string); defer { for l in lines { delete(l) }; delete(lines) }
		for c in config.constants {
			escaped := escape_toml_string(c.value)
			append(&lines, fmt.aprintf("%s = \"%s\"", c.name, escaped))
			delete(escaped)
		}
		for i := 1; i < len(lines); i += 1 {
			j := i
			for j > 0 && lines[j-1] > lines[j] {
				lines[j-1], lines[j] = lines[j], lines[j-1]
				j -= 1
			}
		}
		for l in lines { fmt.sbprintln(&builder, l) }
		fmt.sbprintln(&builder)
	}
	
	// Plugins
	if len(config.plugins) > 0 {
		for plugin in config.plugins {
			fmt.sbprintln(&builder, "[[plugins]]")
			fmt.sbprintfln(&builder, "name = \"%s\"", plugin.name)
			fmt.sbprintfln(&builder, "source = \"%s\"", plugin.source)
			if plugin.version != "" {
				fmt.sbprintfln(&builder, "version = \"%s\"", plugin.version)
			}
			if plugin.defer_load {
				fmt.sbprintln(&builder, "defer = true")
			}
			if plugin.priority != 100 {
				fmt.sbprintfln(&builder, "priority = %d", plugin.priority)
			}
			if plugin.condition != "" {
				fmt.sbprintfln(&builder, "condition = \"%s\"", plugin.condition)
			}
			if plugin.description != "" {
				fmt.sbprintfln(&builder, "description = \"%s\"", plugin.description)
			}
			if len(plugin.use) > 0 {
				fmt.sbprint(&builder, "use = [")
				for u, i in plugin.use {
					if i > 0 {
						fmt.sbprint(&builder, ", ")
					}
					fmt.sbprintf(&builder, "\"%s\"", u)
				}
				fmt.sbprintln(&builder, "]")
			}
			fmt.sbprintln(&builder)
		}
	}
	
	// Settings
	fmt.sbprintln(&builder, "[settings]")
	fmt.sbprintfln(&builder, "auto_backup = %t", config.settings.auto_backup)
	fmt.sbprintfln(&builder, "fuzzy_fallback = %t", config.settings.fuzzy_fallback)
	fmt.sbprintfln(&builder, "dry_run_default = %t", config.settings.dry_run_default)
	if len(config.settings.autosuggestions_accept_keys) > 0 {
		fmt.sbprint(&builder, "autosuggestions_accept_keys = [")
		for key, i in config.settings.autosuggestions_accept_keys {
			if i > 0 {
				fmt.sbprint(&builder, ", ")
			}
			fmt.sbprintf(&builder, "\"%s\"", key)
		}
		fmt.sbprintln(&builder, "]")
	}
	fmt.sbprintln(&builder)
	
	// Profiles
	if len(config.profiles) > 0 {
		for profile_name, profile in config.profiles {
			fmt.sbprintfln(&builder, "[profile.%s]", profile_name)
			
			if profile.path != nil {
				fmt.sbprintfln(&builder, "  [profile.%s.path]", profile_name)
				fmt.sbprint(&builder, "    entries = [")
				for entry, i in profile.path.entries {
					if i > 0 {
						fmt.sbprint(&builder, ", ")
					}
					fmt.sbprintf(&builder, "\"%s\"", entry)
				}
				fmt.sbprintln(&builder, "]")
			}
			
			for alias in profile.aliases {
				fmt.sbprintfln(&builder, "  [[profile.%s.aliases]]", profile_name)
				fmt.sbprintfln(&builder, "    name = \"%s\"", alias.name)
				fmt.sbprintfln(&builder, "    command = \"%s\"", alias.command)
			}
			
			for constant in profile.constants {
				fmt.sbprintfln(&builder, "  [[profile.%s.constants]]", profile_name)
				fmt.sbprintfln(&builder, "    name = \"%s\"", constant.name)
				fmt.sbprintfln(&builder, "    value = \"%s\"", constant.value)
			}
			
			if profile.condition != "" {
				fmt.sbprintfln(&builder, "  condition = \"%s\"", profile.condition)
			}
			
			fmt.sbprintln(&builder)
		}
	}
	
	return strings.clone(strings.to_string(builder))
}

// Merge profile into base config
toml_merge_profiles :: proc(base: TomlConfig, profile_name: string) -> TomlConfig {
	profile, ok := base.profiles[profile_name]
	if !ok {
		// Profile not found, return deep clone of base
		result: TomlConfig
		result.version = strings.clone(base.version)
		result.shell = strings.clone(base.shell)
		result.wayu_version = strings.clone(base.wayu_version)
		result.path.dedup = base.path.dedup
		result.path.clean = base.path.clean
		result.path.entries = make([]string, len(base.path.entries))
		for e, i in base.path.entries {
			result.path.entries[i] = strings.clone(e)
		}
		result.aliases = make([]TomlAlias, len(base.aliases))
		for a, i in base.aliases {
			result.aliases[i] = {strings.clone(a.name), strings.clone(a.command), strings.clone(a.description)}
		}
		result.constants = make([]TomlConstant, len(base.constants))
		for c, i in base.constants {
			result.constants[i] = {strings.clone(c.name), strings.clone(c.value), c.export, c.secret, strings.clone(c.description)}
		}
		result.plugins = make([]TomlPlugin, len(base.plugins))
		for p, i in base.plugins {
			result.plugins[i] = {
				strings.clone(p.name), strings.clone(p.source), strings.clone(p.version),
				p.defer_load, p.priority,
				strings.clone(p.condition),
				make([]string, len(p.use)),
				strings.clone(p.description),
			}
			for u, j in p.use {
				result.plugins[i].use[j] = strings.clone(u)
			}
		}
		result.settings = base.settings
		result.settings.autosuggestions_accept_keys = make([]string, len(base.settings.autosuggestions_accept_keys))
		for k, i in base.settings.autosuggestions_accept_keys {
			result.settings.autosuggestions_accept_keys[i] = strings.clone(k)
		}
		result.profiles = make(map[string]ProfileConfig)
		for name, pf in base.profiles {
			pc: ProfileConfig
			pc.condition = strings.clone(pf.condition)
			if pf.path != nil {
				pc.path = new(TomlPathConfig)
				pc.path.dedup = pf.path.dedup
				pc.path.clean = pf.path.clean
				pc.path.entries = make([]string, len(pf.path.entries))
				for e2, i2 in pf.path.entries {
					pc.path.entries[i2] = strings.clone(e2)
				}
			}
			result.profiles[name] = pc
		}
		return result
	}
	
	// Deep-clone base config to avoid sharing string/map pointers
	merged: TomlConfig
	merged.version = strings.clone(base.version)
	merged.shell = strings.clone(base.shell)
	merged.wayu_version = strings.clone(base.wayu_version)
	merged.path.dedup = base.path.dedup
	merged.path.clean = base.path.clean
	merged.path.entries = make([]string, len(base.path.entries))
	for e, i in base.path.entries {
		merged.path.entries[i] = strings.clone(e)
	}
	merged.aliases = nil
	merged.constants = nil
	merged.plugins = nil
	merged.settings = base.settings
	merged.settings.autosuggestions_accept_keys = make([]string, len(base.settings.autosuggestions_accept_keys))
	for k, i in base.settings.autosuggestions_accept_keys {
		merged.settings.autosuggestions_accept_keys[i] = strings.clone(k)
	}
	// Clone profiles map
	merged.profiles = make(map[string]ProfileConfig)
	for name, pf in base.profiles {
		pc: ProfileConfig
		pc.condition = strings.clone(pf.condition)
		if pf.path != nil {
			pc.path = new(TomlPathConfig)
			pc.path.dedup = pf.path.dedup
			pc.path.clean = pf.path.clean
			pc.path.entries = make([]string, len(pf.path.entries))
			for e, i in pf.path.entries {
				pc.path.entries[i] = strings.clone(e)
			}
		}
		pc.aliases = make([]TomlAlias, len(pf.aliases))
		for a, i in pf.aliases {
			pc.aliases[i] = {strings.clone(a.name), strings.clone(a.command), strings.clone(a.description)}
		}
		pc.constants = make([]TomlConstant, len(pf.constants))
		for c, i in pf.constants {
			pc.constants[i] = {strings.clone(c.name), strings.clone(c.value), c.export, c.secret, strings.clone(c.description)}
		}
		pc.plugins = make([]TomlPlugin, len(pf.plugins))
		for p, i in pf.plugins {
			pc.plugins[i] = {
				strings.clone(p.name), strings.clone(p.source), strings.clone(p.version),
				p.defer_load, p.priority,
				strings.clone(p.condition),
				make([]string, len(p.use)),
				strings.clone(p.description),
			}
			for u, j in p.use {
				pc.plugins[i].use[j] = strings.clone(u)
			}
		}
		merged.profiles[name] = pc
	}
	
	// Override path settings if profile has them (deep clone to avoid sharing).
	// Free the base-cloned entries first — otherwise the earlier
	// `merged.path.entries = make(...)` allocation (and every cloned entry
	// inside it) leaks when we swap in the profile version.
	if profile.path != nil {
		merged.path.dedup = profile.path.dedup
		merged.path.clean = profile.path.clean
		if merged.path.entries != nil {
			for e in merged.path.entries {
				delete(e)
			}
			delete(merged.path.entries)
		}
		merged.path.entries = make([]string, len(profile.path.entries))
		for e, i in profile.path.entries {
			merged.path.entries[i] = strings.clone(e)
		}
	}
	
	// Temp dynamic arrays for merged config
	merged_aliases_dyn := make([dynamic]TomlAlias)
	merged_constants_dyn := make([dynamic]TomlConstant)
	merged_plugins_dyn := make([dynamic]TomlPlugin)
	
	// Copy existing aliases (deep clone strings)
	for alias in base.aliases {
		append(&merged_aliases_dyn, TomlAlias{strings.clone(alias.name), strings.clone(alias.command), strings.clone(alias.description)})
	}
	// Append profile aliases (deep clone strings)
	for alias in profile.aliases {
		append(&merged_aliases_dyn, TomlAlias{strings.clone(alias.name), strings.clone(alias.command), strings.clone(alias.description)})
	}
	
	// Copy existing constants (deep clone strings)
	for constant in base.constants {
		append(&merged_constants_dyn, TomlConstant{strings.clone(constant.name), strings.clone(constant.value), constant.export, constant.secret, strings.clone(constant.description)})
	}
	// Append profile constants (deep clone strings)
	for constant in profile.constants {
		append(&merged_constants_dyn, TomlConstant{strings.clone(constant.name), strings.clone(constant.value), constant.export, constant.secret, strings.clone(constant.description)})
	}
	
	// Copy existing plugins (deep clone strings)
	for plugin in base.plugins {
		p := TomlPlugin{
			strings.clone(plugin.name), strings.clone(plugin.source), strings.clone(plugin.version),
			plugin.defer_load, plugin.priority,
			strings.clone(plugin.condition),
			make([]string, len(plugin.use)),
			strings.clone(plugin.description),
		}
		for u, j in plugin.use { p.use[j] = strings.clone(u) }
		append(&merged_plugins_dyn, p)
	}
	// Append profile plugins (deep clone strings)
	for plugin in profile.plugins {
		p := TomlPlugin{
			strings.clone(plugin.name), strings.clone(plugin.source), strings.clone(plugin.version),
			plugin.defer_load, plugin.priority,
			strings.clone(plugin.condition),
			make([]string, len(plugin.use)),
			strings.clone(plugin.description),
		}
		for u, j in plugin.use { p.use[j] = strings.clone(u) }
		append(&merged_plugins_dyn, p)
	}
	
	// Assign dynamic arrays to merged
	ma_slice := make([]TomlAlias, len(merged_aliases_dyn))
	copy(ma_slice, merged_aliases_dyn[:])
	delete(merged_aliases_dyn)
	merged.aliases = ma_slice
	
	mc_slice := make([]TomlConstant, len(merged_constants_dyn))
	copy(mc_slice, merged_constants_dyn[:])
	delete(merged_constants_dyn)
	merged.constants = mc_slice
	
	mp_slice := make([]TomlPlugin, len(merged_plugins_dyn))
	copy(mp_slice, merged_plugins_dyn[:])
	delete(merged_plugins_dyn)
	merged.plugins = mp_slice
	
	return merged
}

// Get active profile based on condition (simplified - returns first matching)
toml_get_active_profile :: proc(config: TomlConfig) -> string {
	for name, profile in config.profiles {
		if profile.condition != "" {
			// Simple condition evaluation could be expanded
			// For now, just return first profile with a condition
			return name
		}
	}
	return ""
}

