package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// ALIAS_FILE is now defined in main.odin based on detected shell

handle_alias_command :: proc(action: Action, args: []string) {
	switch action {
	case .ADD:
		if len(args) == 0 {
			// Interactive TUI mode when no arguments provided
			add_alias_interactive()
		} else if len(args) < 2 {
			fmt.eprintln("ERROR: alias add requires two arguments: <alias> <command>")
			fmt.println("Usage: wayu alias add <alias> <command>")
			fmt.println("Or run without arguments for interactive mode: wayu alias add")
			os.exit(1)
		} else {
			// CLI mode with provided arguments (backward compatible)
			command := strings.join(args[1:], " ")
			defer delete(command)
			add_alias(args[0], command)
		}
	case .REMOVE:
		if len(args) == 0 {
			remove_alias_interactive()
		} else {
			remove_alias(args[0])
		}
	case .LIST:
		list_aliases()
	case .GET:
		fmt.eprintln("ERROR: get action not supported for alias command")
		fmt.println("The get action only applies to plugins")
		os.exit(1)
	case .RESTORE:
		// RESTORE action is handled by backup command, not alias command
		fmt.eprintln("ERROR: restore action not supported for alias command")
		fmt.println("Use: wayu backup restore alias")
		os.exit(1)
	case .CLEAN:
		fmt.eprintln("ERROR: clean action not supported for alias command")
		fmt.println("The clean action only applies to path entries")
		os.exit(1)
	case .DEDUP:
		fmt.eprintln("ERROR: dedup action not supported for alias command")
		fmt.println("The dedup action only applies to path entries")
		os.exit(1)
	case .HELP:
		print_alias_help()
	case .UNKNOWN:
		fmt.eprintln("Unknown alias action")
		print_alias_help()
		os.exit(1)
	}
}

// Interactive TUI mode for adding aliases
add_alias_interactive :: proc() {
	// Check TTY - if not interactive terminal, show error
	if !os.exists("/dev/tty") {
		fmt.eprintln("ERROR: Interactive mode requires a TTY")
		fmt.println("Use: wayu alias add <alias> <command>")
		os.exit(1)
	}

	// Create form fields with validators
	alias_input := new_input_with_validator("e.g., ll, gc, gst", 64, validate_alias_name_for_form)
	command_input := new_input_with_validator("e.g., ls -la, git commit", 64, validate_alias_command_for_form)

	// Run initial validation with empty values
	alias_validation := validate_alias_name_for_form("")
	command_validation := validate_alias_command_for_form("")

	fields := []FormField{
		{
			label = "✏️  Enter alias name:",
			input = alias_input,
			validation = alias_validation,
			required = true,
		},
		{
			label = "⌨️  Enter command:",
			input = command_input,
			validation = command_validation,
			required = true,
		},
	}

	// Create preview function
	preview_fn := proc(form: ^Form) -> string {
		alias_name := form.fields[0].input.value
		command_value := form.fields[1].input.value

		if len(alias_name) == 0 || len(command_value) == 0 {
			return ""
		}

		// Generate preview
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)

		fmt.sbprintf(&builder, "Will add alias:\n")
		fmt.sbprintf(&builder, "  %salias %s=\"%s\"%s\n\n",
			get_secondary(), alias_name, command_value, RESET)

		// Check if alias already exists
		items := extract_alias_items()
		defer {
			for item in items {
				delete(item)
			}
			delete(items)
		}

		for item in items {
			search_str := fmt.aprintf("%s=", alias_name)
			defer delete(search_str)
			if strings.contains(item, search_str) {
				fmt.sbprintf(&builder, "%s⚠ Alias already exists (will be updated)%s\n",
					get_warning(), RESET)
				break
			}
		}

		return strings.clone(strings.to_string(builder))
	}

	// Create submit function
	submit_fn := proc(form: ^Form) -> bool {
		alias_name := form.fields[0].input.value
		command_value := form.fields[1].input.value

		if len(alias_name) == 0 || len(command_value) == 0 {
			return false
		}

		// Add the alias using existing logic
		add_alias(alias_name, command_value)
		return true
	}

	// Create and run form
	form := new_form(
		"✨ Add Shell Alias",
		fields,
		preview_fn,
		submit_fn,
	)
	// Clean up form resources
	defer form_destroy(&form)

	success := form_run(&form)

	if success {
		// Success message already printed by add_alias
	} else {
		print_info("Operation cancelled")
	}
}

// Validator for alias name in forms
validate_alias_name_for_form :: proc(name: string) -> InputValidation {
	if len(strings.trim_space(name)) == 0 {
		return InputValidation{
			valid = false,
			error_message = strings.clone("Alias name cannot be empty"),
			warning = "",
			info = "",
		}
	}

	// Use existing validation
	base_validation := validate_identifier(name, "Alias")

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

// Validator for alias command in forms
validate_alias_command_for_form :: proc(command: string) -> InputValidation {
	if len(strings.trim_space(command)) == 0 {
		return InputValidation{
			valid = false,
			error_message = strings.clone("Command cannot be empty"),
			warning = "",
			info = "",
		}
	}

	return InputValidation{
		valid = true,
		error_message = "",
		warning = "",
		info = strings.clone("Press Enter to add this alias"),
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
	// Check if wayu is initialized first
	if !check_wayu_initialized() {
		os.exit(1)
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

	// Extract aliases for table display
	aliases := make([dynamic][2]string)
	defer {
		for alias_pair in aliases {
			delete(alias_pair[0])
			delete(alias_pair[1])
		}
		delete(aliases)
	}

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

				alias_pair := [2]string{strings.clone(name_part), strings.clone(value_part)}
				append(&aliases, alias_pair)
			}
		}
	}

	if len(aliases) == 0 {
		print_info("No aliases found")
		return
	}

	// Create and configure table
	headers := []string{"Alias", "Command"}
	table := new_table(headers)
	defer table_destroy(&table)

	// Style the table
	table_style(&table, style_foreground(new_style(), "white"))
	table_header_style(&table, style_bold(style_foreground(new_style(), "cyan"), true))
	table_border(&table, .Normal)

	// Add rows to table
	for alias_pair in aliases {
		row := []string{alias_pair[0], alias_pair[1]}
		table_add_row(&table, row)
	}

	table_output := table_render(table)
	defer delete(table_output)
	fmt.print(table_output)
}

print_alias_help :: proc() {
	// Title
	fmt.printf("\n%s%swayu alias - Manage shell aliases%s\n\n", BOLD, get_primary(), RESET)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu alias add <alias> <command>    Add or update alias")
	fmt.println("  wayu alias add                      Interactive mode (no args)")
	fmt.println("  wayu alias rm [alias]               Remove alias (interactive if no alias)")
	fmt.println("  wayu alias list                     List all aliases")
	fmt.println("  wayu alias help                     Show this help")

	// Examples section
	fmt.printf("\n%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %swayu alias add ll 'ls -la'%s\n", get_muted(), RESET)
	fmt.printf("  %swayu alias add gc 'git commit'%s\n", get_muted(), RESET)
	fmt.printf("  %swayu alias add                      # Interactive TUI mode%s\n", get_muted(), RESET)
	fmt.printf("  %swayu alias rm ll%s\n", get_muted(), RESET)
	fmt.printf("  %swayu alias rm                       # Interactive removal%s\n", get_muted(), RESET)
	fmt.println()
}
