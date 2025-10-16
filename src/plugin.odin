package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"
import "core:time"
import "core:c/libc"

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

// Get plugins config file path
get_plugins_config_file :: proc() -> string {
	return fmt.aprintf("%s/plugins.conf", WAYU_CONFIG)
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
