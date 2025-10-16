package wayu

import "core:fmt"
import "core:os"
import "core:strings"
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

	// Read current configuration
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

	// Generate source statements for enabled plugins
	for plugin in config.plugins {
		// Skip if disabled
		if !plugin.enabled {
			continue
		}

		// Skip if shell incompatible
		if plugin.shell == .ZSH && shell == .BASH {
			continue
		}
		if plugin.shell == .BASH && shell == .ZSH {
			continue
		}

		// Detect plugin entry file
		entry_file, found := detect_plugin_file(plugin.installed_path, plugin.name, shell)

		if found {
			// Single file to source
			comment := fmt.aprintf("# %s\n", plugin.name)
			strings.write_string(&sb, comment)
			delete(comment)

			source_line := fmt.aprintf("if [ -f %s ]; then\n    source %s\nfi\n\n",
				entry_file, entry_file)
			strings.write_string(&sb, source_line)
			delete(source_line)
		} else {
			// Source all .{zsh,bash} files in directory
			comment := fmt.aprintf("# %s (all .%s files)\n", plugin.name, ext)
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

	// Check if already installed
	if is_plugin_installed(&config, info.name) {
		print_warning("Plugin '%s' is already installed", info.name)
		os.exit(0)
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
	new_plugin := InstalledPlugin{
		name = strings.clone(info.name),
		url = strings.clone(info.url),
		enabled = true,
		shell = info.shell,
		installed_path = strings.clone(plugin_path),
	}

	append(&config.plugins, new_plugin)

	// Create backup before writing
	if !DRY_RUN {
		config_file := get_plugins_config_file()
		defer delete(config_file)

		if os.exists(config_file) {
			backup_path, backup_ok := create_backup(config_file)
			if backup_ok {
				defer delete(backup_path)
			}
		}
	}

	// Write config
	if !write_plugin_config(&config) {
		print_error_simple("Error: Failed to write plugin configuration")
		os.exit(1)
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
		table := new_table([]string{"Name", "Status", "Shell", "URL"})
		defer delete(table.rows)

		for plugin in config.plugins {
			status := plugin.enabled ? "✓ Active" : "○ Disabled"
			shell_str := shell_compat_to_string(plugin.shell)

			// Truncate URL for display
			url_display := plugin.url
			if len(url_display) > 40 {
				url_display = fmt.aprintf("%s...", plugin.url[:37])
			}

			row := []string{plugin.name, status, shell_str, url_display}
			table_add_row(&table, row)

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

		// Create table
		table := new_table([]string{"Name", "Status", "Shell", "URL"})
		defer delete(table.rows)

		for plugin in config.plugins {
			status := plugin.enabled ? "✓ Active" : "○ Disabled"
			shell_str := shell_compat_to_string(plugin.shell)

			// Truncate URL for display
			url_display := plugin.url
			if len(url_display) > 40 {
				url_display = fmt.aprintf("%s...", plugin.url[:37])
			}

			row := []string{plugin.name, status, shell_str, url_display}
			table_add_row(&table, row)

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
	plugin_ptr, found := find_plugin(&config, plugin_name)
	if !found {
		print_error_simple("Error: Plugin '%s' not found", plugin_name)
		os.exit(1)
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
			os.exit(1)
		}
	}

	print_success("Removed plugin directory")

	// Remove from config
	new_plugins := make([dynamic]InstalledPlugin)
	defer delete(new_plugins)

	for plugin in config.plugins {
		if plugin.name != plugin_name {
			append(&new_plugins, plugin)
		} else {
			// Clean up memory for removed plugin
			delete(plugin.name)
			delete(plugin.url)
			delete(plugin.installed_path)
			delete(plugin.entry_file)
		}
	}

	config.plugins = new_plugins

	// Create backup before writing
	if !DRY_RUN {
		config_file := get_plugins_config_file()
		defer delete(config_file)

		if os.exists(config_file) {
			backup_path, backup_ok := create_backup(config_file)
			if backup_ok {
				defer delete(backup_path)
			}
		}
	}

	// Write config
	if !write_plugin_config(&config) {
		print_error_simple("Error: Failed to write plugin configuration")
		os.exit(1)
	}

	// Generate plugins file
	if !generate_plugins_file(DETECTED_SHELL) {
		print_error_simple("Error: Failed to generate plugins loader")
		os.exit(1)
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
	fmt.println("  get <name>              Show plugin info and copy URL to clipboard")
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
