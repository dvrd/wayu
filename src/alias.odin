package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// ALIAS_FILE is now defined in main.odin based on detected shell

handle_alias_command :: proc(action: Action, args: []string) {
	switch action {
	case .ADD:
		if len(args) < 2 {
			fmt.eprintln("ERROR: alias add requires two arguments: <alias> <command>")
			fmt.println("Usage: wayu alias add <alias> <command>")
			os.exit(1)
		}
		// Join remaining args as the command
		command := strings.join(args[1:], " ")
		defer delete(command)
		add_alias(args[0], command)
	case .REMOVE:
		if len(args) == 0 {
			remove_alias_interactive()
		} else {
			remove_alias(args[0])
		}
	case .LIST:
		list_aliases()
	case .RESTORE:
		// RESTORE action is handled by backup command, not alias command
		fmt.eprintln("ERROR: restore action not supported for alias command")
		fmt.println("Use: wayu backup restore alias")
		os.exit(1)
	case .HELP:
		print_alias_help()
	case .UNKNOWN:
		fmt.eprintln("Unknown alias action")
		print_alias_help()
		os.exit(1)
	}
}

add_alias :: proc(alias_name: string, command: string) {
	// Validate alias name and command
	validation_result := validate_alias(alias_name, command)
	if !validation_result.valid {
		fmt.eprintf("%s%sERROR:%s ", BOLD, ERROR, RESET)
		fmt.eprintfln("%s", validation_result.error_message)
		delete(validation_result.error_message)
		os.exit(1)
	}

	// Sanitize command value for shell safety
	sanitized_command := sanitize_shell_value(command)
	defer delete(sanitized_command)

	// Dry-run mode check
	if DRY_RUN {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould add to aliases.%s:%s", BRIGHT_CYAN, SHELL_EXT, RESET)
		fmt.printfln("  alias %s=\"%s\"", alias_name, sanitized_command)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Use shell-aware config file with fallback for backward compatibility
	config_file := get_config_file_with_fallback("aliases", DETECTED_SHELL)
	defer delete(config_file)

	// Read current file
	content, read_ok := safe_read_file(config_file)
	if !read_ok {
		os.exit(1)
	}
	defer delete(content)

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	// Check if alias already exists
	alias_prefix := fmt.aprintf("alias %s=", alias_name)
	defer delete(alias_prefix)

	alias_exists := false
	for line, i in lines {
		if strings.has_prefix(strings.trim_space(line), alias_prefix) {
			// Replace existing alias
			new_alias_line := fmt.aprintf("alias %s=\"%s\"", alias_name, sanitized_command)
			lines[i] = new_alias_line
			alias_exists = true
			break
		}
	}

	new_content: string
	if !alias_exists {
		// Add new alias at the end
		new_alias := fmt.aprintf("alias %s=\"%s\"", alias_name, sanitized_command)

		new_lines := make([]string, len(lines) + 1)
		copy(new_lines[:len(lines)], lines)
		new_lines[len(lines)] = new_alias

		new_content = strings.join(new_lines, "\n")

		defer delete(new_alias)
		defer delete(new_lines)
	} else {
		new_content = strings.join(lines, "\n")
	}
	defer delete(new_content)

	// Create backup before modifying
	if !create_backup_with_prompt(config_file) {
		print_info("Operation cancelled")
		os.exit(1)
	}

	write_ok := safe_write_file(config_file, transmute([]byte)new_content)
	if !write_ok {
		os.exit(1)
	}

	// Cleanup old backups (keep last 5)
	cleanup_old_backups(config_file, 5)

	if alias_exists {
		fmt.println("Alias updated successfully:", alias_name)
	} else {
		fmt.println("Alias added successfully:", alias_name)
	}
}

remove_alias :: proc(alias_name: string) {
	// Dry-run mode check
	if DRY_RUN {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould remove from aliases.%s:%s", BRIGHT_CYAN, SHELL_EXT, RESET)
		fmt.printfln("  alias %s", alias_name)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Use shell-aware config file with fallback for backward compatibility
	config_file := get_config_file_with_fallback("aliases", DETECTED_SHELL)
	defer delete(config_file)

	content, read_ok := safe_read_file(config_file)
	if !read_ok {
		os.exit(1)
	}
	defer delete(content)

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	// Filter out the alias
	filtered_lines := make([dynamic]string)
	defer delete(filtered_lines)

	alias_prefix := fmt.aprintf("alias %s=", alias_name)
	defer delete(alias_prefix)

	removed := false
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, alias_prefix) {
			removed = true
			continue
		}
		append(&filtered_lines, line)
	}

	if !removed {
		fmt.println("Alias not found:", alias_name)
		return
	}

	// Create backup before modifying
	if !create_backup_with_prompt(config_file) {
		print_info("Operation cancelled")
		os.exit(1)
	}

	// Write back to file
	new_content := strings.join(filtered_lines[:], "\n")
	defer delete(new_content)

	write_ok := safe_write_file(config_file, transmute([]byte)new_content)
	if !write_ok {
		os.exit(1)
	}

	// Cleanup old backups (keep last 5)
	cleanup_old_backups(config_file, 5)

	fmt.println("Alias removed successfully:", alias_name)
}

remove_alias_interactive :: proc() {
	items := extract_alias_items()
	defer {
		// Clean up the items array properly
		for item in items {
			delete(item)
		}
		delete(items)
	}

	if len(items) == 0 {
		print_warning("No aliases found to remove")
		return
	}

	prompt := "Select alias to remove:"
	if DRY_RUN {
		prompt = "Select alias to remove (DRY RUN - no changes will be made):"
	}

	selected, ok := interactive_fuzzy_select(items, prompt)
	if !ok {
		print_info("Operation cancelled")
		return
	}

	// Clone the selected item before items get cleaned up
	selected_copy := strings.clone(selected)
	defer delete(selected_copy)

	remove_alias(selected_copy)
}

list_aliases :: proc() {
	// Use shell-aware config file with fallback for backward compatibility
	config_file := get_config_file_with_fallback("aliases", DETECTED_SHELL)
	defer delete(config_file)

	content, read_ok := safe_read_file(config_file)
	if !read_ok {
		os.exit(1)
	}
	defer delete(content)

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	print_header("Current aliases:")
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "alias ") && strings.contains(trimmed, "=") {
			// Extract alias name and command
			eq_pos := strings.index(trimmed, "=")
			if eq_pos != -1 {
				name_part := trimmed[6:eq_pos] // Skip "alias "
				value_part := trimmed[eq_pos + 1:]

				// Clean up quotes
				if strings.has_prefix(value_part, "\"") && strings.has_suffix(value_part, "\"") {
					value_part = value_part[1:len(value_part) - 1]
				}

				fmt.printf("  %-20s -> %s\n", name_part, value_part)
			}
		}
	}
}

print_alias_help :: proc() {
	print_header("wayu alias - Manage shell aliases\n", EMOJI_PALM_TREE)
	print_section("USAGE:", EMOJI_USER)
	fmt.println("  wayu alias add <alias> <command>    Add or update alias")
	fmt.println("  wayu alias rm [alias]               Remove alias (interactive if no alias)")
	fmt.println("  wayu alias list                     List all aliases")
	fmt.println("  wayu alias help                     Show this help")
	fmt.println("")
	print_section("EXAMPLES:", EMOJI_CYCLIST)
	fmt.println("  wayu alias add ll 'ls -la'")
	fmt.println("  wayu alias add gc 'git commit'")
	fmt.println("  wayu alias rm ll")
	fmt.println("  wayu alias rm                       # Interactive removal")
}
