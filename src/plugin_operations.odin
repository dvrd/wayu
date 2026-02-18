package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:c/libc"

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

// Shared implementation for enable/disable plugin commands
// Sets enabled state in plugins.json and regenerates shell loader
// Idempotent: Setting a plugin to its current state returns EXIT_SUCCESS
handle_plugin_set_enabled :: proc(args: []string, enable: bool) {
	// Determine action-specific strings
	action_word: string = "disable"
	if enable { action_word = "enable" }
	action_word_cap: string = "Disable"
	if enable { action_word_cap = "Enable" }
	action_ing: string = "Disabling"
	if enable { action_ing = "Enabling" }
	action_past: string = "disabled"
	if enable { action_past = "enabled" }
	header_text: string = "Disabling Plugin"
	if enable { header_text = "Enabling Plugin" }

	// 1. Validate arguments
	if len(args) == 0 {
		print_error("Missing required argument: plugin name")
		fmt.println()
		fmt.printfln("Usage: wayu plugin %s <name>", action_word)
		fmt.println()
		fmt.println("Example:")
		fmt.printfln("  wayu plugin %s zsh-autosuggestions", action_word)
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

	// 4. Check if already in target state (idempotent operation)
	if plugin_ptr.enabled == enable {
		cleanup_plugin_config_json(&config)
		print_info("Plugin '%s' is already %s", plugin_name, action_past)
		os.exit(EXIT_SUCCESS)  // NOT an error - idempotent
	}

	// Display header
	print_header(header_text, EMOJI_COMMAND)
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

	// 6. Set plugin enabled state
	plugin_ptr.enabled = enable

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
	print_success("Plugin '%s' %s successfully", plugin_name, action_past)
	fmt.println()

	if enable {
		fmt.printfln("%sThe plugin will be loaded in new shell sessions.%s", BRIGHT_CYAN, RESET)
	} else {
		fmt.printfln("%sThe plugin will not be loaded in new shell sessions.%s", BRIGHT_CYAN, RESET)
	}
	fmt.printfln("Restart your shell or run 'source ~/.%src' to apply changes.", SHELL_EXT)

	if !enable {
		fmt.println()
		fmt.printfln("%sTo re-enable:%s wayu plugin enable %s", get_muted(), RESET, plugin_name)
	}

	os.exit(EXIT_SUCCESS)
}

// Handle plugin enable command - enable a disabled plugin
// Sets enabled: true in plugins.json and regenerates shell loader
// CLI-only command (no interactive mode)
// Idempotent: Enabling an already-enabled plugin returns EXIT_SUCCESS
handle_plugin_enable :: proc(args: []string) {
	handle_plugin_set_enabled(args, true)
}

// Handle plugin disable command - disable an enabled plugin
// Sets enabled: false in plugins.json and regenerates shell loader
// CLI-only command (no interactive mode)
// Plugin remains installed, only prevents loading on shell startup
// Idempotent: Disabling an already-disabled plugin returns EXIT_SUCCESS
handle_plugin_disable :: proc(args: []string) {
	handle_plugin_set_enabled(args, false)
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
		// Validate path against shell injection before rm -rf
		if !is_safe_shell_arg(plugin_ptr.installed_path) {
			print_error_simple("Error: Plugin path contains unsafe characters")
			os.exit(EXIT_DATAERR)
		}

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
	if !DRY_RUN && is_safe_shell_arg(plugin_ptr.url) {
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

