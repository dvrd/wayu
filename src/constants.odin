package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// CONSTANTS_FILE is now defined in main.odin based on detected shell

handle_constants_command :: proc(action: Action, args: []string) {
	switch action {
	case .ADD:
		if len(args) == 0 {
			// Interactive TUI mode when no arguments provided
			add_constant_interactive()
		} else if len(args) < 2 {
			fmt.eprintln("ERROR: constants add requires two arguments: <name> <value>")
			fmt.println("Usage: wayu constants add <name> <value>")
			fmt.println("Or run without arguments for interactive mode: wayu constants add")
			os.exit(1)
		} else {
			// CLI mode with provided arguments (backward compatible)
			value := strings.join(args[1:], " ")
			defer delete(value)
			add_constant(args[0], value)
		}
	case .REMOVE:
		if len(args) == 0 {
			remove_constant_interactive()
		} else {
			remove_constant(args[0])
		}
	case .LIST:
		if len(args) > 0 && args[0] == "--static" {
			// Static table mode (for scripts/automation)
			list_constants_static()
		} else {
			// Interactive fuzzy finder mode (default)
			list_constants_interactive()
		}
	case .GET:
		fmt.eprintln("ERROR: get action not supported for constants command")
		fmt.println("The get action only applies to plugins")
		os.exit(1)
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

// Interactive TUI mode for adding constants
add_constant_interactive :: proc() {
	// Check TTY - if not interactive terminal, show error
	if !os.exists("/dev/tty") {
		fmt.eprintln("ERROR: Interactive mode requires a TTY")
		fmt.println("Use: wayu constants add <name> <value>")
		os.exit(1)
	}

	// Create form fields with validators
	name_input := new_input_with_validator("e.g., MY_VAR, API_URL", 64, validate_constant_name_for_form)
	value_input := new_input_with_validator("e.g., /path/to/something, https://api.example.com", 64, validate_constant_value_for_form)

	// Run initial validation with empty values
	name_validation := validate_constant_name_for_form("")
	value_validation := validate_constant_value_for_form("")

	fields := []FormField{
		{
			label = "📝 Enter constant name:",
			input = name_input,
			validation = name_validation,
			required = true,
		},
		{
			label = "💾 Enter value:",
			input = value_input,
			validation = value_validation,
			required = true,
		},
	}

	// Create preview function
	preview_fn := proc(form: ^Form) -> string {
		const_name := form.fields[0].input.value
		const_value := form.fields[1].input.value

		if len(const_name) == 0 || len(const_value) == 0 {
			return ""
		}

		// Generate preview
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)

		fmt.sbprintf(&builder, "Will add constant:\n")
		fmt.sbprintf(&builder, "  %sexport %s=\"%s\"%s\n\n",
			get_secondary(), const_name, const_value, RESET)

		// Check if constant already exists
		items := extract_constant_items()
		defer {
			for item in items {
				delete(item)
			}
			delete(items)
		}

		for item in items {
			// Check if constant already exists by checking prefix
			const_check := fmt.aprintf("export %s=", const_name)
			defer delete(const_check)
			if strings.has_prefix(item, const_check) {
				fmt.sbprintf(&builder, "%s⚠ Constant already exists (will be updated)%s\n",
					get_warning(), RESET)
				break
			}
		}

		return strings.clone(strings.to_string(builder))
	}

	// Create submit function
	submit_fn := proc(form: ^Form) -> bool {
		const_name := form.fields[0].input.value
		const_value := form.fields[1].input.value

		if len(const_name) == 0 || len(const_value) == 0 {
			return false
		}

		// Add the constant using existing logic
		add_constant(const_name, const_value)
		return true
	}

	// Create and run form
	form := new_form(
		"✨ Add Environment Constant",
		fields,
		preview_fn,
		submit_fn,
	)
	// Clean up form resources
	defer form_destroy(&form)

	success := form_run(&form)

	if success {
		// Success message already printed by add_constant
	} else {
		print_info("Operation cancelled")
	}
}

// Validator for constant name in forms
validate_constant_name_for_form :: proc(name: string) -> InputValidation {
	if len(strings.trim_space(name)) == 0 {
		return InputValidation{
			valid = false,
			error_message = strings.clone("Constant name cannot be empty"),
			warning = "",
			info = "",
		}
	}

	// Use existing validation
	base_validation := validate_identifier(name, "Constant")

	if !base_validation.valid {
		return InputValidation{
			valid = false,
			error_message = strings.clone(base_validation.error_message),
			warning = "",
			info = "",
		}
	}

	return InputValidation{
		valid = true,
		error_message = "",
		warning = "",
		info = strings.clone("Press Tab to move to next field"),
	}
}

// Validator for constant value in forms
validate_constant_value_for_form :: proc(value: string) -> InputValidation {
	if len(strings.trim_space(value)) == 0 {
		return InputValidation{
			valid = false,
			error_message = strings.clone("Value cannot be empty"),
			warning = "",
			info = "",
		}
	}

	return InputValidation{
		valid = true,
		error_message = "",
		warning = "",
		info = strings.clone("Press Enter to add this constant"),
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

list_constants_static :: proc() {
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

	table_output := table_render(table)
	defer delete(table_output)
	fmt.print(table_output)
}

list_constants_interactive :: proc() {
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

	// Parse constants and create FuzzyItem structures
	items := make([dynamic]FuzzyItem)
	defer {
		for item in items {
			delete(item.display)
			delete(item.value)
			delete(item.metadata)
		}
		delete(items)
	}

	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "export ") && strings.contains(trimmed, "=") {
			// Extract constant name and value
			eq_pos := strings.index(trimmed, "=")
			if eq_pos != -1 {
				name := trimmed[7:eq_pos] // Skip "export "
				value_part := trimmed[eq_pos + 1:]

				// Clean up quotes
				if strings.has_prefix(value_part, "\"") && strings.has_suffix(value_part, "\"") {
					value_part = value_part[1:len(value_part) - 1]
				}

				// Create metadata
				metadata := make(map[string]string)
				metadata["name"] = strings.clone(name)
				metadata["value"] = strings.clone(value_part)
				metadata["length"] = fmt.aprintf("%d chars", len(value_part))
				metadata["type"] = determine_constant_type(value_part)

				// Determine icon based on value type
				icon := "💾"
				if strings.has_prefix(value_part, "/") || strings.has_prefix(value_part, "~") {
					icon = "📂" // Path
				} else if strings.has_prefix(value_part, "http://") || strings.has_prefix(value_part, "https://") {
					icon = "🌐" // URL
				} else if is_numeric(value_part) {
					icon = "🔢" // Number
				}

				item := FuzzyItem{
					display = strings.clone(name),
					value = strings.clone(trimmed),
					metadata = metadata,
					icon = icon,
					color = "",
				}
				append(&items, item)
			}
		}
	}

	if len(items) == 0 {
		print_info("No constants found")
		return
	}

	// Create details function
	details_fn := proc(item: ^FuzzyItem) -> string {
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)

		name := item.metadata["name"]
		value := item.metadata["value"]
		length := item.metadata["length"]
		type := item.metadata["type"]

		fmt.sbprintf(&builder, "Constant: %s\n", name)
		fmt.sbprintf(&builder, "Value: %s\n", value)
		fmt.sbprintf(&builder, "\n")
		fmt.sbprintf(&builder, "Type: %s\n", type)
		fmt.sbprintf(&builder, "Length: %s\n", length)
		fmt.sbprintf(&builder, "\n")
		fmt.sbprintf(&builder, "Actions:\n")
		fmt.sbprintf(&builder, "  Enter - Select to view\n")

		return strings.clone(strings.to_string(builder))
	}

	// Create actions (disabled for now)
	actions := []FuzzyAction{}

	// Create and run fuzzy view
	view := new_fuzzy_view("💾 Environment Constants", items[:], details_fn, actions)
	defer fuzzy_view_destroy(&view)

	selected, ok := fuzzy_run(&view)
	if ok {
		// User selected a constant - just show info
		print_info(fmt.tprintf("Selected: %s = %s", selected.metadata["name"], selected.metadata["value"]))
	}
}

// Helper function to determine constant type
determine_constant_type :: proc(value: string) -> string {
	if strings.has_prefix(value, "/") || strings.has_prefix(value, "~") {
		return "Path"
	} else if strings.has_prefix(value, "http://") || strings.has_prefix(value, "https://") {
		return "URL"
	} else if is_numeric(value) {
		return "Number"
	} else if value == "true" || value == "false" {
		return "Boolean"
	}
	return "String"
}

// Helper function to check if a string is numeric
is_numeric :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for c in s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

print_constants_help :: proc() {
	// Title
	fmt.printf("\n%s%swayu constants - Manage environment constants%s\n\n", BOLD, get_primary(), RESET)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu constants add <name> <value>    Add or update constant")
	fmt.println("  wayu constants add                   Interactive mode (no args)")
	fmt.println("  wayu constants rm [name]             Remove constant (interactive if no name)")
	fmt.println("  wayu constants list                  List all constants")
	fmt.println("  wayu constants help                  Show this help")

	// Examples section
	fmt.printf("\n%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %swayu constants add MY_PROJECT_PATH /path/to/project%s\n", get_muted(), RESET)
	fmt.printf("  %swayu constants add API_URL https://api.example.com%s\n", get_muted(), RESET)
	fmt.printf("  %swayu constants add                  # Interactive TUI mode%s\n", get_muted(), RESET)
	fmt.printf("  %swayu constants rm MY_PROJECT_PATH%s\n", get_muted(), RESET)
	fmt.printf("  %swayu constants rm                   # Interactive removal%s\n", get_muted(), RESET)
	fmt.println()
}
