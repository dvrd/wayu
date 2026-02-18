// config_entry.odin - Generic config file management system
//
// This module provides a unified abstraction for managing configuration entries
// across different types (PATH, aliases, constants). It eliminates code duplication
// by providing generic implementations that work with any config entry type via
// the ConfigEntrySpec strategy pattern.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// ConfigEntryType defines the type of configuration entry
ConfigEntryType :: enum {
	PATH,      // PATH entries (add_to_path "...")
	ALIAS,     // Aliases (alias name="...")
	CONSTANT,  // Environment variables (export NAME="...")
}

// ConfigEntry represents a single configuration entry
ConfigEntry :: struct {
	type:    ConfigEntryType,
	name:    string,           // PATH entry, alias name, or constant name
	value:   string,           // Empty for PATH, command for alias, value for constant
	line:    string,           // Original line from config file
}

// ConfigEntrySpec defines how to work with a specific entry type (Strategy Pattern)
ConfigEntrySpec :: struct {
	type:             ConfigEntryType,
	file_name:        string,                // e.g., "path", "aliases", "constants"
	line_prefix:      string,                // e.g., "add_to_path", "alias", "export"
	display_name:     string,                // e.g., "PATH", "Alias", "Constant"
	icon:             string,                // e.g., "📂", "🔑", "💾"

	// Validation
	validator:        proc(ConfigEntry) -> ValidationResult,

	// Formatting
	format_line:      proc(ConfigEntry) -> string,
	parse_line:       proc(string) -> (ConfigEntry, bool),

	// Optional special actions
	has_clean:        bool,                  // PATH has clean action
	has_dedup:        bool,                  // PATH has dedup action
	fields_count:     int,                   // 1 for path, 2 for alias/constants

	// Form configuration
	field_labels:     []string,              // Field labels for interactive mode
	field_placeholders: []string,            // Field placeholders
	field_validators: []proc(string) -> InputValidation,
}

// Print usage error with hint to TUI mode (CLI-specific error handling)
print_cli_usage_error :: proc(spec: ^ConfigEntrySpec, action: string) {
	print_error("Missing required arguments for '%s %s'", spec.file_name, action)
	fmt.println()

	// Show usage based on action
	switch action {
	case "add":
		if spec.fields_count == 1 {
			fmt.printfln("Usage: wayu %s add <%s>", spec.file_name, spec.field_labels[0])
			fmt.println()
			fmt.printfln("Example:")
			fmt.printfln("  wayu %s add %s", spec.file_name, spec.field_placeholders[0])
		} else {
			fmt.printfln("Usage: wayu %s add <%s> <%s>",
				spec.file_name, spec.field_labels[0], spec.field_labels[1])
			fmt.println()
			fmt.printfln("Example:")
			fmt.printfln("  wayu %s add %s %s",
				spec.file_name, spec.field_placeholders[0], spec.field_placeholders[1])
		}
	case "remove":
		fmt.printfln("Usage: wayu %s rm <%s>", spec.file_name, spec.field_labels[0])
		fmt.println()
		fmt.printfln("Example:")
		fmt.printfln("  wayu %s rm %s", spec.file_name, spec.field_placeholders[0])
	}

	fmt.println()
	fmt.printfln("%sHint:%s For interactive mode, use: %swayu --tui%s",
		get_muted(), RESET, get_primary(), RESET)
}

// Generic handler - Main dispatcher for all config commands
handle_config_command :: proc(spec: ^ConfigEntrySpec, action: Action, args: []string) {
	#partial switch action {
	case .ADD:
		if len(args) == 0 {
			print_cli_usage_error(spec, "add")
			os.exit(EXIT_USAGE)
		}

		entry := parse_args_to_entry(spec, args)
		defer cleanup_entry(&entry)

		if !is_entry_complete(entry) {
			print_cli_usage_error(spec, "add")
			os.exit(EXIT_USAGE)
		}

		add_config_entry(spec, entry)
	case .REMOVE:
		if len(args) == 0 {
			print_cli_usage_error(spec, "remove")
			os.exit(EXIT_USAGE)
		}
		remove_config_entry(spec, args[0])
	case .LIST:
		// CLI defaults to static (non-interactive)
		list_config_static(spec)
	case .CLEAN:
		if !spec.has_clean {
			print_error("%s command does not support clean action", spec.display_name)
			os.exit(EXIT_GENERAL)
		}
		// Command-specific clean implementation
		// This will be called from command files (e.g., clean_missing_paths)
	case .DEDUP:
		if !spec.has_dedup {
			print_error("%s command does not support dedup action", spec.display_name)
			os.exit(EXIT_GENERAL)
		}
		// Command-specific dedup implementation
		// This will be called from command files (e.g., remove_duplicate_paths)
	case .HELP:
		print_config_help(spec)
	case .UNKNOWN:
		fmt.eprintfln("Unknown %s action", spec.display_name)
		print_config_help(spec)
		os.exit(EXIT_USAGE)
	}
}

// TUI-only: Interactive form for adding config entries
// This function is ONLY called from TUI bridge, never from CLI
add_config_interactive :: proc(spec: ^ConfigEntrySpec) {
	// TTY check
	if !os.exists("/dev/tty") {
		print_error("Interactive mode requires a TTY")
		os.exit(EXIT_CONFIG)
	}

	// Create form fields based on spec
	fields := make([]FormField, spec.fields_count)
	defer delete(fields)

	for i in 0..<spec.fields_count {
		input := new_input_with_validator(
			spec.field_placeholders[i],
			64,
			spec.field_validators[i],
		)
		validation := spec.field_validators[i]("")

		fields[i] = FormField{
			label = spec.field_labels[i],
			input = input,
			validation = validation,
			required = true,
		}
	}

	// Create and run form - use wrapper approach to avoid closures
	title := fmt.aprintf("✨ Add %s", spec.display_name)
	defer delete(title)

	// Store spec temporarily for callback access
	g_current_spec = spec
	defer g_current_spec = nil

	form := new_form(title, fields, add_preview_callback, add_submit_callback)
	defer form_destroy(&form)

	success := form_run(&form)

	if !success {
		print_info("Operation cancelled")
	}
}

// Module-level variable to pass spec to callbacks (workaround for no closure capture)
g_current_spec: ^ConfigEntrySpec = nil

// Preview callback for add operations
add_preview_callback :: proc(form: ^Form) -> string {
	spec := g_current_spec
	if spec == nil do return ""

	entry := form_to_entry(spec, form)
	defer cleanup_entry(&entry)

	if !is_entry_complete(entry) {
		return ""
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	fmt.sbprintf(&builder, "Will add %s:\n", spec.display_name)
	line := spec.format_line(entry)
	defer delete(line)
	fmt.sbprintf(&builder, "  %s%s%s\n\n", get_secondary(), line, RESET)

	// Check for duplicates
	if entry_exists(spec, entry) {
		fmt.sbprintf(&builder, "%s⚠ %s already exists (will be updated)%s\n",
			get_warning(), spec.display_name, RESET)
	}

	return strings.clone(strings.to_string(builder))
}

// Submit callback for add operations
add_submit_callback :: proc(form: ^Form) -> bool {
	spec := g_current_spec
	if spec == nil do return false

	entry := form_to_entry(spec, form)
	defer cleanup_entry(&entry)

	if !is_entry_complete(entry) {
		return false
	}

	add_config_entry(spec, entry)
	return true
}

// Generic add implementation
add_config_entry :: proc(spec: ^ConfigEntrySpec, entry: ConfigEntry) {
	// For PATH entries, expand environment variables before saving
	entry_to_save := entry
	if spec.type == .PATH {
		expanded_path := expand_env_vars(entry.name)
		entry_to_save.name = expanded_path
		// Note: expanded_path will be cleaned up at the end of this function
	}
	defer if spec.type == .PATH {
		delete(entry_to_save.name)
	}

	// Validate (using original entry for validation to allow checking $HOME etc.)
	validation_result := spec.validator(entry)
	if !validation_result.valid {
		print_error("%s", validation_result.error_message)
		delete(validation_result.error_message)
		os.exit(EXIT_DATAERR)
	}

	// Dry-run check
	if DRY_RUN {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		line := spec.format_line(entry_to_save)
		defer delete(line)

		shell_ext := DETECTED_SHELL == .ZSH ? "zsh" : "bash"
		fmt.printfln("%sWould add to %s.%s:%s", BRIGHT_CYAN, spec.file_name, shell_ext, RESET)
		fmt.printfln("  %s", line)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Get config file
	config_file := get_config_file_with_fallback(spec.file_name, DETECTED_SHELL)
	defer delete(config_file)

	// Read current content
	content, read_ok := safe_read_file(config_file)
	if !read_ok { os.exit(EXIT_IOERR) }
	defer delete(content)

	content_str := string(content)
	// Use temp allocator for the lines array since it's only needed during this function
	lines := strings.split(content_str, "\n", context.temp_allocator)
	// No need to defer delete - temp allocator manages this

	// Check if entry exists and update or append
	line_to_add := spec.format_line(entry_to_save)
	defer delete(line_to_add)

	exists := false
	for line, i in lines {
		parsed_entry, ok := spec.parse_line(line)
		if ok {
			defer cleanup_entry(&parsed_entry)
			if parsed_entry.name == entry_to_save.name {
				lines[i] = line_to_add
				exists = true
				break
			}
		}
	}

	final_content: string
	if !exists {
		// PATH entries: insert into WAYU_PATHS array before closing paren
		// Other entries: append to end of file
		if spec.type == .PATH {
			// Find closing paren of WAYU_PATHS array by searching line by line
			array_close_line_idx := -1
			found_array_start := false

			for line, i in lines {
				trimmed := strings.trim_space(line)
				// Look for array declaration
				if strings.contains(line, "WAYU_PATHS=(") {
					found_array_start = true
					continue
				}
				// After finding array start, look for closing paren on its own line
				if found_array_start && trimmed == ")" {
					array_close_line_idx = i
					break
				}
			}

			if array_close_line_idx == -1 {
				// Fallback to append if array not found (shouldn't happen with proper template)
				final_content = fmt.aprintf("%s\n%s", content_str, line_to_add)
			} else {
				// Insert new line before closing paren line
				// Allocate with heap since it will be used in strings.join()
				new_line := fmt.aprintf("%s\n)", line_to_add)
				lines[array_close_line_idx] = new_line
				final_content = strings.join(lines, "\n")
				delete(new_line)  // Free after strings.join() copies it
			}
		} else {
			// Append new entry for non-PATH types
			final_content = fmt.aprintf("%s\n%s", content_str, line_to_add)
		}
	} else {
		// Rejoin modified lines
		final_content = strings.join(lines, "\n")
	}
	defer delete(final_content)

	// Create backup
	if !create_backup_cli(config_file) {
		os.exit(EXIT_IOERR)
	}

	// Write file
	write_ok := safe_write_file(config_file, transmute([]byte)final_content)
	if !write_ok { os.exit(EXIT_IOERR) }

	// Cleanup old backups
	cleanup_old_backups(config_file, 5)

	// Success message
	if exists {
		print_success("%s updated successfully: %s", spec.display_name, entry_to_save.name)
	} else {
		print_success("%s added successfully: %s", spec.display_name, entry_to_save.name)
	}
}

// Generic remove implementation
remove_config_entry :: proc(spec: ^ConfigEntrySpec, name: string) {
	// For PATH entries, expand environment variables to support removing with $HOME, $OSS, etc.
	name_to_remove := name
	if spec.type == .PATH {
		expanded_name := expand_env_vars(name)
		name_to_remove = expanded_name
	}
	defer if spec.type == .PATH {
		delete(name_to_remove)
	}

	// Dry-run check
	if DRY_RUN {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()

		shell_ext := DETECTED_SHELL == .ZSH ? "zsh" : "bash"
		fmt.printfln("%sWould remove from %s.%s:%s", BRIGHT_CYAN, spec.file_name, shell_ext, RESET)
		fmt.printfln("  %s: %s", spec.display_name, name_to_remove)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Get config file
	config_file := get_config_file_with_fallback(spec.file_name, DETECTED_SHELL)
	defer delete(config_file)

	// Read current content
	content, read_ok := safe_read_file(config_file)
	if !read_ok { os.exit(EXIT_IOERR) }
	defer delete(content)

	content_str := string(content)
	// Use temp allocator for the lines array since it's only needed during this function
	lines := strings.split(content_str, "\n", context.temp_allocator)
	// No need to defer delete - temp allocator manages this

	// Filter out the entry
	new_lines := make([dynamic]string)
	defer {
		for line in new_lines {
			delete(line)
		}
		delete(new_lines)
	}

	removed := false
	for line in lines {
		entry, ok := spec.parse_line(line)
		if ok {
			defer cleanup_entry(&entry)
			if entry.name == name_to_remove {
				removed = true
				continue
			}
		}
		append(&new_lines, strings.clone(line))
	}

	if !removed {
		print_error_simple(fmt.aprintf("Error: %s not found: %s", spec.display_name, name_to_remove))
		os.exit(EXIT_DATAERR)
	}

	// Create backup
	if !create_backup_cli(config_file) {
		os.exit(EXIT_IOERR)
	}

	// Write back
	new_content := strings.join(new_lines[:], "\n")
	defer delete(new_content)

	write_ok := safe_write_file(config_file, transmute([]byte)new_content)
	if !write_ok { os.exit(EXIT_IOERR) }

	// Cleanup old backups
	cleanup_old_backups(config_file, 5)

	print_success("%s removed successfully: %s", spec.display_name, name_to_remove)
}

// TUI-only: Interactive fuzzy finder for removing config entries
// This function is ONLY called from TUI bridge, never from CLI
remove_config_interactive :: proc(spec: ^ConfigEntrySpec) {
	entries := read_config_entries(spec)
	defer cleanup_entries(&entries)

	if len(entries) == 0 {
		print_warning("No %ss found to remove", spec.display_name)
		return
	}

	// Convert to string list for selection
	items := make([]string, len(entries))
	defer {
		for item in items {
			delete(item)
		}
		delete(items)
	}

	for entry, i in entries {
		items[i] = strings.clone(entry.name)
	}

	prompt := fmt.aprintf("Select %s to remove:", spec.display_name)
	defer delete(prompt)
	if DRY_RUN {
		prompt_dry := fmt.aprintf("%s (DRY RUN - no changes will be made)", prompt)
		delete(prompt)
		prompt = prompt_dry
	}

	selected, ok := interactive_fuzzy_select(items, prompt)
	if !ok {
		print_info("Operation cancelled")
		return
	}

	selected_copy := strings.clone(selected)
	defer delete(selected_copy)

	remove_config_entry(spec, selected_copy)
}

// Generic static list (table view)
list_config_static :: proc(spec: ^ConfigEntrySpec) {
	// Check if wayu is initialized
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	entries := read_config_entries(spec)
	defer cleanup_entries(&entries)

	if len(entries) == 0 {
		print_info("No %ss found", spec.display_name)
		return
	}

	// Create table
	headers := make([]string, spec.fields_count)
	defer delete(headers)

	// Build headers based on entry type
	switch spec.type {
	case .PATH:
		headers[0] = "Entry"
	case .ALIAS:
		headers[0] = "Alias"
		headers[1] = "Command"
	case .CONSTANT:
		headers[0] = "Constant"
		headers[1] = "Value"
	}

	table := new_table(headers)
	defer table_destroy(&table)

	// Style the table
	table_style(&table, style_foreground(new_style(), "white"))
	table_header_style(&table, style_bold(style_foreground(new_style(), "cyan"), true))
	table_border(&table, .Normal)

	// Add rows
	for entry in entries {
		row := make([]string, spec.fields_count)
		defer delete(row)

		switch spec.type {
		case .PATH:
			row[0] = entry.name
		case .ALIAS, .CONSTANT:
			row[0] = entry.name
			row[1] = entry.value
		}

		table_add_row(&table, row)
	}

	table_output := table_render(table)
	defer delete(table_output)
	fmt.print(table_output)
}

// TUI-only: Interactive fuzzy finder view for listing config entries
// This function is ONLY called from TUI bridge, never from CLI
list_config_interactive :: proc(spec: ^ConfigEntrySpec) {
	// Check if wayu is initialized
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	entries := read_config_entries(spec)
	defer cleanup_entries(&entries)

	if len(entries) == 0 {
		print_info("No %ss found", spec.display_name)
		return
	}

	// Convert to FuzzyItems
	fuzzy_items := make([]FuzzyItem, len(entries))
	defer {
		for item in fuzzy_items {
			delete(item.display)
			delete(item.value)
			delete(item.metadata)
		}
		delete(fuzzy_items)
	}

	for entry, i in entries {
		metadata := make(map[string]string)
		metadata["name"] = strings.clone(entry.name)
		if len(entry.value) > 0 {
			metadata["value"] = strings.clone(entry.value)
		}

		fuzzy_items[i] = FuzzyItem{
			display = strings.clone(entry.name),
			value = strings.clone(entry.line),
			metadata = metadata,
			icon = spec.icon,
			color = "",
		}
	}

	// Store spec temporarily for callbacks
	g_current_spec = spec
	defer g_current_spec = nil

	// Create actions
	actions := []FuzzyAction{
		{
			name = "remove",
			key_name = "Ctrl+D",
			key_code = 4,
			handler = list_remove_action_callback,
			description = "Delete",
		},
	}

	// Create fuzzy view
	title := fmt.aprintf("%s %ss", spec.icon, spec.display_name)
	defer delete(title)

	view := new_fuzzy_view(title, fuzzy_items, list_details_callback, actions)
	defer fuzzy_view_destroy(&view)

	selected, ok := fuzzy_run(&view)
	if ok {
		print_info(fmt.tprintf("Selected: %s", selected.metadata["name"]))
	}
}

// Details callback for list operations
list_details_callback :: proc(item: ^FuzzyItem) -> string {
	spec := g_current_spec
	if spec == nil do return ""

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	name := item.metadata["name"]
	fmt.sbprintf(&builder, "%s: %s\n", spec.display_name, name)

	if value, ok := item.metadata["value"]; ok {
		fmt.sbprintf(&builder, "Value: %s\n", value)
	}

	fmt.sbprintf(&builder, "\n")
	fmt.sbprintf(&builder, "Actions:\n")
	fmt.sbprintf(&builder, "  Ctrl+D - Delete this %s\n", spec.display_name)
	fmt.sbprintf(&builder, "  Enter - Select and exit\n")

	return strings.clone(strings.to_string(builder))
}

// Action callback for removing items in list view
list_remove_action_callback :: proc(item: ^FuzzyItem) -> bool {
	spec := g_current_spec
	if spec == nil do return false

	name := item.metadata["name"]
	remove_config_entry(spec, name)
	return true  // Refresh
}

// Helper: Read all entries from config file
read_config_entries :: proc(spec: ^ConfigEntrySpec) -> []ConfigEntry {
	config_file := get_config_file_with_fallback(spec.file_name, DETECTED_SHELL)
	defer delete(config_file)

	content, read_ok := safe_read_file(config_file)
	if !read_ok { return {} }
	defer delete(content)

	content_str := string(content)
	// Use temp allocator for the lines array since it's only needed during this function
	lines := strings.split(content_str, "\n", context.temp_allocator)
	// No need to defer delete - temp allocator manages this

	entries := make([dynamic]ConfigEntry)

	for line in lines {
		entry, ok := spec.parse_line(line)
		if ok {
			append(&entries, entry)
		}
	}

	return entries[:]
}

// Helper: Check if entry exists
entry_exists :: proc(spec: ^ConfigEntrySpec, entry: ConfigEntry) -> bool {
	entries := read_config_entries(spec)
	defer cleanup_entries(&entries)

	for existing in entries {
		if existing.name == entry.name {
			return true
		}
	}

	return false
}

// Helper: Convert form to entry
form_to_entry :: proc(spec: ^ConfigEntrySpec, form: ^Form) -> ConfigEntry {
	entry := ConfigEntry{type = spec.type}

	switch spec.fields_count {
	case 1:
		entry.name = strings.clone(form.fields[0].input.value)
		entry.value = ""
	case 2:
		entry.name = strings.clone(form.fields[0].input.value)
		entry.value = strings.clone(form.fields[1].input.value)
	}

	return entry
}

// Helper: Parse command line args to entry
parse_args_to_entry :: proc(spec: ^ConfigEntrySpec, args: []string) -> ConfigEntry {
	entry := ConfigEntry{type = spec.type}

	switch spec.fields_count {
	case 1:
		if len(args) >= 1 {
			entry.name = strings.clone(args[0])
		}
		entry.value = ""
	case 2:
		if len(args) >= 2 {
			entry.name = strings.clone(args[0])
			// Join remaining args as value (for commands with spaces)
			entry.value = strings.join(args[1:], " ")
		}
	}

	return entry
}

// Helper: Check if entry is complete
is_entry_complete :: proc(entry: ConfigEntry) -> bool {
	if len(entry.name) == 0 { return false }
	// PATH only needs name, others need value too
	if entry.type != .PATH && len(entry.value) == 0 {
		return false
	}
	return true
}

// Helper: Cleanup single entry
cleanup_entry :: proc(entry: ^ConfigEntry) {
	if len(entry.name) > 0 { delete(entry.name) }
	if len(entry.value) > 0 { delete(entry.value) }
	if len(entry.line) > 0 { delete(entry.line) }
}

// Helper: Cleanup entry array
cleanup_entries :: proc(entries: ^[]ConfigEntry) {
	for &entry in entries {
		cleanup_entry(&entry)
	}
	delete(entries^)
}

// Generic help printer
print_config_help :: proc(spec: ^ConfigEntrySpec) {
	// Title
	title := fmt.aprintf("\n%s%swayu %s - Manage %ss%s\n\n",
		BOLD, get_primary(), spec.file_name, spec.display_name, RESET)
	defer delete(title)
	fmt.print(title)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)

	// Generate usage based on fields count
	if spec.fields_count == 1 {
		fmt.printfln("  wayu %s add [%s]", spec.file_name, strings.to_lower(spec.display_name))
		fmt.printfln("  wayu %s add", spec.file_name)
	} else {
		fmt.printfln("  wayu %s add <%s> <value>", spec.file_name, strings.to_lower(spec.display_name))
		fmt.printfln("  wayu %s add", spec.file_name)
	}

	fmt.printfln("  wayu %s rm [%s]", spec.file_name, strings.to_lower(spec.display_name))
	fmt.printfln("  wayu %s list", spec.file_name)

	if spec.has_clean {
		fmt.printfln("  wayu %s clean", spec.file_name)
	}
	if spec.has_dedup {
		fmt.printfln("  wayu %s dedup", spec.file_name)
	}

	fmt.printfln("  wayu %s help", spec.file_name)

	// Examples section
	fmt.println()
	fmt.printf("%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)

	if spec.fields_count == 1 {
		// PATH examples
		fmt.printfln("  wayu %s add %s", spec.file_name, spec.field_placeholders[0])
		fmt.printfln("  wayu %s list", spec.file_name)
		fmt.printfln("  wayu %s rm %s", spec.file_name, spec.field_placeholders[0])
	} else {
		// ALIAS/CONSTANT examples
		fmt.printfln("  wayu %s add %s %s", spec.file_name, spec.field_placeholders[0], spec.field_placeholders[1])
		fmt.printfln("  wayu %s list", spec.file_name)
		fmt.printfln("  wayu %s rm %s", spec.file_name, spec.field_placeholders[0])
	}

	fmt.println()
}
