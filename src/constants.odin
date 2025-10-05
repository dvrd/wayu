package wayu

import "core:fmt"
import "core:os"
import "core:strings"

CONSTANTS_FILE :: "constants.zsh"

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
	config_file := fmt.aprintf("%s/%s", WAYU_CONFIG, CONSTANTS_FILE)
	defer delete(config_file)
	debug("Config file: %s", config_file)

	// Read current file
	debug("Reading config file...")
	content, read_ok := os.read_entire_file_from_filename(config_file)
	if !read_ok {
		print_error("Could not read config file '%s'", config_file)
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
			new_const_line := fmt.aprintf("export %s=\"%s\"", name, value)
			lines[i] = new_const_line
			constant_exists = true
			break
		}
	}

	final_content: string
	if !constant_exists {
		// Add new constant at the end - simpler approach
		new_constant := fmt.aprintf("export %s=\"%s\"", name, value)
		defer delete(new_constant)

		// Simply append to the content string directly
		final_content = fmt.aprintf("%s\n%s", content_str, new_constant)
	} else {
		// If we updated an existing constant, rejoin the lines
		final_content = strings.join(lines, "\n")
	}
	defer delete(final_content)

	write_ok := os.write_entire_file(config_file, transmute([]byte)final_content)
	if !write_ok {
		print_error("Could not write to config file")
		os.exit(1)
	}

	if constant_exists {
		print_success("Constant updated successfully: %s", name)
	} else {
		print_success("Constant added successfully: %s", name)
	}
}

remove_constant :: proc(name: string) {
	debug("Removing constant: %s", name)
	config_file := fmt.aprintf("%s/%s", WAYU_CONFIG, CONSTANTS_FILE)
	defer delete(config_file)

	content, read_ok := os.read_entire_file_from_filename(config_file)
	if !read_ok {
		print_error("Could not read config file")
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

	// Write back to file - use simple string join
	new_content := strings.join(new_lines[:], "\n")
	defer delete(new_content)
	debug("Created new content with %d characters", len(new_content))

	write_ok := os.write_entire_file(config_file, transmute([]byte)new_content)
	if !write_ok {
		print_error("Could not write to config file")
		os.exit(1)
	}
	debug("File written successfully")

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

	debug("Calling interactive_fuzzy_select")
	selected, ok := interactive_fuzzy_select(items, "Select constant to remove:")
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
	config_file := fmt.aprintf("%s/%s", WAYU_CONFIG, CONSTANTS_FILE)
	defer delete(config_file)

	content, read_ok := os.read_entire_file_from_filename(config_file)
	if !read_ok {
		fmt.eprintfln("ERROR: Could not read config file")
		os.exit(1)
	}
	defer delete(content)

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	fmt.printf("%s%s📋  Current constants:%s\n", PRIMARY, BOLD, RESET)
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

				fmt.printf("  %-20s -> %s\n", name_part, value_part)
			}
		}
	}
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