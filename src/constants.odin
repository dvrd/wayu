package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// CONSTANTS_FILE is now defined in main.odin based on detected shell

handle_constants_command :: proc(action: Action, args: []string) {
	switch action {
	case .ADD:
		if len(args) < 2 {
			fmt.eprintln("ERROR: constants add requires two arguments: <name> <value>")
			fmt.println("Usage: wayu constants add <name> <value>")
			os.exit(1)
		}
		// Join remaining args as the value
		value := strings.join(args[1:], " ")
		defer delete(value)
		add_constant(args[0], value)
	case .REMOVE:
		if len(args) == 0 {
			remove_constant_interactive()
		} else {
			remove_constant(args[0])
		}
	case .LIST:
		list_constants()
	case .RESTORE:
		// RESTORE action is handled by backup command, not constants command
		fmt.eprintln("ERROR: restore action not supported for constants command")
		fmt.println("Use: wayu backup restore constants")
		os.exit(1)
	case .CLEAN:
		fmt.eprintln("ERROR: clean action not supported for constants command")
		fmt.println("The clean action only applies to path entries")
		os.exit(1)
	case .DEDUP:
		fmt.eprintln("ERROR: dedup action not supported for constants command")
		fmt.println("The dedup action only applies to path entries")
		os.exit(1)
	case .HELP:
		print_constants_help()
	case .UNKNOWN:
		fmt.eprintln("Unknown constants action")
		print_constants_help()
		os.exit(1)
	}
}

add_constant :: proc(name: string, value: string) {
	debug("Adding constant %s = %s", name, value)

	// Validate constant name and value
	validation_result := validate_constant(name, value)
	if !validation_result.valid {
		fmt.eprintf("%s%sERROR:%s ", BOLD, ERROR, RESET)
		fmt.eprintfln("%s", validation_result.error_message)
		delete(validation_result.error_message)
		os.exit(1)
	}

	// Sanitize value for shell safety
	sanitized_value := sanitize_shell_value(value)
	defer delete(sanitized_value)

	// Dry-run mode check
	if DRY_RUN {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould add to constants.%s:%s", BRIGHT_CYAN, SHELL_EXT, RESET)
		fmt.printfln("  export %s=\"%s\"", name, sanitized_value)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Use shell-aware config file with fallback for backward compatibility
	config_file := get_config_file_with_fallback("constants", DETECTED_SHELL)
	defer delete(config_file)
	debug("Config file: %s", config_file)

	// Read current file
	debug("Reading config file...")
	content, read_ok := safe_read_file(config_file)
	if !read_ok {
		os.exit(1)
	}
	defer delete(content)
	debug("Read %d bytes", len(content))

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	// Check if constant already exists
	export_prefix := fmt.aprintf("export %s=", name)
	defer delete(export_prefix)

	constant_exists := false
	for line, i in lines {
		if strings.has_prefix(strings.trim_space(line), export_prefix) {
			// Replace existing constant
			new_const_line := fmt.aprintf("export %s=\"%s\"", name, sanitized_value)
			lines[i] = new_const_line
			constant_exists = true
			break
		}
	}

	final_content: string
	if !constant_exists {
		// Add new constant at the end - simpler approach
		new_constant := fmt.aprintf("export %s=\"%s\"", name, sanitized_value)
		defer delete(new_constant)

		// Simply append to the content string directly
		final_content = fmt.aprintf("%s\n%s", content_str, new_constant)
	} else {
		// If we updated an existing constant, rejoin the lines
		final_content = strings.join(lines, "\n")
	}
	defer delete(final_content)

	// Create backup before modifying
	if !create_backup_with_prompt(config_file) {
		print_info("Operation cancelled")
		os.exit(1)
	}

	write_ok := safe_write_file(config_file, transmute([]byte)final_content)
	if !write_ok {
		os.exit(1)
	}

	// Cleanup old backups (keep last 5)
	cleanup_old_backups(config_file, 5)

	if constant_exists {
		print_success("Constant updated successfully: %s", name)
	} else {
		print_success("Constant added successfully: %s", name)
	}
}

remove_constant :: proc(name: string) {
	debug("Removing constant: %s", name)

	// Dry-run mode check
	if DRY_RUN {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould remove from constants.%s:%s", BRIGHT_CYAN, SHELL_EXT, RESET)
		fmt.printfln("  export %s", name)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Use shell-aware config file with fallback for backward compatibility
	config_file := get_config_file_with_fallback("constants", DETECTED_SHELL)
	defer delete(config_file)

	content, read_ok := safe_read_file(config_file)
	if !read_ok {
		os.exit(1)
	}
	defer delete(content)
	debug("Read %d bytes", len(content))

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)
	debug("Split into %d lines", len(lines))

	// Build new content without the target constant - safer approach
	export_prefix := fmt.aprintf("export %s=", name)
	defer delete(export_prefix)
	debug("Looking for prefix: %s", export_prefix)

	new_lines := make([dynamic]string)
	defer {
		for line in new_lines {
			delete(line)
		}
		delete(new_lines)
	}

	removed := false
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, export_prefix) {
			debug("Found constant to remove at line: %s", line)
			removed = true
			continue
		}
		append(&new_lines, strings.clone(line))
	}
	debug("Removed: %t", removed)

	if !removed {
		print_warning("Constant not found: %s", name)
		return
	}

	// Create backup before modifying
	if !create_backup_with_prompt(config_file) {
		print_info("Operation cancelled")
		os.exit(1)
	}

	// Write back to file - use simple string join
	new_content := strings.join(new_lines[:], "\n")
	defer delete(new_content)
	debug("Created new content with %d characters", len(new_content))

	write_ok := safe_write_file(config_file, transmute([]byte)new_content)
	if !write_ok {
		os.exit(1)
	}
	debug("File written successfully")

	// Cleanup old backups (keep last 5)
	cleanup_old_backups(config_file, 5)

	print_success("Constant removed successfully: %s", name)
}

remove_constant_interactive :: proc() {
	debug("Starting interactive constant removal")
	items := extract_constant_items()
	defer delete(items) // Only clean up the array, not the strings (they're managed by extract_constant_items)
	debug("Extracted %d constant items", len(items))

	if len(items) == 0 {
		print_warning("No constants found to remove")
		return
	}

	prompt := "Select constant to remove:"
	if DRY_RUN {
		prompt = "Select constant to remove (DRY RUN - no changes will be made):"
	}

	debug("Calling interactive_fuzzy_select")
	selected, ok := interactive_fuzzy_select(items, prompt)
	defer delete(selected) // Clean up the cloned string from interactive_select
	debug("Interactive selection result: ok=%t, selected='%s'", ok, selected)
	if !ok {
		print_info("Operation cancelled")
		return
	}

	debug("About to call remove_constant with: %s", selected)
	remove_constant(selected)
	debug("remove_constant completed successfully")
}

list_constants :: proc() {
	// Check if wayu is initialized first
	if !check_wayu_initialized() {
		os.exit(1)
	}

	// Use shell-aware config file with fallback for backward compatibility
	config_file := get_config_file_with_fallback("constants", DETECTED_SHELL)
	defer delete(config_file)

	content, read_ok := safe_read_file(config_file)
	if !read_ok {
		os.exit(1)
	}
	defer delete(content)

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	// Extract constants for table display
	constants := make([dynamic][2]string)
	defer {
		for const_pair in constants {
			delete(const_pair[0])
			delete(const_pair[1])
		}
		delete(constants)
	}

	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "export ") && strings.contains(trimmed, "=") {
			// Extract constant name and value
			eq_pos := strings.index(trimmed, "=")
			if eq_pos != -1 {
				name_part := trimmed[7:eq_pos] // Skip "export "
				value_part := trimmed[eq_pos + 1:]

				// Clean up quotes
				if strings.has_prefix(value_part, "\"") && strings.has_suffix(value_part, "\"") {
					value_part = value_part[1:len(value_part) - 1]
				}

				const_pair := [2]string{strings.clone(name_part), strings.clone(value_part)}
				append(&constants, const_pair)
			}
		}
	}

	if len(constants) == 0 {
		print_info("No constants found")
		return
	}

	// Create and configure table
	headers := []string{"Constant", "Value"}
	table := new_table(headers)
	defer table_destroy(&table)

	// Style the table
	table_style(&table, style_foreground(new_style(), "white"))
	table_header_style(&table, style_bold(style_foreground(new_style(), "cyan"), true))
	table_border(&table, .Normal)

	// Add rows to table
	for const_pair in constants {
		row := []string{const_pair[0], const_pair[1]}
		table_add_row(&table, row)
	}

	// Print header and render table
	print_header("Environment Constants", "📋")
	fmt.println()
	table_output := table_render(table)
	defer delete(table_output)
	fmt.print(table_output)
}

print_constants_help :: proc() {
	fmt.println("wayu constants - Manage environment constants")
	fmt.println("")
	fmt.println("USAGE:")
	fmt.println("  wayu constants add <name> <value>    Add or update constant")
	fmt.println("  wayu constants rm [name]             Remove constant (interactive if no name)")
	fmt.println("  wayu constants list                  List all constants")
	fmt.println("  wayu constants help                  Show this help")
	fmt.println("")
	fmt.println("EXAMPLES:")
	fmt.println("  wayu constants add MY_PROJECT_PATH /path/to/project")
	fmt.println("  wayu constants add API_URL https://api.example.com")
	fmt.println("  wayu constants rm MY_PROJECT_PATH")
	fmt.println("  wayu constants rm                    # Interactive removal")
}