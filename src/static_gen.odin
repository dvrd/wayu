// static_gen.odin - Static shell script generation for ultra-fast loading
//
// This module generates optimized static shell scripts from TOML configuration,
// eliminating runtime parsing overhead for shell startup speed.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// ============================================================================
// Main Generation Functions
// ============================================================================

// Generate optimized static shell script from TOML config
static_generate :: proc(config: TomlConfig, lock: LockFile) -> StaticConfig {
	shell := config.shell
	if len(shell) == 0 {
		shell = "zsh" // Default to zsh
	}

	// Fish shell uses a different syntax — route to the fish-native generator
	// to avoid emitting bash/zsh constructs under a fish shebang. Use
	// DETECTED_SHELL since config.shell may carry the [shell] table rather
	// than a simple string depending on TOML layout.
	if DETECTED_SHELL == .FISH || strings.equal_fold(shell, "fish") {
		fish_content := shell_fish_generate_init(config)
		return StaticConfig{
			generated_at = fmt.aprintf("%v", time.now()),
			wayu_version = strings.clone(VERSION),
			shell        = strings.clone("fish"),
			content      = fish_content,
		}
	}

	// Build static content
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// Header comment
	fmt.sbprintf(&builder, "#!/usr/bin/env %s\n\n", shell)
	fmt.sbprintln(&builder, "# ============================================")
	fmt.sbprintln(&builder, "# Wayu Static Configuration")
	fmt.sbprintln(&builder, "# Auto-generated - DO NOT EDIT MANUALLY")
	fmt.sbprintf(&builder, "# Generated: %s\n", time.now())
	fmt.sbprintf(&builder, "# Wayu Version: %s\n", VERSION)
	fmt.sbprintln(&builder, "# ============================================")
	fmt.sbprintln(&builder, "")

	// Generate PATH
	path_section := static_generate_path(config.path.entries)
	defer delete(path_section)
	if len(path_section) > 0 {
		fmt.sbprintln(&builder, "# --- PATH Configuration ---")
		fmt.sbprint(&builder, path_section)
		fmt.sbprintln(&builder, "")
	}

	// Generate constants
	constants_section := static_generate_constants(config.constants)
	defer delete(constants_section)
	if len(constants_section) > 0 {
		fmt.sbprintln(&builder, "# --- Environment Constants ---")
		fmt.sbprint(&builder, constants_section)
		fmt.sbprintln(&builder, "")
	}

	// Generate aliases
	aliases_section := static_generate_aliases(config.aliases)
	defer delete(aliases_section)
	if len(aliases_section) > 0 {
		fmt.sbprintln(&builder, "# --- Aliases ---")
		fmt.sbprint(&builder, aliases_section)
		fmt.sbprintln(&builder, "")
	}

	// Generate plugins
	plugins_section := static_generate_plugins(config.plugins)
	defer delete(plugins_section)
	if len(plugins_section) > 0 {
		fmt.sbprintln(&builder, "# --- Plugins ---")
		fmt.sbprint(&builder, plugins_section)
		fmt.sbprintln(&builder, "")
	}

	content := strings.clone(strings.to_string(builder))

	// Optimize the content
	optimized := static_optimize(content)
	delete(content)

	return StaticConfig{
		generated_at = fmt.aprintf("%v", time.now()),
		wayu_version = strings.clone(VERSION),
		shell        = strings.clone(shell),
		content      = optimized,
	}
}

// Generate optimized PATH export
static_generate_path :: proc(entries: []string) -> string {
	if len(entries) == 0 {
		return ""
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// Build PATH string with deduplication
	// Using the optimized array-based approach from v3.0
	fmt.sbprintln(&builder, "WAYU_PATHS=(")

	for entry in entries {
		escaped := escape_shell_string(entry)
		defer delete(escaped)
		fmt.sbprintf(&builder, "  \"%s\"\n", escaped)
	}

	fmt.sbprintln(&builder, ")")
	fmt.sbprintln(&builder, "")

	// Optimized PATH building loop
	fmt.sbprintln(&builder, "# Build PATH with deduplication")
	fmt.sbprintln(&builder, "for dir in \"${WAYU_PATHS[@]}\"; do")
	fmt.sbprintln(&builder, "  [[ -d \"$dir\" ]] || continue")
	fmt.sbprintln(&builder, "  [[ \":$PATH:\" == *\":$dir:\"* ]] && continue")
	fmt.sbprintln(&builder, "  export PATH=\"$dir:$PATH\"")
	fmt.sbprintln(&builder, "done")
	fmt.sbprintln(&builder, "")

	return strings.clone(strings.to_string(builder))
}

// Generate alias definitions
static_generate_aliases :: proc(aliases: []TomlAlias) -> string {
	if len(aliases) == 0 {
		return ""
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	for alias in aliases {
		escaped_cmd := escape_shell_string(alias.command)
		defer delete(escaped_cmd)

		if len(alias.description) > 0 {
			fmt.sbprintf(&builder, "# %s\n", alias.description)
		}
		fmt.sbprintf(&builder, "alias %s=\"%s\"\n", alias.name, escaped_cmd)
	}

	return strings.clone(strings.to_string(builder))
}

// Generate constant exports
static_generate_constants :: proc(constants: []TomlConstant) -> string {
	if len(constants) == 0 {
		return ""
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	for constant in constants {
		escaped_value := escape_shell_string(constant.value)
		defer delete(escaped_value)

		if len(constant.description) > 0 {
			fmt.sbprintf(&builder, "# %s\n", constant.description)
		}

		if constant.secret {
			// Mask secret values in output
			fmt.sbprintf(&builder, "# %s (secret - value hidden)\n", constant.name)
		}

		if constant.export {
			fmt.sbprintf(&builder, "export %s=\"%s\"\n", constant.name, escaped_value)
		} else {
			fmt.sbprintf(&builder, "%s=\"%s\"\n", constant.name, escaped_value)
		}
	}

	return strings.clone(strings.to_string(builder))
}

// Generate plugin sources
static_generate_plugins :: proc(plugins: []TomlPlugin) -> string {
	if len(plugins) == 0 {
		return ""
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// Sort plugins by priority (lower = earlier)
	sorted_plugins := make([]TomlPlugin, len(plugins))
	copy(sorted_plugins, plugins)
	defer delete(sorted_plugins)

	// Bubble sort by priority
	for i := 0; i < len(sorted_plugins); i += 1 {
		for j := i + 1; j < len(sorted_plugins); j += 1 {
			if sorted_plugins[j].priority < sorted_plugins[i].priority {
				sorted_plugins[i], sorted_plugins[j] = sorted_plugins[j], sorted_plugins[i]
			}
		}
	}

	for plugin in sorted_plugins {
		if len(plugin.description) > 0 {
			fmt.sbprintf(&builder, "# %s (%s)\n", plugin.name, plugin.description)
		} else {
			fmt.sbprintf(&builder, "# %s\n", plugin.name)
		}

		// Handle conditional loading
		if len(plugin.condition) > 0 {
			fmt.sbprintf(&builder, "if [[ %s ]]; then\n", plugin.condition)
		}

		// Handle defer loading
		if plugin.defer_load {
			fmt.sbprintln(&builder, "# DEFERRED: Loaded after first prompt via precmd hook")
			fmt.sbprintf(&builder, "_wayu_deferred_%s() {\n", plugin.name)
		}

		// Generate source commands for plugin files
		plugin_path := resolve_plugin_path(plugin.source)
		defer delete(plugin_path)

		if len(plugin.use) > 0 {
			for use_file in plugin.use {
				full_path := fmt.aprintf("%s/%s", plugin_path, use_file)
				defer delete(full_path)
				escaped_path := escape_shell_string(full_path)
				defer delete(escaped_path)
				fmt.sbprintf(&builder, "  [[ -f \"%s\" ]] && source \"%s\"\n", escaped_path, escaped_path)
			}
		} else {
			// Default: source all .plugin.zsh files
			escaped_path := escape_shell_string(plugin_path)
			defer delete(escaped_path)
			fmt.sbprintf(&builder, "  for f in \"%s\"/*.plugin.zsh(N); do\n", escaped_path)
			fmt.sbprintln(&builder, "    [[ -f \"$f\" ]] && source \"$f\"")
			fmt.sbprintln(&builder, "  done")
		}

		if plugin.defer_load {
			fmt.sbprintln(&builder, "}")
			fmt.sbprintf(&builder, "add-zsh-hook precmd _wayu_deferred_%s\n", plugin.name)
			fmt.sbprintf(&builder, "unset -f _wayu_deferred_%s 2>/dev/null\n", plugin.name)
		}

		if len(plugin.condition) > 0 {
			fmt.sbprintln(&builder, "fi")
		}

		fmt.sbprintln(&builder, "")
	}

	return strings.clone(strings.to_string(builder))
}

// Optimize generated content (remove extra whitespace, comments if needed)
static_optimize :: proc(content: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	lines := strings.split(content, "\n")
	defer delete(lines)

	last_was_blank := false

	for line in lines {
		trimmed := strings.trim_space(line)

		// Skip consecutive blank lines
		if len(trimmed) == 0 {
			if last_was_blank {
				continue
			}
			last_was_blank = true
		} else {
			last_was_blank = false
		}

		fmt.sbprintln(&builder, line)
	}

	return strings.clone(strings.to_string(builder))
}

// Write static config to file
static_write :: proc(path: string, static_config: StaticConfig) -> bool {
	content_bytes := transmute([]byte)static_config.content
	write_err := os.write_entire_file(path, content_bytes)
	if write_err != nil {
		print_error("Failed to write static file: %s", path)
		return false
	}

	return true
}

// ============================================================================
// Helper Functions
// ============================================================================

// Escape special characters in shell strings
escape_shell_string :: proc(s: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	for c in s {
		switch c {
		case '"':
			strings.write_string(&builder, "\\\"")
		case '\\':
			strings.write_string(&builder, "\\\\")
		case '`':
			strings.write_string(&builder, "\\`")
		case '$':
			strings.write_string(&builder, "\\$")
		case:
			strings.write_byte(&builder, u8(c))
		}
	}

	return strings.clone(strings.to_string(builder))
}

// Resolve plugin source to filesystem path
resolve_plugin_path :: proc(source: string) -> string {
	if strings.has_prefix(source, "local:") {
		return strings.clone(strings.trim_prefix(source, "local:"))
	}

	if strings.has_prefix(source, "github:") {
		// github:user/repo -> ~/.config/wayu/plugins/user-repo
		repo_part := strings.trim_prefix(source, "github:")
		return fmt.aprintf("%s/plugins/%s", WAYU_CONFIG, strings.replace_all(repo_part, "/", "-"))
	}

	if strings.has_prefix(source, "https://") || strings.has_prefix(source, "http://") {
		// Remote URL - use cached version
		return fmt.aprintf("%s/plugins/remote/%s", WAYU_CONFIG, sanitize_filename(source))
	}

	// Assume it's a local path
	return strings.clone(source)
}

// Sanitize filename for caching
sanitize_filename :: proc(url: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	for c in url {
		switch c {
		case 'a'..='z', 'A'..='Z', '0'..='9', '-', '_', '.':
			strings.write_byte(&builder, u8(c))
		case:
			strings.write_byte(&builder, '_')
		}
	}

	return strings.clone(strings.to_string(builder))
}

// ============================================================================
// CLI Integration
// ============================================================================

// Handle generate-static command
handle_generate_static_command :: proc(args: []string) {
	// Check if wayu is initialized
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	// Default output path
	output_path := fmt.aprintf("%s/wayu_static.%s", WAYU_CONFIG, SHELL_EXT)
	defer delete(output_path)

	// Parse optional --output flag
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--output" || args[i] == "-o" {
			if i + 1 < len(args) {
				delete(output_path)
				output_path = strings.clone(args[i + 1])
				i += 1
			}
		}
	}

	// Read TOML config
	toml_path := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG)
	defer delete(toml_path)

	config: TomlConfig
	config_ok := false

	if os.exists(toml_path) {
		content, read_ok := safe_read_file(toml_path)
		if read_ok {
			defer delete(content)
			config, config_ok = toml_parse(string(content))
		}
	}

	if !config_ok {
		// Fallback: read from existing config files
		config = static_config_from_files()
	}
	defer static_cleanup_config(&config)

	// Read lock file (optional)
	lock_path := fmt.aprintf("%s/wayu.lock", WAYU_CONFIG)
	defer delete(lock_path)

	lock: LockFile
	lock_ok := false

	if os.exists(lock_path) {
		lock, lock_ok = lock_read(lock_path)
	}

	// Generate static config
	static_config := static_generate(config, lock)
	defer static_cleanup_static_config(&static_config)

	// Dry-run mode check
	if DRY_RUN {
		print_header("DRY RUN - Static Generation", EMOJI_INFO)
		fmt.println()
		fmt.printfln("Would write to: %s", output_path)
		fmt.printfln("Shell: %s", static_config.shell)
		fmt.printfln("Size: %d bytes", len(static_config.content))
		fmt.println()
		fmt.println("--- Content Preview ---")
		
		// Show first 500 chars
		preview_len := 500
		if len(static_config.content) < preview_len {
			preview_len = len(static_config.content)
		}
		fmt.printfln("%s...", static_config.content[:preview_len])
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Write static file
	if !static_write(output_path, static_config) {
		os.exit(EXIT_IOERR)
	}

	print_success("Generated static config: %s", output_path)
	fmt.printfln("  Shell: %s", static_config.shell)
	fmt.printfln("  Size: %d bytes", len(static_config.content))
	fmt.println()
	fmt.printfln("To use, add this to your shell RC file:")
	fmt.printfln("  %ssource %s%s", BOLD, output_path, RESET)
}

// Build config from existing config files (fallback when TOML doesn't exist)
static_config_from_files :: proc() -> TomlConfig {
	config: TomlConfig
	config.version = "1.0"
	config.shell = SHELL_EXT // "zsh" or "bash"
	config.wayu_version = VERSION

	// Read PATH entries
	path_entries := read_config_entries(&PATH_SPEC)
	defer cleanup_entries(&path_entries)

	config.path.entries = make([]string, len(path_entries))
	for entry, i in path_entries {
		config.path.entries[i] = strings.clone(entry.name)
	}

	// Read aliases
	alias_entries := read_config_entries(&ALIAS_SPEC)
	defer cleanup_entries(&alias_entries)

	config.aliases = make([]TomlAlias, len(alias_entries))
	for entry, i in alias_entries {
		config.aliases[i] = TomlAlias{
			name    = strings.clone(entry.name),
			command = strings.clone(entry.value),
		}
	}

	// Read constants
	constant_entries := read_config_entries(&CONSTANTS_SPEC)
	defer cleanup_entries(&constant_entries)

	config.constants = make([]TomlConstant, len(constant_entries))
	for entry, i in constant_entries {
		config.constants[i] = TomlConstant{
			name   = strings.clone(entry.name),
			value  = strings.clone(entry.value),
			export = true,
		}
	}

	return config
}

// Cleanup TomlConfig (free allocated memory)
static_cleanup_config :: proc(config: ^TomlConfig) {
	delete(config.version)
	delete(config.shell)
	delete(config.wayu_version)

	for entry in config.path.entries {
		delete(entry)
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
		for use_file in plugin.use {
			delete(use_file)
		}
		delete(plugin.use)
	}
	delete(config.plugins)

	for key, profile in config.profiles {
		delete(key)
		if profile.path != nil {
			for entry in profile.path.entries {
				delete(entry)
			}
			delete(profile.path.entries)
			free(profile.path)
		}
		for alias in profile.aliases {
			delete(alias.name)
			delete(alias.command)
			delete(alias.description)
		}
		delete(profile.aliases)
		for constant in profile.constants {
			delete(constant.name)
			delete(constant.value)
			delete(constant.description)
		}
		delete(profile.constants)
		for plugin in profile.plugins {
			delete(plugin.name)
			delete(plugin.source)
			delete(plugin.version)
			delete(plugin.condition)
			delete(plugin.description)
			for use_file in plugin.use {
				delete(use_file)
			}
			delete(plugin.use)
		}
		delete(profile.plugins)
		delete(profile.condition)
	}
	delete(config.profiles)
}

// Cleanup StaticConfig (free allocated memory)
static_cleanup_static_config :: proc(static_config: ^StaticConfig) {
	delete(static_config.generated_at)
	delete(static_config.wayu_version)
	delete(static_config.shell)
	delete(static_config.content)
}
