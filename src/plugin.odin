#+feature dynamic-literals
package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:slice"
import "core:time"
import "core:c/libc"
import "core:encoding/json"

// Shell compatibility for plugins
ShellCompat :: enum {
	ZSH,
	BASH,
	BOTH,
}

// Plugin information from registry
PluginInfo :: struct {
	name:        string,
	url:         string,
	shell:       ShellCompat,
	description: string,
}

// Installed plugin with metadata
InstalledPlugin :: struct {
	name:           string,
	url:            string,
	enabled:        bool,
	shell:          ShellCompat,
	installed_path: string,
	entry_file:     string, // Main file to source
}

// Plugin configuration state
PluginConfig :: struct {
	plugins: [dynamic]InstalledPlugin,
}

// Enhanced plugin metadata with git tracking, dependencies, and conflicts (JSON5 format)
PluginMetadata :: struct {
	name:           string,
	url:            string,
	enabled:        bool,
	shell:          ShellCompat,
	installed_path: string,
	entry_file:     string,
	git:            GitMetadata,
	dependencies:   [dynamic]string,
	priority:       int,
	config:         map[string]string,
	conflicts:      ConflictInfo,
}

// Git metadata for update tracking
GitMetadata :: struct {
	branch:        string,  // Current branch (default: "master" or "main")
	commit:        string,  // Local commit SHA (short form)
	last_checked:  string,  // ISO 8601 timestamp of last update check
	remote_commit: string,  // Remote commit SHA (short form)
}

// Conflict detection information
ConflictInfo :: struct {
	env_vars:            [dynamic]string,  // Environment variables this plugin sets
	functions:           [dynamic]string,  // Functions this plugin defines
	aliases_:            [dynamic]string,  // Aliases this plugin creates
	detected:            bool,             // Whether conflicts were detected
	conflicting_plugins: [dynamic]string,  // Names of plugins with conflicts
}

// Enhanced plugin configuration (JSON5 format)
PluginConfigJSON :: struct {
	version:      string,
	last_updated: string,  // ISO 8601 timestamp
	plugins:      [dynamic]PluginMetadata,
}

// Popular plugins registry - hardcoded for simplicity and speed
POPULAR_PLUGINS := map[string]PluginInfo{
	"syntax-highlighting" = {
		name = "zsh-syntax-highlighting",
		url = "https://github.com/zsh-users/zsh-syntax-highlighting.git",
		shell = .ZSH,
		description = "Fish-like syntax highlighting for ZSH",
	},
	"autosuggestions" = {
		name = "zsh-autosuggestions",
		url = "https://github.com/zsh-users/zsh-autosuggestions.git",
		shell = .ZSH,
		description = "Fish-like autosuggestions for ZSH",
	},
	"fast-syntax-highlighting" = {
		name = "fast-syntax-highlighting",
		url = "https://github.com/zdharma-continuum/fast-syntax-highlighting.git",
		shell = .ZSH,
		description = "Feature-rich syntax highlighting for ZSH",
	},
	"completions" = {
		name = "zsh-completions",
		url = "https://github.com/zsh-users/zsh-completions.git",
		shell = .ZSH,
		description = "Additional completion definitions for ZSH",
	},
	"history-substring-search" = {
		name = "zsh-history-substring-search",
		url = "https://github.com/zsh-users/zsh-history-substring-search.git",
		shell = .ZSH,
		description = "Fish-like history search",
	},
	"git-open" = {
		name = "git-open",
		url = "https://github.com/paulirish/git-open.git",
		shell = .BOTH,
		description = "Open repo in browser from command line",
	},
	"z" = {
		name = "z",
		url = "https://github.com/rupa/z.git",
		shell = .BOTH,
		description = "Jump to frecent directories",
	},
	"you-should-use" = {
		name = "zsh-you-should-use",
		url = "https://github.com/MichaelAquilina/zsh-you-should-use.git",
		shell = .ZSH,
		description = "Reminds you to use aliases",
	},
	"colored-man-pages" = {
		name = "zsh-colored-man-pages",
		url = "https://github.com/ael-code/zsh-colored-man-pages.git",
		shell = .ZSH,
		description = "Colorize man pages",
	},
}

// Parse shell compatibility from string
parse_shell_compat :: proc(shell_str: string) -> ShellCompat {
	shell_lower := strings.to_lower(shell_str)
	defer delete(shell_lower)

	switch shell_lower {
	case "zsh":
		return .ZSH
	case "bash":
		return .BASH
	case "both":
		return .BOTH
	}
	return .BOTH
}

// Convert shell compatibility to string
shell_compat_to_string :: proc(compat: ShellCompat) -> string {
	switch compat {
	case .ZSH:
		return "zsh"
	case .BASH:
		return "bash"
	case .BOTH:
		return "both"
	}
	return "both"
}

// Helper: Get current timestamp in ISO 8601 format
get_iso8601_timestamp :: proc() -> string {
	now := time.now()
	year, month, day := time.date(now)
	hour, minute, second := time.clock(now)
	return fmt.aprintf("%d-%02d-%02dT%02d:%02d:%02dZ",
		year, month, day, hour, minute, second)
}

// Execute command and return trimmed output
exec_command_output :: proc(cmd: string) -> string {
	// Use unique temporary file for output to avoid race conditions
	now := time.now()
	unix_nanos := time.to_unix_nanoseconds(now)
	temp_file := fmt.aprintf("/tmp/wayu_cmd_output_%d.txt", unix_nanos)
	defer delete(temp_file)

	full_cmd := fmt.aprintf("%s > %s 2>&1", cmd, temp_file)
	defer delete(full_cmd)

	cmd_cstr := strings.clone_to_cstring(full_cmd)
	defer delete(cmd_cstr)

	result := libc.system(cmd_cstr)
	if result != 0 {
		// Clean up temp file on error
		os.remove(temp_file)
		return ""
	}

	data, ok := os.read_entire_file_from_filename(temp_file)
	if !ok {
		os.remove(temp_file)
		return ""
	}
	defer delete(data)

	// Clean up temp file after reading
	os.remove(temp_file)

	output := string(data)
	trimmed := strings.trim_space(output)
	// Clone the trimmed string before data is deleted
	return strings.clone(trimmed)
}

// Get git information for an installed plugin
get_git_info :: proc(plugin_dir: string) -> GitMetadata {
	info := GitMetadata{}

	if !os.exists(plugin_dir) {
		return info
	}

	// Get current branch
	branch_cmd := fmt.aprintf("git -C \"%s\" rev-parse --abbrev-ref HEAD 2>/dev/null", plugin_dir)
	defer delete(branch_cmd)
	info.branch = exec_command_output(branch_cmd)

	// Get local commit (short SHA)
	commit_cmd := fmt.aprintf("git -C \"%s\" rev-parse --short HEAD 2>/dev/null", plugin_dir)
	defer delete(commit_cmd)
	info.commit = exec_command_output(commit_cmd)

	// Remote commit will be fetched during check/update
	info.remote_commit = info.commit
	info.last_checked = get_iso8601_timestamp()

	return info
}

// Cleanup helper for PluginMetadata
cleanup_plugin_metadata :: proc(plugin: ^PluginMetadata) {
	delete(plugin.name)
	delete(plugin.url)
	delete(plugin.installed_path)
	delete(plugin.entry_file)
	delete(plugin.git.branch)
	delete(plugin.git.commit)
	delete(plugin.git.last_checked)
	delete(plugin.git.remote_commit)
	delete(plugin.dependencies)
	delete(plugin.config)
	delete(plugin.conflicts.env_vars)
	delete(plugin.conflicts.functions)
	delete(plugin.conflicts.aliases_)
	delete(plugin.conflicts.conflicting_plugins)
}

// Cleanup helper for PluginConfigJSON
cleanup_plugin_config_json :: proc(config: ^PluginConfigJSON) {
	delete(config.version)
	delete(config.last_updated)
	for &plugin in config.plugins {
		cleanup_plugin_metadata(&plugin)
	}
	delete(config.plugins)
}

// Get plugins config file path
get_plugins_config_file :: proc() -> string {
	return fmt.aprintf("%s/plugins.conf", WAYU_CONFIG)
}

// Get plugins JSON config file path
get_plugins_json_config_file :: proc() -> string {
	return fmt.aprintf("%s/plugins.json", WAYU_CONFIG)
}

// Get plugins directory path
get_plugins_dir :: proc() -> string {
	return fmt.aprintf("%s/plugins", WAYU_CONFIG)
}

// Read plugins.conf configuration file
read_plugin_config :: proc() -> PluginConfig {
	config := PluginConfig{}
	config.plugins = make([dynamic]InstalledPlugin)

	config_file := get_plugins_config_file()
	defer delete(config_file)

	if !os.exists(config_file) {
		return config
	}

	data, ok := os.read_entire_file_from_filename(config_file)
	if !ok {
		return config
	}
	defer delete(data)

	content := string(data)
	lines := strings.split_lines(content)
	defer delete(lines)

	for line in lines {
		trimmed_line := strings.trim_space(line)

		// Skip empty lines and comments
		if len(trimmed_line) == 0 || strings.has_prefix(trimmed_line, "#") {
			continue
		}

		// Parse: name|url|enabled|shell
		parts := strings.split(trimmed_line, "|")
		defer delete(parts)

		if len(parts) != 4 {
			continue
		}

		plugins_dir := get_plugins_dir()
		defer delete(plugins_dir)

		plugin := InstalledPlugin{
			name = strings.clone(parts[0]),
			url = strings.clone(parts[1]),
			enabled = parts[2] == "true",
			shell = parse_shell_compat(parts[3]),
			installed_path = fmt.aprintf("%s/%s", plugins_dir, parts[0]),
		}

		append(&config.plugins, plugin)
	}

	return config
}

// Write plugins.conf configuration file
write_plugin_config :: proc(config: ^PluginConfig) -> bool {
	config_file := get_plugins_config_file()
	defer delete(config_file)

	// Build content
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, "# Wayu Plugin Configuration\n")
	strings.write_string(&sb, "# Format: name|url|enabled|shell\n")
	strings.write_string(&sb, "# shell: zsh, bash, both\n\n")

	for plugin in config.plugins {
		line := fmt.aprintf("%s|%s|%t|%s\n",
			plugin.name,
			plugin.url,
			plugin.enabled,
			shell_compat_to_string(plugin.shell))
		defer delete(line)

		strings.write_string(&sb, line)
	}

	content := strings.to_string(sb)
	return os.write_entire_file(config_file, transmute([]byte)content)
}

// Read JSON5 configuration file
read_plugin_config_json :: proc() -> (config: PluginConfigJSON, ok: bool) {
	config_file := get_plugins_json_config_file()
	defer delete(config_file)

	if !os.exists(config_file) {
		// Return empty config on first run
		config.version = "1.0"
		config.last_updated = get_iso8601_timestamp()
		config.plugins = make([dynamic]PluginMetadata)
		return config, true
	}

	data, read_ok := os.read_entire_file_from_filename(config_file)
	if !read_ok {
		fmt.eprintln("Error: Failed to read plugins.json")
		return config, false
	}
	defer delete(data)

	// Parse as JSON5 (allows comments and trailing commas)
	json_err := json.unmarshal(data, &config, spec = .JSON5)
	if json_err != nil {
		fmt.eprintfln("Error: Failed to parse plugins.json: %v", json_err)
		return config, false
	}

	// Phase 4: Validate no circular dependencies on load
	validate_no_circular_dependencies(&config)

	return config, true
}

// Write JSON5 configuration file
write_plugin_config_json :: proc(config: ^PluginConfigJSON) -> bool {
	config.last_updated = get_iso8601_timestamp()

	// Marshal to JSON5 with pretty printing
	marshal_options := json.Marshal_Options{
		pretty = true,
		use_spaces = true,
		spaces = 2,
		spec = .JSON5,
	}

	data, marshal_err := json.marshal(config^, marshal_options)
	if marshal_err != nil {
		fmt.eprintfln("Error: Failed to marshal config: %v", marshal_err)
		return false
	}
	defer delete(data)

	config_file := get_plugins_json_config_file()
	defer delete(config_file)

	write_ok := os.write_entire_file(config_file, data)
	if !write_ok {
		fmt.eprintln("Error: Failed to write plugins.json")
		return false
	}

	return true
}

// Migrate from old pipe-delimited format to JSON5
migrate_plugin_config :: proc() -> bool {
	old_file := get_plugins_config_file()
	defer delete(old_file)

	new_file := get_plugins_json_config_file()
	defer delete(new_file)

	// Skip if new file exists or old file doesn't exist
	if os.exists(new_file) || !os.exists(old_file) {
		return true
	}

	print_info("Migrating plugins.conf to plugins.json...")

	// Read old config
	old_config := read_plugin_config()
	defer {
		for plugin in old_config.plugins {
			delete(plugin.name)
			delete(plugin.url)
			delete(plugin.installed_path)
			delete(plugin.entry_file)
		}
		delete(old_config.plugins)
	}

	// Convert to new format
	new_config := PluginConfigJSON{
		version = "1.0",
		last_updated = get_iso8601_timestamp(),
		plugins = make([dynamic]PluginMetadata),
	}
	defer cleanup_plugin_config_json(&new_config)

	for old_plugin in old_config.plugins {
		// Get git info for existing plugin
		git_info := get_git_info(old_plugin.installed_path)

		new_plugin := PluginMetadata{
			name = strings.clone(old_plugin.name),
			url = strings.clone(old_plugin.url),
			enabled = old_plugin.enabled,
			shell = old_plugin.shell,
			installed_path = strings.clone(old_plugin.installed_path),
			entry_file = strings.clone(old_plugin.entry_file),
			git = git_info,
			dependencies = make([dynamic]string),
			priority = 100, // Default priority
			config = make(map[string]string),
			conflicts = ConflictInfo{
				env_vars = make([dynamic]string),
				functions = make([dynamic]string),
				aliases_ = make([dynamic]string),
				detected = false,
				conflicting_plugins = make([dynamic]string),
			},
		}

		append(&new_config.plugins, new_plugin)
	}

	// Write new config
	if !write_plugin_config_json(&new_config) {
		print_error_simple("Error: Failed to write new configuration")
		return false
	}

	// Backup old config
	backup_file := fmt.aprintf("%s.backup", old_file)
	defer delete(backup_file)

	os.rename(old_file, backup_file)

	print_success("Migration complete! Old config backed up to plugins.conf.backup")
	return true
}

// Git operations

// Clone plugin repository
git_clone :: proc(url: string, dest: string) -> bool {
	cmd := fmt.aprintf("git clone --depth=1 --quiet \"%s\" \"%s\" 2>&1", url, dest)
	defer delete(cmd)

	if DRY_RUN {
		print_info("[DRY RUN] Would execute: %s", cmd)
		return true
	}

	cmd_cstr := strings.clone_to_cstring(cmd)
	defer delete(cmd_cstr)

	result := libc.system(cmd_cstr)
	return result == 0
}

// Update plugin (git pull)
git_update :: proc(plugin_dir: string) -> bool {
	cmd := fmt.aprintf("git -C \"%s\" pull --quiet 2>&1", plugin_dir)
	defer delete(cmd)

	if DRY_RUN {
		print_info("[DRY RUN] Would execute: %s", cmd)
		return true
	}

	cmd_cstr := strings.clone_to_cstring(cmd)
	defer delete(cmd_cstr)

	result := libc.system(cmd_cstr)
	return result == 0
}

// Check if directory is git repo
is_git_repo :: proc(dir: string) -> bool {
	git_dir := fmt.aprintf("%s/.git", dir)
	defer delete(git_dir)

	return os.exists(git_dir)
}

// Plugin file detection

// Detect plugin entry file to source
detect_plugin_file :: proc(plugin_dir: string, plugin_name: string, shell: ShellType) -> (string, bool) {
	ext := get_shell_extension(shell)

	// 1. Standard plugin file: {name}.plugin.{zsh,bash}
	plugin_file := fmt.aprintf("%s/%s.plugin.%s", plugin_dir, plugin_name, ext)
	if os.exists(plugin_file) {
		return plugin_file, true
	}
	delete(plugin_file)

	// 2. Simple naming: {name}.{zsh,bash}
	simple_file := fmt.aprintf("%s/%s.%s", plugin_dir, plugin_name, ext)
	if os.exists(simple_file) {
		return simple_file, true
	}
	delete(simple_file)

	// 3. Init file: init.{zsh,bash}
	init_file := fmt.aprintf("%s/init.%s", plugin_dir, ext)
	if os.exists(init_file) {
		return init_file, true
	}
	delete(init_file)

	// 4. Fallback: return directory (source all .{zsh,bash} files)
	return "", false
}

// Generate plugins.{zsh,bash} loader file
generate_plugins_file :: proc(shell: ShellType) -> bool {
	ext := get_shell_extension(shell)
	plugins_file := fmt.aprintf("%s/plugins.%s", WAYU_CONFIG, ext)
	defer delete(plugins_file)

	// Read current configuration (JSON format with dependencies support)
	config, ok := read_plugin_config_json()
	if !ok {
		// Fall back to empty config if read fails
		config.version = "1.0"
		config.last_updated = get_iso8601_timestamp()
		config.plugins = make([dynamic]PluginMetadata)
	}
	defer cleanup_plugin_config_json(&config)

	// Build plugin loader script
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	shebang := get_shebang(shell)
	strings.write_string(&sb, shebang)
	strings.write_string(&sb, "\n# Auto-generated by wayu - DO NOT EDIT\n")

	// Add timestamp
	now := time.now()
	year, month, day := time.date(now)
	hour, minute, second := time.clock(now)
	timestamp := fmt.aprintf("# Last updated: %d-%02d-%02d %02d:%02d:%02d\n\n",
		year, month, day, hour, minute, second)
	defer delete(timestamp)
	strings.write_string(&sb, timestamp)

	strings.write_string(&sb, "# Load enabled plugins\n\n")

	// Phase 5: Resolve load order with priority
	load_order, order_ok := resolve_dependencies_with_priority(&config)
	if !order_ok {
		fmt.eprintln("Error: Failed to resolve plugin load order (circular dependency)")
		return false
	}
	defer {
		for name in load_order {
			delete(name)
		}
		delete(load_order)
	}

	// Phase 6: Detect conflicts between enabled plugins
	detect_conflicts(&config)

	// Check if any conflicts were detected
	conflicts_detected := false
	for plugin in config.plugins {
		if plugin.enabled && plugin.conflicts.detected {
			conflicts_detected = true
			break
		}
	}

	// Add global conflict warning header if conflicts exist
	if conflicts_detected {
		strings.write_string(&sb, "# ⚠️  CONFLICT WARNINGS\n")
		strings.write_string(&sb, "# The following plugins have potential conflicts:\n")

		// List all conflicting plugins
		for plugin in config.plugins {
			if plugin.enabled && plugin.conflicts.detected {
				conflicts_str := strings.join(plugin.conflicts.conflicting_plugins[:], ", ")
				warning := fmt.aprintf("#   - %s conflicts with: %s\n", plugin.name, conflicts_str)
				strings.write_string(&sb, warning)
				delete(warning)
				delete(conflicts_str)
			}
		}

		strings.write_string(&sb, "# This may cause unexpected behavior. Review your plugin configuration.\n\n")
	}

	// Generate source statements for enabled plugins in priority/dependency order
	for plugin_name in load_order {
		// Find plugin metadata
		plugin_ptr, found_plugin := find_plugin_json(&config, plugin_name)
		if !found_plugin || !plugin_ptr.enabled {
			continue
		}
		plugin := plugin_ptr^

		// Skip if shell incompatible
		if plugin.shell == .ZSH && shell == .BASH {
			continue
		}
		if plugin.shell == .BASH && shell == .ZSH {
			continue
		}

		// Detect plugin entry file
		entry_file, found := detect_plugin_file(plugin.installed_path, plugin.name, shell)

		// Phase 4: Check for missing or disabled dependencies
		if len(plugin.dependencies) > 0 {
			missing := make([dynamic]string)
			disabled := make([dynamic]string)
			defer delete(missing)
			defer delete(disabled)

			for dep_name in plugin.dependencies {
				dep_plugin, dep_found := find_plugin_json(&config, dep_name)
				if !dep_found {
					append(&missing, dep_name)
				} else if !dep_plugin.enabled {
					append(&disabled, dep_name)
				}
			}

			// Add warning comments for missing dependencies
			if len(missing) > 0 {
				warning_line := fmt.aprintf("# ⚠️  WARNING: Plugin '%s' has missing dependencies:\n", plugin.name)
				strings.write_string(&sb, warning_line)
				delete(warning_line)

				for dep in missing {
					dep_line := fmt.aprintf("#   - %s (not installed)\n", dep)
					strings.write_string(&sb, dep_line)
					delete(dep_line)
				}

				missing_str := strings.join(missing[:], " ")
				install_line := fmt.aprintf("# Install with: wayu plugin add %s\n\n", missing_str)
				strings.write_string(&sb, install_line)
				delete(install_line)
				delete(missing_str)
			}

			// Add warning comments for disabled dependencies
			if len(disabled) > 0 {
				warning_line := fmt.aprintf("# ⚠️  WARNING: Plugin '%s' has disabled dependencies:\n", plugin.name)
				strings.write_string(&sb, warning_line)
				delete(warning_line)

				for dep in disabled {
					dep_line := fmt.aprintf("#   - %s (disabled)\n", dep)
					strings.write_string(&sb, dep_line)
					delete(dep_line)
				}

				disabled_str := strings.join(disabled[:], " ")
				enable_line := fmt.aprintf("# Enable with: wayu plugin enable %s\n\n", disabled_str)
				strings.write_string(&sb, enable_line)
				delete(enable_line)
				delete(disabled_str)
			}
		}

		// Phase 6: Add per-plugin conflict warning if detected
		if plugin.conflicts.detected {
			conflict_warning := fmt.aprintf("# ⚠️  WARNING: %s has conflicts\n", plugin.name)
			strings.write_string(&sb, conflict_warning)
			delete(conflict_warning)
		}

		if found {
			// Single file to source
			comment := fmt.aprintf("# %s (priority: %d)\n", plugin.name, plugin.priority)
			strings.write_string(&sb, comment)
			delete(comment)

			source_line := fmt.aprintf("if [ -f %s ]; then\n    source %s\nfi\n\n",
				entry_file, entry_file)
			strings.write_string(&sb, source_line)
			delete(source_line)
		} else {
			// Source all .{zsh,bash} files in directory
			comment := fmt.aprintf("# %s (priority: %d, all .%s files)\n", plugin.name, plugin.priority, ext)
			strings.write_string(&sb, comment)
			delete(comment)

			source_block := fmt.aprintf(
				"for f in %s/*.%s; do\n" +
				"    [ -f \"$f\" ] && source \"$f\"\n" +
				"done\n\n",
				plugin.installed_path, ext)
			strings.write_string(&sb, source_block)
			delete(source_block)
		}

		if found {
			delete(entry_file)
		}
	}

	strings.write_string(&sb, "# End of plugin loading\n")

	// Write to file
	content := strings.to_string(sb)

	if DRY_RUN {
		print_info("[DRY RUN] Would write plugins file: %s", plugins_file)
		return true
	}

	return os.write_entire_file(plugins_file, transmute([]byte)content)
}

// URL validation
is_valid_git_url :: proc(url: string) -> bool {
	// Basic validation - check if it looks like a git URL
	if strings.has_prefix(url, "http://") ||
	   strings.has_prefix(url, "https://") ||
	   strings.has_prefix(url, "git@") {
		return true
	}
	return false
}

// Extract plugin name from URL
extract_plugin_name_from_url :: proc(url: string) -> string {
	// Remove .git suffix if present
	url_clean := strings.trim_suffix(url, ".git")

	// Extract last component from URL
	parts := strings.split(url_clean, "/")
	defer delete(parts)

	if len(parts) > 0 {
		return strings.clone(parts[len(parts) - 1])
	}

	return ""
}

// Find plugin by name in config
find_plugin :: proc(config: ^PluginConfig, name: string) -> (^InstalledPlugin, bool) {
	for &plugin in config.plugins {
		if plugin.name == name {
			return &plugin, true
		}
	}
	return nil, false
}

// Check if plugin is already installed
is_plugin_installed :: proc(config: ^PluginConfig, name: string) -> bool {
	_, found := find_plugin(config, name)
	return found
}

// Find plugin in JSON config by name
// Returns pointer to plugin in config array, or nil if not found
find_plugin_json :: proc(config: ^PluginConfigJSON, name: string) -> (^PluginMetadata, bool) {
	for &plugin in config.plugins {
		if plugin.name == name {
			return &plugin, true
		}
	}
	return nil, false
}

// Validate that all of a plugin's dependencies are installed
// Returns array of missing dependency names
validate_plugin_dependencies :: proc(
	plugin: ^PluginMetadata,
	config: ^PluginConfigJSON,
) -> [dynamic]string {
	missing := make([dynamic]string)

	for dep_name in plugin.dependencies {
		_, found := find_plugin_json(config, dep_name)
		if !found {
			append(&missing, strings.clone(dep_name))
		}
	}

	return missing
}

// Check if any other plugins depend on the given plugin
// Returns array of plugin names that depend on this plugin
check_plugin_dependents :: proc(
	plugin_name: string,
	config: ^PluginConfigJSON,
) -> [dynamic]string {
	dependents := make([dynamic]string)

	for plugin in config.plugins {
		// Skip the plugin itself
		if plugin.name == plugin_name {
			continue
		}

		// Check if this plugin lists plugin_name as a dependency
		for dep_name in plugin.dependencies {
			if dep_name == plugin_name {
				append(&dependents, strings.clone(plugin.name))
				break  // Each plugin only added once
			}
		}
	}

	return dependents
}

// Phase 4: Circular Dependency Detection (Three-Color DFS)

// DFS color states for cycle detection
DFSColor :: enum {
	WHITE = 0,  // Not visited yet
	GRAY  = 1,  // Currently being processed (in recursion stack)
	BLACK = 2,  // Fully processed
}

// Result of circular dependency detection
CycleDetectionResult :: struct {
	has_cycle:  bool,
	cycle_path: [dynamic]string,  // Empty if no cycle
}

// Build directed dependency graph from plugin config
// Returns map: plugin_name -> [dependencies]
build_dependency_graph :: proc(config: ^PluginConfigJSON) -> map[string][dynamic]string {
	graph := make(map[string][dynamic]string)

	for plugin in config.plugins {
		// Initialize entry for this plugin
		if plugin.name not_in graph {
			graph[plugin.name] = make([dynamic]string)
		}

		// Add edges for each dependency
		for dep_name in plugin.dependencies {
			append(&graph[plugin.name], strings.clone(dep_name))
		}
	}

	return graph
}

// Reconstruct cycle path from parent pointers
reconstruct_cycle :: proc(
	cycle_start: string,
	cycle_end: string,
	parent: map[string]string,
) -> [dynamic]string {
	path := make([dynamic]string)

	// Build path from cycle_end back to cycle_start
	append(&path, strings.clone(cycle_start))
	current := cycle_end
	for current != cycle_start {
		append(&path, strings.clone(current))
		current = parent[current]
	}
	append(&path, strings.clone(cycle_start))  // Close the cycle

	// Reverse to get correct order: A → B → C → A
	for i := 0; i < len(path) / 2; i += 1 {
		j := len(path) - 1 - i
		path[i], path[j] = path[j], path[i]
	}

	return path
}

// DFS visit for cycle detection
// Returns true if cycle found
dfs_visit :: proc(
	node: string,
	graph: map[string][dynamic]string,
	color: ^map[string]DFSColor,
	parent: ^map[string]string,
	cycle_start: ^string,
	cycle_end: ^string,
) -> bool {
	color[node] = .GRAY  // Mark as being processed

	// Visit all dependencies
	if node in graph {
		for neighbor in graph[node] {
			if color[neighbor] == .WHITE {
				parent[neighbor] = node
				if dfs_visit(neighbor, graph, color, parent, cycle_start, cycle_end) {
					return true
				}
			} else if color[neighbor] == .GRAY {
				// Back edge detected - cycle found!
				cycle_start^ = neighbor
				cycle_end^ = node
				return true
			}
			// BLACK nodes are fully processed, skip
		}
	}

	color[node] = .BLACK  // Mark as fully processed
	return false
}

// Detect circular dependencies in plugin dependency graph
// Uses three-color DFS with parent tracking for cycle reconstruction
detect_circular_dependencies :: proc(
	graph: map[string][dynamic]string,
) -> CycleDetectionResult {
	color := make(map[string]DFSColor)
	parent := make(map[string]string)
	defer delete(color)
	defer delete(parent)

	// Initialize all nodes as WHITE (unvisited)
	for plugin_name in graph {
		color[plugin_name] = .WHITE
	}

	cycle_start: string = ""
	cycle_end: string = ""

	// Run DFS from each unvisited node
	for plugin_name in graph {
		if color[plugin_name] == .WHITE {
			if dfs_visit(plugin_name, graph, &color, &parent, &cycle_start, &cycle_end) {
				// Cycle found! Reconstruct path
				cycle_path := reconstruct_cycle(cycle_start, cycle_end, parent)
				return CycleDetectionResult{
					has_cycle = true,
					cycle_path = cycle_path,
				}
			}
		}
	}

	// No cycle found
	return CycleDetectionResult{ has_cycle = false }
}

// Validate that plugin configuration has no circular dependencies
// Exits with error if circular dependency detected
validate_no_circular_dependencies :: proc(config: ^PluginConfigJSON) {
	// Build dependency graph
	graph := build_dependency_graph(config)
	defer {
		for _, deps in graph {
			delete(deps)
		}
		delete(graph)
	}

	// Detect cycles
	result := detect_circular_dependencies(graph)
	defer if result.has_cycle do delete(result.cycle_path)

	// If cycle found, print error and exit
	if result.has_cycle {
		cycle_str := strings.join(result.cycle_path[:], " → ")

		print_error("Circular dependency detected: %s", cycle_str)
		fmt.println()
		fmt.println("Circular dependencies prevent determining a valid plugin load order.")
		fmt.println()
		fmt.println("Suggestions:")
		fmt.println("  • Review the dependencies for these plugins")
		fmt.println("  • Remove the dependency that creates the cycle")
		fmt.println("  • Consider if all these dependencies are necessary")

		delete(cycle_str)  // Clean up before exit
		os.exit(EXIT_DATAERR)
	}
}

// Phase 5: Resolve dependencies with priority-based ordering
// Dependencies are resolved first (dependency order), then sorted by priority
// Returns plugins in load order: dependencies first, then by priority
resolve_dependencies_with_priority :: proc(config: ^PluginConfigJSON) -> (order: [dynamic]string, ok: bool) {
	// Build dependency graph
	graph := build_dependency_graph(config)
	defer {
		for _, edges in graph {
			delete(edges)
		}
		delete(graph)
	}

	// Topological sort with DFS (respects dependencies)
	visited := make(map[string]bool)
	defer delete(visited)

	temp_mark := make(map[string]bool)
	defer delete(temp_mark)

	order = make([dynamic]string)

	// Visit all enabled plugins
	for plugin in config.plugins {
		if !plugin.enabled {
			continue
		}

		if !dfs_visit_with_priority(plugin.name, &graph, &visited, &temp_mark, &order, config) {
			// Circular dependency detected
			delete(order)
			return order, false
		}
	}

	// Now sort by priority (stable sort preserves dependency order)
	// Create array of (name, priority) pairs for sorting
	PriorityPair :: struct {
		name: string,
		priority: int,
	}

	pairs := make([dynamic]PriorityPair)
	defer delete(pairs)

	// Build priority map first
	priority_map := make(map[string]int)
	defer delete(priority_map)

	for plugin in config.plugins {
		priority_map[plugin.name] = plugin.priority
	}

	// Create pairs array from order
	for name in order {
		pair := PriorityPair{
			name = name,
			priority = priority_map[name],
		}
		append(&pairs, pair)
	}

	// Stable sort pairs by priority
	slice.stable_sort_by(pairs[:], proc(a, b: PriorityPair) -> bool {
		return a.priority < b.priority
	})

	// Clean up old order strings before replacing
	for name in order {
		delete(name)
	}
	clear(&order)

	// Extract sorted names back into order array
	for pair in pairs {
		append(&order, strings.clone(pair.name))
	}

	return order, true
}

// Phase 5: DFS visit for topological sort with priority awareness
dfs_visit_with_priority :: proc(
	node: string,
	graph: ^map[string][dynamic]string,
	visited: ^map[string]bool,
	temp_mark: ^map[string]bool,
	order: ^[dynamic]string,
	config: ^PluginConfigJSON,
) -> bool {
	// Already processed
	if visited[node] {
		return true
	}

	// Cycle detection
	if temp_mark[node] {
		return false
	}

	temp_mark[node] = true

	// Visit dependencies first
	if deps, has_deps := graph[node]; has_deps {
		for dep in deps {
			if !dfs_visit_with_priority(dep, graph, visited, temp_mark, order, config) {
				return false
			}
		}
	}

	delete_key(temp_mark, node)
	visited[node] = true
	append(order, strings.clone(node))

	return true
}

// Phase 6: Conflict Detection

// Scan plugin for potential conflicts (exports, functions, aliases)
// Parses the plugin's entry file and populates ConflictInfo
scan_plugin_conflicts :: proc(plugin: ^PluginMetadata) -> bool {
	// Detect the entry file first
	entry_file, found := detect_plugin_file(plugin.installed_path, plugin.name, DETECTED_SHELL)

	// If no specific entry file found, return true (no conflicts to scan)
	if !found {
		return true
	}
	defer delete(entry_file)

	if !os.exists(entry_file) {
		return true
	}

	content, read_ok := os.read_entire_file_from_filename(entry_file)
	if !read_ok {
		return false
	}
	defer delete(content)

	script := string(content)
	lines := strings.split_lines(script)
	defer delete(lines)

	// Clear existing conflict data
	delete(plugin.conflicts.env_vars)
	delete(plugin.conflicts.functions)
	delete(plugin.conflicts.aliases_)
	plugin.conflicts.env_vars = make([dynamic]string)
	plugin.conflicts.functions = make([dynamic]string)
	plugin.conflicts.aliases_ = make([dynamic]string)

	// Scan for exports, functions, and aliases
	for line in lines {
		trimmed := strings.trim_space(line)

		// Skip comments and empty lines
		if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") {
			continue
		}

		// Check for exports: export VAR=value
		if strings.has_prefix(trimmed, "export ") {
			after_export := trimmed[7:]  // Skip "export "
			parts := strings.split(after_export, "=")
			if len(parts) >= 1 {
				var_name := strings.trim_space(parts[0])
				if len(var_name) > 0 {
					append(&plugin.conflicts.env_vars, strings.clone(var_name))
				}
			}
			delete(parts)
		}

		// Check for functions (bash/zsh syntax)
		// Pattern 1: function name() {
		// Pattern 2: name() {
		if strings.contains(trimmed, "()") {
			func_name := ""

			if strings.has_prefix(trimmed, "function ") {
				// Pattern: function name() {
				after_function := trimmed[9:]  // Skip "function "
				paren_idx := strings.index(after_function, "(")
				if paren_idx > 0 {
					func_name = strings.trim_space(after_function[:paren_idx])
				}
			} else {
				// Pattern: name() {
				paren_idx := strings.index(trimmed, "()")
				if paren_idx > 0 {
					func_name = strings.trim_space(trimmed[:paren_idx])
				}
			}

			if len(func_name) > 0 {
				append(&plugin.conflicts.functions, strings.clone(func_name))
			}
		}

		// Check for aliases: alias name=value
		if strings.has_prefix(trimmed, "alias ") {
			after_alias := trimmed[6:]  // Skip "alias "
			parts := strings.split(after_alias, "=")
			if len(parts) >= 1 {
				alias_name := strings.trim_space(parts[0])
				if len(alias_name) > 0 {
					append(&plugin.conflicts.aliases_, strings.clone(alias_name))
				}
			}
			delete(parts)
		}
	}

	return true
}

// Detect conflicts between all enabled plugins
// Compares env vars, functions, and aliases to find duplicates
detect_conflicts :: proc(config: ^PluginConfigJSON) {
	// First, scan all enabled plugins for their declarations
	for &plugin in config.plugins {
		if !plugin.enabled {
			continue
		}

		scan_plugin_conflicts(&plugin)
	}

	// Now compare plugins pairwise to detect conflicts
	for i := 0; i < len(config.plugins); i += 1 {
		plugin_a := &config.plugins[i]

		if !plugin_a.enabled {
			continue
		}

		// Clear previous conflict tracking
		delete(plugin_a.conflicts.conflicting_plugins)
		plugin_a.conflicts.conflicting_plugins = make([dynamic]string)
		plugin_a.conflicts.detected = false

		for j := i + 1; j < len(config.plugins); j += 1 {
			plugin_b := &config.plugins[j]

			if !plugin_b.enabled {
				continue
			}

			has_conflict := false

			// Check environment variable conflicts
			for var_a in plugin_a.conflicts.env_vars {
				for var_b in plugin_b.conflicts.env_vars {
					if var_a == var_b {
						has_conflict = true
						break
					}
				}
				if has_conflict do break
			}

			// Check function conflicts
			if !has_conflict {
				for func_a in plugin_a.conflicts.functions {
					for func_b in plugin_b.conflicts.functions {
						if func_a == func_b {
							has_conflict = true
							break
						}
					}
					if has_conflict do break
				}
			}

			// Check alias conflicts
			if !has_conflict {
				for alias_a in plugin_a.conflicts.aliases_ {
					for alias_b in plugin_b.conflicts.aliases_ {
						if alias_a == alias_b {
							has_conflict = true
							break
						}
					}
					if has_conflict do break
				}
			}

			// If conflict found, mark both plugins
			if has_conflict {
				plugin_a.conflicts.detected = true
				plugin_b.conflicts.detected = true

				// Add to conflicting plugins list (avoid duplicates)
				already_tracked := false
				for existing in plugin_a.conflicts.conflicting_plugins {
					if existing == plugin_b.name {
						already_tracked = true
						break
					}
				}
				if !already_tracked {
					append(&plugin_a.conflicts.conflicting_plugins, strings.clone(plugin_b.name))
				}

				// Also track in plugin_b
				already_tracked_b := false
				for existing in plugin_b.conflicts.conflicting_plugins {
					if existing == plugin_a.name {
						already_tracked_b = true
						break
					}
				}
				if !already_tracked_b {
					append(&plugin_b.conflicts.conflicting_plugins, strings.clone(plugin_a.name))
				}
			}
		}
	}
}

// Resolve plugin name or URL to PluginInfo
resolve_plugin :: proc(name_or_url: string) -> (PluginInfo, bool) {
	// Check if it's a URL
	if is_valid_git_url(name_or_url) {
		// Extract name from URL
		plugin_name := extract_plugin_name_from_url(name_or_url)

		return PluginInfo{
			name = plugin_name,
			url = name_or_url,
			shell = .BOTH, // Unknown shell compat for custom URLs
			description = "Custom plugin",
		}, true
	}

	// Check popular plugins registry
	if info, found := POPULAR_PLUGINS[name_or_url]; found {
		return info, true
	}

	return PluginInfo{}, false
}

// Get remote commit SHA for a git repository
// Returns short SHA (7 chars) or empty string on failure
// CRITICAL: Returned string is ALLOCATED - caller must delete()
get_remote_commit :: proc(url: string, branch: string) -> string {
	// Use HEAD if no branch specified
	branch_ref := branch != "" ? branch : "HEAD"

	// Build command: git ls-remote <url> <branch> 2>/dev/null | cut -f1
	// The '2>/dev/null' suppresses error output
	// The 'cut -f1' extracts just the commit SHA (first field)
	cmd := fmt.aprintf("git ls-remote %s %s 2>/dev/null | cut -f1", url, branch_ref)
	defer delete(cmd)

	// Execute and get full SHA (40 chars) or empty string
	full_sha := exec_command_output(cmd)  // ALLOCATED - must delete
	if full_sha == "" {
		return ""
	}

	// Extract short SHA (first 7 chars)
	// NOTE: Create new allocated string before deleting full_sha
	short_sha := strings.clone(full_sha[0:min(7, len(full_sha))])
	delete(full_sha)  // Clean up full SHA

	return short_sha  // Caller's responsibility to delete
}

// Handle plugin check command - check for available updates
// CLI-only command (no interactive mode)
// Checks all enabled plugins for updates using git ls-remote
handle_plugin_check :: proc(args: []string) {
	// Read plugin configuration
	config, ok := read_plugin_config_json()
	if !ok {
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	// Handle empty plugin list (non-error case)
	if len(config.plugins) == 0 {
		print_info("No plugins installed")
		fmt.println()
		fmt.println("Run 'wayu plugin add <name>' to install a plugin")
		return
	}

	// Display header
	print_header("Checking Plugin Updates", EMOJI_COMMAND)
	fmt.println()

	updates_available := false
	check_count := 0

	// Check each enabled plugin
	for &plugin in config.plugins {
		// Skip disabled plugins
		if !plugin.enabled {
			continue
		}

		check_count += 1
		fmt.printfln("Checking %s...", plugin.name)

		// Fetch remote commit SHA
		remote_commit := get_remote_commit(plugin.url, plugin.git.branch)
		if remote_commit == "" {
			print_warning("  ⚠ Failed to check remote (network error or invalid URL)")
			continue
		}
		defer delete(remote_commit)  // CRITICAL: get_remote_commit returns allocated string

		// Update metadata with remote commit and timestamp
		delete(plugin.git.remote_commit)  // Clean up old value
		plugin.git.remote_commit = strings.clone(remote_commit)

		delete(plugin.git.last_checked)  // Clean up old timestamp
		plugin.git.last_checked = get_iso8601_timestamp()  // ALLOCATED

		// Compare local vs remote commits
		if plugin.git.commit != remote_commit {
			// Truncate to 7 chars for display
			local_short := plugin.git.commit[0:min(7, len(plugin.git.commit))]
			remote_short := remote_commit[0:min(7, len(remote_commit))]

			print_success("  ↑ Update available: %s → %s", local_short, remote_short)
			updates_available = true
		} else {
			print_info("  ✓ Up to date")
		}
	}

	fmt.println()

	// No enabled plugins to check
	if check_count == 0 {
		print_info("No enabled plugins to check")
		fmt.println()
		print_info("Enable plugins with: wayu --tui")
		return
	}

	// Save updated metadata (last_checked timestamps)
	if !DRY_RUN {
		if !write_plugin_config_json(&config) {
			print_error_simple("Error: Failed to save plugin metadata")
			os.exit(EXIT_CONFIG)
		}
	} else {
		print_info("[DRY RUN] Would save updated metadata")
	}

	// Display summary
	if updates_available {
		fmt.println()
		print_info("Updates available! Run one of:")
		fmt.println("  wayu plugin update <name>      # Update specific plugin")
		fmt.println("  wayu plugin update --all       # Update all plugins")
	} else {
		print_success("All plugins are up to date!")
	}
}

// Handle plugin update command - update plugins
// Supports both single plugin and --all flag
// CLI-only command (no interactive mode)
handle_plugin_update :: proc(args: []string) {
	// Require explicit argument (plugin name or --all)
	if len(args) == 0 {
		print_error("Missing required argument: plugin name or --all")
		fmt.println()
		fmt.println("Usage:")
		fmt.println("  wayu plugin update <name>      # Update specific plugin")
		fmt.println("  wayu plugin update --all       # Update all plugins")
		fmt.println()
		fmt.printfln("%sExample:%s", get_muted(), RESET)
		fmt.printfln("  %swayu plugin update zsh-autosuggestions%s", get_muted(), RESET)
		os.exit(EXIT_USAGE)
	}

	update_all := args[0] == "--all" || args[0] == "-a"

	// Read plugin configuration
	config, ok := read_plugin_config_json()
	if !ok {
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	// Handle empty plugin list
	if len(config.plugins) == 0 {
		print_info("No plugins installed")
		fmt.println()
		fmt.println("Run 'wayu plugin add <name>' to install a plugin")
		return
	}

	// Display header
	if update_all {
		print_header("Updating All Plugins", EMOJI_COMMAND)
	} else {
		print_header("Updating Plugin", EMOJI_COMMAND)
	}
	fmt.println()

	updated_count := 0

	// Update specific plugin
	if !update_all {
		plugin_name := args[0]

		// Find plugin
		plugin_ptr: ^PluginMetadata = nil
		for &plugin in config.plugins {
			if plugin.name == plugin_name {
				plugin_ptr = &plugin
				break
			}
		}

		if plugin_ptr == nil {
			print_error_simple("Error: Plugin '%s' not found", plugin_name)
			fmt.println()
			fmt.println("Run 'wayu plugin list' to see installed plugins")
			os.exit(EXIT_DATAERR)
		}

		// Perform update
		print_info("Updating %s...", plugin_ptr.name)

		// Show spinner for long operation
		spinner := new_spinner(.Dots)
		spinner_text(&spinner, fmt.aprintf("Updating %s", plugin_ptr.name))
		spinner_start(&spinner)

		success := git_update(plugin_ptr.installed_path)

		spinner_stop(&spinner)

		if !success {
			print_error_simple("Error: Failed to update plugin")
			os.exit(EXIT_IOERR)
		}

		// Refresh git metadata after update
		new_git_info := get_git_info(plugin_ptr.installed_path)

		// Clean up old git metadata
		delete(plugin_ptr.git.branch)
		delete(plugin_ptr.git.commit)
		delete(plugin_ptr.git.last_checked)
		delete(plugin_ptr.git.remote_commit)

		// Assign new metadata
		plugin_ptr.git = new_git_info

		print_success("Plugin '%s' updated successfully", plugin_ptr.name)
		updated_count = 1
	} else {
		// Update all plugins
		for &plugin in config.plugins {
			// Skip disabled plugins
			if !plugin.enabled {
				continue
			}

			print_info("Updating %s...", plugin.name)

			// Perform update
			success := git_update(plugin.installed_path)

			if !success {
				print_warning("  ⚠ Failed to update plugin")
				continue
			}

			// Refresh git metadata
			new_git_info := get_git_info(plugin.installed_path)

			// Clean up old git metadata
			delete(plugin.git.branch)
			delete(plugin.git.commit)
			delete(plugin.git.last_checked)
			delete(plugin.git.remote_commit)

			// Assign new metadata
			plugin.git = new_git_info

			print_success("  ✓ Updated")
			updated_count += 1
		}
	}

	fmt.println()

	// Save updated metadata
	if !DRY_RUN {
		// Create backup before writing
		config_file := get_plugins_json_config_file()
		defer delete(config_file)

		if os.exists(config_file) {
			backup_path, backup_ok := create_backup(config_file)
			if backup_ok {
				defer delete(backup_path)
			} else {
				print_warning("Warning: Failed to create backup")
			}
		}

		// Write updated config
		if !write_plugin_config_json(&config) {
			print_error_simple("Error: Failed to save plugin metadata")
			os.exit(EXIT_CONFIG)
		}
	} else {
		print_info("[DRY RUN] Would save updated metadata")
	}

	// Summary
	if updated_count == 0 {
		print_info("No plugins updated")
	} else if updated_count == 1 {
		print_success("1 plugin updated")
	} else {
		print_success("%d plugins updated", updated_count)
	}

	// Regenerate plugins loader file for current shell
	if !DRY_RUN {
		if !generate_plugins_file(DETECTED_SHELL) {
			print_warning("Warning: Failed to regenerate plugins loader")
		}
	}

	fmt.println()
	print_info("Restart your shell or run 'source ~/.%src' to reload plugins", SHELL_EXT)
}

// Handle plugin enable command - enable a disabled plugin
// Sets enabled: true in plugins.json and regenerates shell loader
// CLI-only command (no interactive mode)
// Idempotent: Enabling an already-enabled plugin returns EXIT_SUCCESS
handle_plugin_enable :: proc(args: []string) {
	// 1. Validate arguments
	if len(args) == 0 {
		print_error("Missing required argument: plugin name")
		fmt.println()
		fmt.println("Usage: wayu plugin enable <name>")
		fmt.println()
		fmt.println("Example:")
		fmt.println("  wayu plugin enable zsh-autosuggestions")
		fmt.println()
		fmt.printfln("%sHint:%s For interactive selection, use: %swayu --tui%s",
			get_muted(), RESET, get_primary(), RESET)
		os.exit(EXIT_USAGE)
	}

	plugin_name := args[0]

	// 2. Read plugin configuration
	config, ok := read_plugin_config_json()
	if !ok {
		os.exit(EXIT_CONFIG)
	}

	// 3. Find plugin by name
	plugin_ptr: ^PluginMetadata = nil
	for &plugin in config.plugins {
		if plugin.name == plugin_name {
			plugin_ptr = &plugin
			break
		}
	}

	if plugin_ptr == nil {
		cleanup_plugin_config_json(&config)
		print_error_simple("Error: Plugin '%s' not found", plugin_name)
		fmt.println()
		fmt.println("Run 'wayu plugin list' to see installed plugins")
		os.exit(EXIT_DATAERR)
	}

	// 4. Check if already enabled (idempotent operation)
	if plugin_ptr.enabled {
		cleanup_plugin_config_json(&config)
		print_info("Plugin '%s' is already enabled", plugin_name)
		os.exit(EXIT_SUCCESS)  // NOT an error - idempotent
	}

	// Display header
	print_header("Enabling Plugin", EMOJI_COMMAND)
	fmt.println()

	// 5. Create backup before modifying
	config_file := get_plugins_json_config_file()

	if os.exists(config_file) {
		backup_path, backup_ok := create_backup(config_file)
		if backup_ok {
			delete(backup_path)
		} else {
			print_warning("Warning: Failed to create backup")
		}
	}

	// 6. Enable plugin
	plugin_ptr.enabled = true

	// 7. Write updated configuration
	if !DRY_RUN {
		if !write_plugin_config_json(&config) {
			delete(config_file)
			cleanup_plugin_config_json(&config)
			print_error_simple("Error: Failed to save plugin configuration")
			os.exit(EXIT_CONFIG)
		}
	} else {
		print_info("[DRY RUN] Would save updated configuration")
	}

	// 8. Regenerate shell loader
	if !DRY_RUN {
		if !generate_plugins_file(DETECTED_SHELL) {
			delete(config_file)
			cleanup_plugin_config_json(&config)
			print_error_simple("Error: Failed to regenerate plugins loader")
			os.exit(EXIT_IOERR)
		}
	} else {
		print_info("[DRY RUN] Would regenerate shell loader")
	}

	// 9. Success
	delete(config_file)
	cleanup_plugin_config_json(&config)
	print_success("Plugin '%s' enabled successfully", plugin_name)
	fmt.println()
	fmt.printfln("%sThe plugin will be loaded in new shell sessions.%s", BRIGHT_CYAN, RESET)
	fmt.printfln("Restart your shell or run 'source ~/.%src' to apply changes.", SHELL_EXT)

	os.exit(EXIT_SUCCESS)
}

// Handle plugin disable command - disable an enabled plugin
// Sets enabled: false in plugins.json and regenerates shell loader
// CLI-only command (no interactive mode)
// Plugin remains installed, only prevents loading on shell startup
// Idempotent: Disabling an already-disabled plugin returns EXIT_SUCCESS
handle_plugin_disable :: proc(args: []string) {
	// 1. Validate arguments
	if len(args) == 0 {
		print_error("Missing required argument: plugin name")
		fmt.println()
		fmt.println("Usage: wayu plugin disable <name>")
		fmt.println()
		fmt.println("Example:")
		fmt.println("  wayu plugin disable zsh-autosuggestions")
		fmt.println()
		fmt.printfln("%sHint:%s For interactive selection, use: %swayu --tui%s",
			get_muted(), RESET, get_primary(), RESET)
		os.exit(EXIT_USAGE)
	}

	plugin_name := args[0]

	// 2. Read plugin configuration
	config, ok := read_plugin_config_json()
	if !ok {
		os.exit(EXIT_CONFIG)
	}

	// 3. Find plugin by name
	plugin_ptr: ^PluginMetadata = nil
	for &plugin in config.plugins {
		if plugin.name == plugin_name {
			plugin_ptr = &plugin
			break
		}
	}

	if plugin_ptr == nil {
		cleanup_plugin_config_json(&config)
		print_error_simple("Error: Plugin '%s' not found", plugin_name)
		fmt.println()
		fmt.println("Run 'wayu plugin list' to see installed plugins")
		os.exit(EXIT_DATAERR)
	}

	// 4. Check if already disabled (idempotent operation)
	if !plugin_ptr.enabled {
		cleanup_plugin_config_json(&config)
		print_info("Plugin '%s' is already disabled", plugin_name)
		os.exit(EXIT_SUCCESS)  // NOT an error - idempotent
	}

	// Display header
	print_header("Disabling Plugin", EMOJI_COMMAND)
	fmt.println()

	// 5. Create backup before modifying
	config_file := get_plugins_json_config_file()

	if os.exists(config_file) {
		backup_path, backup_ok := create_backup(config_file)
		if backup_ok {
			delete(backup_path)
		} else {
			print_warning("Warning: Failed to create backup")
		}
	}

	// 6. Disable plugin
	plugin_ptr.enabled = false

	// 7. Write updated configuration
	if !DRY_RUN {
		if !write_plugin_config_json(&config) {
			delete(config_file)
			cleanup_plugin_config_json(&config)
			print_error_simple("Error: Failed to save plugin configuration")
			os.exit(EXIT_CONFIG)
		}
	} else {
		print_info("[DRY RUN] Would save updated configuration")
	}

	// 8. Regenerate shell loader
	if !DRY_RUN {
		if !generate_plugins_file(DETECTED_SHELL) {
			delete(config_file)
			cleanup_plugin_config_json(&config)
			print_error_simple("Error: Failed to regenerate plugins loader")
			os.exit(EXIT_IOERR)
		}
	} else {
		print_info("[DRY RUN] Would regenerate shell loader")
	}

	// 9. Success
	delete(config_file)
	cleanup_plugin_config_json(&config)
	print_success("Plugin '%s' disabled successfully", plugin_name)
	fmt.println()
	fmt.printfln("%sThe plugin will not be loaded in new shell sessions.%s", BRIGHT_CYAN, RESET)
	fmt.printfln("Restart your shell or run 'source ~/.%src' to apply changes.", SHELL_EXT)
	fmt.println()
	fmt.printfln("%sTo re-enable:%s wayu plugin enable %s", get_muted(), RESET, plugin_name)

	os.exit(EXIT_SUCCESS)
}

// Handle plugin priority command - set plugin load priority
// Lower priority numbers load first (default: 100)
// CLI-only command (no interactive mode)
handle_plugin_priority :: proc(args: []string) {
	// 1. Validate arguments
	if len(args) < 2 {
		print_error("Missing required arguments: plugin name and priority")
		fmt.println()
		fmt.println("Usage: wayu plugin priority <name> <number>")
		fmt.println()
		fmt.println("  Lower numbers load first (default: 100)")
		fmt.println()
		fmt.println("Example:")
		fmt.println("  wayu plugin priority zsh-autosuggestions 50")
		os.exit(EXIT_USAGE)
	}

	plugin_name := args[0]
	priority_str := args[1]

	// 2. Parse priority number
	priority, ok := strconv.parse_int(priority_str)
	if !ok {
		print_error_simple("Error: Invalid priority number '%s'", priority_str)
		fmt.println()
		fmt.println("Priority must be a valid integer")
		os.exit(EXIT_USAGE)
	}

	// 3. Read config
	config, read_ok := read_plugin_config_json()
	if !read_ok {
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	// 4. Find plugin
	plugin, found := find_plugin_json(&config, plugin_name)
	if !found {
		print_error_simple("Error: Plugin '%s' not found", plugin_name)
		fmt.println()
		fmt.println("Use 'wayu plugin list' to see installed plugins")
		os.exit(EXIT_DATAERR)
	}

	if DRY_RUN {
		print_info("[DRY RUN] Would set priority of '%s' to %d (current: %d)",
			plugin_name, priority, plugin.priority)
		return
	}

	// Display header
	print_header("Setting Plugin Priority", EMOJI_COMMAND)
	fmt.println()

	old_priority := plugin.priority
	plugin.priority = priority

	// 5. Create backup before modifying
	config_file := get_plugins_json_config_file()
	defer delete(config_file)

	if os.exists(config_file) {
		backup_path, backup_ok := create_backup(config_file)
		if backup_ok {
			defer delete(backup_path)
		} else {
			print_warning("Warning: Failed to create backup")
		}
	}

	// 6. Save config
	if !write_plugin_config_json(&config) {
		print_error_simple("Error: Failed to save configuration")
		os.exit(EXIT_CANTCREAT)
	}

	// 7. Regenerate loader (load order changed)
	if !generate_plugins_file(DETECTED_SHELL) {
		print_warning("Warning: Failed to regenerate plugin loader")
		// Don't exit - config was saved successfully
	}

	// 8. Success
	print_success("Updated priority for '%s': %d → %d", plugin_name, old_priority, priority)
	fmt.println()
	fmt.println("Restart your shell for changes to take effect")
}

// Command handlers

// Handle plugin add command
handle_plugin_add :: proc(args: []string) {
	if len(args) == 0 {
		print_error_simple("Error: Plugin name or URL required")
		print_plugin_add_help()
		os.exit(1)
	}

	name_or_url := args[0]

	// Resolve plugin
	info, resolved := resolve_plugin(name_or_url)
	if !resolved {
		print_error_simple("Error: Unknown plugin '%s'", name_or_url)
		fmt.println("\nRun 'wayu plugin search' to see available plugins")
		os.exit(1)
	}
	defer delete(info.name)
	defer delete(info.url)
	defer delete(info.description)

	// Read current config
	config, ok := read_plugin_config_json()
	if !ok {
		print_error_simple("Error: Failed to read plugin configuration")
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	// Check if already installed
	_, found := find_plugin_json(&config, info.name)
	if found {
		print_warning("Plugin '%s' is already installed", info.name)
		os.exit(EXIT_SUCCESS)
	}

	print_header("Installing Plugin", EMOJI_COMMAND)
	print_info("Name: %s", info.name)
	print_info("URL: %s", info.url)
	print_info("Shell: %s", shell_compat_to_string(info.shell))
	fmt.println()

	// Create plugins directory if it doesn't exist
	plugins_dir := get_plugins_dir()
	defer delete(plugins_dir)

	if !os.exists(plugins_dir) && !DRY_RUN {
		err := os.make_directory(plugins_dir)
		if err != nil {
			print_error_simple("Error: Failed to create plugins directory: %v", err)
			os.exit(1)
		}
	}

	// Clone repository
	plugin_path := fmt.aprintf("%s/%s", plugins_dir, info.name)
	defer delete(plugin_path)

	spinner := new_spinner(.Dots)
	spinner_text(&spinner, "Cloning repository")
	spinner_start(&spinner)

	success := git_clone(info.url, plugin_path)

	spinner_stop(&spinner)

	if !success {
		print_error_simple("Error: Failed to clone plugin repository")
		os.exit(1)
	}

	print_success("Cloned plugin repository")

	// Add to config
	git_info := get_git_info(plugin_path)

	new_plugin := PluginMetadata{
		name = strings.clone(info.name),
		url = strings.clone(info.url),
		enabled = true,
		shell = info.shell,
		installed_path = strings.clone(plugin_path),
		entry_file = "",  // Will be detected by generate_plugins_file
		git = git_info,
		dependencies = make([dynamic]string),  // Phase 4: Initialize empty
		priority = 100,  // Phase 5: Default priority
		config = make(map[string]string),  // Phase 6: Empty config
		conflicts = ConflictInfo{},  // Phase 6: No conflicts yet
	}

	append(&config.plugins, new_plugin)

	// Phase 4: Validate no circular dependencies before writing config
	validate_no_circular_dependencies(&config)

	// Create backup before writing
	if !DRY_RUN {
		config_file := get_plugins_json_config_file()
		defer delete(config_file)

		if os.exists(config_file) {
			backup_path, backup_ok := create_backup(config_file)
			if backup_ok {
				defer delete(backup_path)
			}
		}
	}

	// Write config
	if !write_plugin_config_json(&config) {
		print_error_simple("Error: Failed to write plugin configuration")
		os.exit(EXIT_IOERR)
	}

	// Generate plugins file for current shell
	if !generate_plugins_file(DETECTED_SHELL) {
		print_error_simple("Error: Failed to generate plugins loader")
		os.exit(1)
	}

	print_success("Plugin '%s' installed successfully", info.name)
	fmt.println()
	print_info("Restart your shell or run 'source ~/.%src' to load the plugin", SHELL_EXT)
}

// Handle plugin list command
handle_plugin_list :: proc(args: []string) {
	// Run migration if needed
	if !migrate_plugin_config() {
		os.exit(EXIT_CONFIG)
	}

	// Use JSON5 config if it exists, otherwise fall back to old format
	json_file := get_plugins_json_config_file()
	defer delete(json_file)

	use_json := os.exists(json_file)

	if use_json {
		// Read from JSON5 config
		config, ok := read_plugin_config_json()
		if !ok {
			os.exit(EXIT_CONFIG)
		}
		defer cleanup_plugin_config_json(&config)

		if len(config.plugins) == 0 {
			print_info("No plugins installed")
			fmt.println("\nRun 'wayu plugin add <name>' to install a plugin")
			return
		}

		print_header("Installed Plugins", EMOJI_COMMAND)
		fmt.println()

		// Create table
		table := new_table([]string{"Name", "Status", "Priority", "Shell", "URL"})
		defer delete(table.rows)

		for plugin in config.plugins {
			status := plugin.enabled ? "✓ Active" : "○ Disabled"
			priority_str := fmt.aprintf("%d", plugin.priority)
			shell_str := shell_compat_to_string(plugin.shell)

			// Truncate URL for display
			url_display := plugin.url
			if len(url_display) > 40 {
				url_display = fmt.aprintf("%s...", plugin.url[:37])
			}

			row := []string{plugin.name, status, priority_str, shell_str, url_display}
			table_add_row(&table, row)
			delete(priority_str)

			if len(url_display) > 40 {
				delete(url_display)
			}
		}

		output := table_render(table)
		defer delete(output)
		fmt.print(output)

		fmt.println()
		enabled_count := 0
		for plugin in config.plugins {
			if plugin.enabled {
				enabled_count += 1
			}
		}

		print_info("%d plugins installed (%d enabled)", len(config.plugins), enabled_count)
	} else {
		// Fall back to old format (for backward compatibility during transition)
		config := read_plugin_config()
		defer {
			for plugin in config.plugins {
				delete(plugin.name)
				delete(plugin.url)
				delete(plugin.installed_path)
				delete(plugin.entry_file)
			}
			delete(config.plugins)
		}

		if len(config.plugins) == 0 {
			print_info("No plugins installed")
			fmt.println("\nRun 'wayu plugin add <name>' to install a plugin")
			return
		}

		print_header("Installed Plugins", EMOJI_COMMAND)
		fmt.println()

		// Create table (old format fallback - priority defaults to 100)
		table := new_table([]string{"Name", "Status", "Priority", "Shell", "URL"})
		defer delete(table.rows)

		for plugin in config.plugins {
			status := plugin.enabled ? "✓ Active" : "○ Disabled"
			priority_str := fmt.aprintf("%d", 100)  // Old format doesn't have priority field
			shell_str := shell_compat_to_string(plugin.shell)

			// Truncate URL for display
			url_display := plugin.url
			if len(url_display) > 40 {
				url_display = fmt.aprintf("%s...", plugin.url[:37])
			}

			row := []string{plugin.name, status, priority_str, shell_str, url_display}
			table_add_row(&table, row)
			delete(priority_str)

			if len(url_display) > 40 {
				delete(url_display)
			}
		}

		output := table_render(table)
		defer delete(output)
		fmt.print(output)

		fmt.println()
		enabled_count := 0
		for plugin in config.plugins {
			if plugin.enabled {
				enabled_count += 1
			}
		}

		print_info("%d plugins installed (%d enabled)", len(config.plugins), enabled_count)
	}
}

// Handle plugin remove command
handle_plugin_remove :: proc(args: []string) {
	// Read plugin configuration
	config, ok := read_plugin_config_json()
	if !ok {
		print_error_simple("Error: Failed to read plugin configuration")
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	if len(config.plugins) == 0 {
		print_info("No plugins installed")
		return
	}

	// Require explicit plugin name (no interactive selection in CLI)
	if len(args) == 0 {
		print_error("Missing required argument: plugin name")
		fmt.println()
		fmt.println("Usage: wayu plugin rm <name>")
		fmt.println()
		fmt.println("Example:")
		fmt.println("  wayu plugin rm syntax-highlighting")
		fmt.println()
		fmt.printfln("%sHint:%s For interactive selection, use: %swayu --tui%s",
			get_muted(), RESET, get_primary(), RESET)
		os.exit(EXIT_USAGE)
	}

	plugin_name := args[0]

	// Find plugin
	plugin_ptr, found := find_plugin_json(&config, plugin_name)
	if !found {
		print_error_simple("Error: Plugin '%s' not found", plugin_name)
		os.exit(EXIT_DATAERR)
	}

	// Phase 4: Check if other plugins depend on this one
	dependents := check_plugin_dependents(plugin_name, &config)
	defer delete(dependents)

	if len(dependents) > 0 {
		print_warning("Warning: The following plugins depend on '%s':", plugin_name)
		for dep in dependents {
			fmt.printfln("  - %s", dep)
		}
		fmt.println()
		print_warning("Removing this plugin may break these plugins.")
		fmt.println()

		// In CLI mode: respect --yes flag
		if !YES_FLAG {
			fmt.print("Continue anyway? [y/N] ")

			// Read user input
			input_buf: [256]byte
			n, err := os.read(os.stdin, input_buf[:])
			if err != nil || n == 0 {
				fmt.println("Cancelled.")
				os.exit(EXIT_SUCCESS)
			}

			response := string(input_buf[:n])
			response = strings.trim_space(response)
			response = strings.to_lower(response)
			defer delete(response)

			if response != "y" && response != "yes" {
				fmt.println("Cancelled.")
				os.exit(EXIT_SUCCESS)
			}
		}
	}

	print_header("Removing Plugin", EMOJI_COMMAND)
	print_info("Name: %s", plugin_ptr.name)
	fmt.println()

	// Remove plugin directory
	if os.exists(plugin_ptr.installed_path) && !DRY_RUN {
		// Use rm -rf to remove directory
		rm_cmd := fmt.aprintf("rm -rf \"%s\"", plugin_ptr.installed_path)
		defer delete(rm_cmd)

		cmd_cstr := strings.clone_to_cstring(rm_cmd)
		defer delete(cmd_cstr)

		result := libc.system(cmd_cstr)
		if result != 0 {
			print_error_simple("Error: Failed to remove plugin directory")
			os.exit(EXIT_IOERR)
		}
	}

	print_success("Removed plugin directory")

	// Remove from config
	new_plugins := make([dynamic]PluginMetadata)
	defer delete(new_plugins)

	for &plugin in config.plugins {
		if plugin.name != plugin_name {
			append(&new_plugins, plugin)
		} else {
			// Clean up memory for removed plugin
			cleanup_plugin_metadata(&plugin)
		}
	}

	config.plugins = new_plugins

	// Create backup before writing
	if !DRY_RUN {
		config_file := get_plugins_json_config_file()
		defer delete(config_file)

		if os.exists(config_file) {
			backup_path, backup_ok := create_backup(config_file)
			if backup_ok {
				defer delete(backup_path)
			}
		}
	}

	// Write config
	if !write_plugin_config_json(&config) {
		print_error_simple("Error: Failed to write plugin configuration")
		os.exit(EXIT_IOERR)
	}

	// Generate plugins file
	if !generate_plugins_file(DETECTED_SHELL) {
		print_error_simple("Error: Failed to generate plugins loader")
		os.exit(EXIT_IOERR)
	}

	print_success("Plugin '%s' removed successfully", plugin_name)
}

// Handle plugin get command - display plugin info and copy URL to clipboard
handle_plugin_get :: proc(args: []string) {
	if len(args) == 0 {
		print_error_simple("Error: Plugin name required")
		fmt.println("\nUsage: wayu plugin get <name>")
		os.exit(1)
	}

	plugin_name := args[0]

	// Read current config
	config := read_plugin_config()
	defer {
		for plugin in config.plugins {
			delete(plugin.name)
			delete(plugin.url)
			delete(plugin.installed_path)
			delete(plugin.entry_file)
		}
		delete(config.plugins)
	}

	// Find plugin
	plugin_ptr, found := find_plugin(&config, plugin_name)
	if !found {
		print_error_simple("Error: Plugin '%s' not found", plugin_name)
		fmt.println("\nRun 'wayu plugin list' to see installed plugins")
		os.exit(1)
	}

	// Display plugin information
	print_header("Plugin Information", EMOJI_COMMAND)
	fmt.println()

	// Create table with plugin details
	table := new_table([]string{"Property", "Value"})
	defer delete(table.rows)

	table_add_row(&table, []string{"Name", plugin_ptr.name})
	table_add_row(&table, []string{"URL", plugin_ptr.url})
	table_add_row(&table, []string{"Status", plugin_ptr.enabled ? "✓ Enabled" : "○ Disabled"})
	table_add_row(&table, []string{"Shell", shell_compat_to_string(plugin_ptr.shell)})
	table_add_row(&table, []string{"Path", plugin_ptr.installed_path})

	output := table_render(table)
	defer delete(output)
	fmt.print(output)

	fmt.println()

	// Copy URL to clipboard
	if !DRY_RUN {
		// Detect platform and use appropriate clipboard command
		when ODIN_OS == .Darwin {
			// macOS - use pbcopy
			cmd := fmt.aprintf("printf '%%s' \"%s\" | pbcopy", plugin_ptr.url)
			defer delete(cmd)

			cmd_cstr := strings.clone_to_cstring(cmd)
			defer delete(cmd_cstr)

			result := libc.system(cmd_cstr)
			if result == 0 {
				print_success("URL copied to clipboard: %s", plugin_ptr.url)
			} else {
				print_warning("Failed to copy URL to clipboard")
				print_info("URL: %s", plugin_ptr.url)
			}
		} else when ODIN_OS == .Linux {
			// Linux - try xclip first, then xsel
			cmd := fmt.aprintf("printf '%%s' \"%s\" | xclip -selection clipboard 2>/dev/null || printf '%%s' \"%s\" | xsel --clipboard",
				plugin_ptr.url, plugin_ptr.url)
			defer delete(cmd)

			cmd_cstr := strings.clone_to_cstring(cmd)
			defer delete(cmd_cstr)

			result := libc.system(cmd_cstr)
			if result == 0 {
				print_success("URL copied to clipboard: %s", plugin_ptr.url)
			} else {
				print_warning("Failed to copy URL to clipboard (install xclip or xsel)")
				print_info("URL: %s", plugin_ptr.url)
			}
		} else when ODIN_OS == .Windows {
			// Windows - use clip.exe
			cmd := fmt.aprintf("echo %s | clip", plugin_ptr.url)
			defer delete(cmd)

			cmd_cstr := strings.clone_to_cstring(cmd)
			defer delete(cmd_cstr)

			result := libc.system(cmd_cstr)
			if result == 0 {
				print_success("URL copied to clipboard: %s", plugin_ptr.url)
			} else {
				print_warning("Failed to copy URL to clipboard")
				print_info("URL: %s", plugin_ptr.url)
			}
		} else {
			// Unsupported OS
			print_warning("Clipboard copy not supported on this platform")
			print_info("URL: %s", plugin_ptr.url)
		}
	} else {
		print_info("[DRY RUN] Would copy URL to clipboard: %s", plugin_ptr.url)
	}
}

// Handle plugin command routing
handle_plugin_command :: proc(action: Action, args: []string) {
	#partial switch action {
	case .ADD:
		handle_plugin_add(args)
	case .REMOVE:
		handle_plugin_remove(args)
	case .LIST:
		handle_plugin_list(args)
	case .GET:
		handle_plugin_get(args)
	case .CHECK:
		handle_plugin_check(args)
	case .UPDATE:
		handle_plugin_update(args)
	case .ENABLE:
		handle_plugin_enable(args)
	case .DISABLE:
		handle_plugin_disable(args)
	case .PRIORITY:
		handle_plugin_priority(args)
	case .HELP:
		print_plugin_help()
	case:
		print_error_simple("Unknown plugin action")
		print_plugin_help()
		os.exit(1)
	}
}

// Help text

print_plugin_help :: proc() {
	// Title
	fmt.printf("\n%s%swayu plugin - Plugin management%s\n\n", BOLD, get_primary(), RESET)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu plugin <action> [arguments]")

	// Actions section
	fmt.printf("\n%s%sACTIONS:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  add <name-or-url>       Install plugin")
	fmt.println("  remove [name]           Remove plugin (interactive if no name)")
	fmt.println("  list                    List installed plugins")
	fmt.println("  enable <name>           Enable disabled plugin")
	fmt.println("  disable <name>          Disable plugin without removing")
	fmt.println("  priority <name> <num>   Set plugin load priority (lower = earlier)")
	fmt.println("  get <name>              Show plugin info and copy URL to clipboard")
	fmt.println("  check                   Check all plugins for updates")
	fmt.println("  update <name|--all>     Update specific plugin or all plugins")
	fmt.println("  help                    Show this help message")

	// Examples section
	fmt.printf("\n%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %s# Install popular plugin%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin add syntax-highlighting%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Install from URL%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin add https://github.com/user/plugin.git%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Show all plugins%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin list%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Get plugin info + copy URL%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin get syntax-highlighting%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Interactive removal%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin remove%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Check for plugin updates%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin check%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Update specific plugin%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin update zsh-autosuggestions%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Update all plugins%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin update --all%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Temporarily disable a plugin%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin disable zsh-autosuggestions%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Re-enable a disabled plugin%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin enable zsh-autosuggestions%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Set load priority (lower loads first)%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin priority zsh-autosuggestions 50%s\n", get_muted(), RESET)

	// Popular plugins section
	fmt.printf("\n%s%sPOPULAR PLUGINS:%s\n", BOLD, get_secondary(), RESET)
	count := 0
	for name, info in POPULAR_PLUGINS {
		if count >= 5 {
			break
		}
		fmt.printf("  %s• %s - %s%s\n", get_muted(), name, info.description, RESET)
		count += 1
	}
	fmt.println()
}

print_plugin_add_help :: proc() {
	// Title
	fmt.printf("\n%s%swayu plugin add - Install plugin%s\n\n", BOLD, get_primary(), RESET)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu plugin add <name-or-url>")

	// Examples section
	fmt.printf("\n%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %swayu plugin add syntax-highlighting%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin add https://github.com/user/plugin.git%s\n", get_muted(), RESET)
	fmt.println()
}
