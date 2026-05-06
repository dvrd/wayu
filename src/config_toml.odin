// config_toml.odin - TOML configuration file support for wayu
//
// This module provides TOML parsing, validation, and serialization for wayu's
// configuration files. It supports profiles, nested structures, and all
// configuration types defined in interfaces.odin.

package wayu

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:unicode"

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
