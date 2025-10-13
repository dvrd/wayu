package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"

// PATH_FILE is now defined in main.odin based on detected shell

handle_path_command :: proc(action: Action, args: []string) {
	switch action {
	case .ADD:
		if len(args) == 0 {
			// Interactive TUI mode when no arguments provided
			add_path_interactive()
		} else {
			// CLI mode with provided argument (backward compatible)
			add_path(args[0])
		}
	case .REMOVE:
		if len(args) == 0 {
			remove_path_interactive()
		} else {
			remove_path(args[0])
		}
	case .LIST:
		if len(args) > 0 && args[0] == "--static" {
			// Static table mode (for scripts/automation)
			list_paths_static()
		} else {
			// Interactive fuzzy finder mode (default)
			list_paths_interactive()
		}
	case .GET:
		fmt.eprintln("ERROR: get action not supported for path command")
		fmt.println("The get action only applies to plugins")
		os.exit(1)
	case .CLEAN:
		clean_missing_paths()
	case .DEDUP:
		remove_duplicate_paths()
	case .RESTORE:
		// RESTORE action is handled by backup command, not path command
		fmt.eprintln("ERROR: restore action not supported for path command")
		fmt.println("Use: wayu backup restore path")
		os.exit(1)
	case .HELP:
		print_path_help()
	case .UNKNOWN:
		fmt.eprintln("Unknown path action")
		print_path_help()
		os.exit(1)
	}
}

// Interactive TUI mode for adding paths
add_path_interactive :: proc() {
	// Check TTY - if not interactive terminal, fall back to PWD
	if !os.exists("/dev/tty") {
		cwd := os.get_current_directory()
		defer delete(cwd)
		add_path(cwd)
		return
	}

	// Create form field with path validator
	input_field := new_input_with_validator("e.g., /usr/local/bin or $HOME/bin", 64, validate_path_for_form)

	// Run initial validation with empty value
	initial_validation := validate_path_for_form("")

	fields := []FormField{
		{
			label = "📂 Enter the directory path to add:",
			input = input_field,
			validation = initial_validation,
			required = true,
		},
	}

	// Create preview function
	preview_fn := proc(form: ^Form) -> string {
		path_value := form.fields[0].input.value
		if len(path_value) == 0 {
			return ""
		}

		// Generate preview
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)

		// Show what will be added
		expanded := expand_env_vars(path_value)
		defer delete(expanded)

		fmt.sbprintf(&builder, "Will add to PATH:\n")
		fmt.sbprintf(&builder, "  %s\n\n", path_value)

		// Check if directory exists
		if os.exists(expanded) {
			fmt.sbprintf(&builder, "%s✓ Directory exists%s\n", get_success(), RESET)
		} else {
			fmt.sbprintf(&builder, "%s⚠ Directory does not exist yet%s\n", get_warning(), RESET)
			fmt.sbprintf(&builder, "  (You can still add it)\n")
		}

		// Check if already in PATH
		items := extract_path_items()
		defer {
			for item in items {
				delete(item)
			}
			delete(items)
		}

		for item in items {
			if item == path_value {
				fmt.sbprintf(&builder, "%s✗ Path already in configuration%s\n", get_error(), RESET)
				break
			}
		}

		return strings.clone(strings.to_string(builder))
	}

	// Create submit function
	submit_fn := proc(form: ^Form) -> bool {
		path_value := form.fields[0].input.value
		if len(path_value) == 0 {
			return false
		}

		// Add the path using existing logic
		add_path(path_value)
		return true
	}

	// Create and run form
	form := new_form(
		"✨ Add new PATH entry",
		fields,
		preview_fn,
		submit_fn,
	)
	// Clean up form resources
	// Note: initial_validation strings are now owned by form.fields[0].validation
	// and will be cleaned up by form_destroy
	defer form_destroy(&form)

	success := form_run(&form)

	if success {
		// Success message already printed by add_path
	} else {
		print_info("Operation cancelled")
	}
}

// Validator for path input in forms
validate_path_for_form :: proc(path: string) -> InputValidation {
	base_validation := validate_path(path)

	// If base validation failed, return it as InputValidation
	// Note: base_validation.error_message is a string literal, don't delete it
	if !base_validation.valid {
		result := InputValidation{
			valid = false,
			error_message = strings.clone(base_validation.error_message),
			warning = "",
			info = "",
		}
		return result
	}

	// Additional TUI-specific validation
	result := InputValidation{
		valid = true,
		error_message = "",
		warning = "",
		info = "",
	}

	// Check if path exists
	expanded := expand_env_vars(path)
	defer delete(expanded)

	if !os.exists(expanded) {
		result.warning = strings.clone("Directory does not exist (can still be added)")
	} else if !os.is_dir(expanded) {
		result.valid = false
		result.error_message = strings.clone("Path exists but is not a directory")
		return result
	}

	// Check if already added
	items := extract_path_items()
	defer {
		for item in items {
			delete(item)
		}
		delete(items)
	}

	for item in items {
		if item == path {
			result.valid = false
			result.error_message = strings.clone("Path already exists in configuration")
			return result
		}
	}

	result.info = strings.clone("Press Enter to add this path")
	return result
}

add_path :: proc(path: string) {
	// Validate path
	validation_result := validate_path(path)
	if !validation_result.valid {
		print_error_simple("%s", validation_result.error_message)
		delete(validation_result.error_message)
		os.exit(1)
	}

	target_path, path_ok := filepath.abs(path)
	if !path_ok {
		print_error_with_context(.INVALID_INPUT, path, "Could not resolve absolute path")
		os.exit(1)
	}

	// Check if directory exists
	if !os.is_dir(target_path) {
		print_error_with_context(.DIRECTORY_NOT_FOUND, target_path)
		os.exit(1)
	}

	// Dry-run mode check
	if DRY_RUN {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould add to path.%s:%s", BRIGHT_CYAN, SHELL_EXT, RESET)
		fmt.printfln("  add_to_path \"%s\"", target_path)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Use shell-aware config file with fallback for backward compatibility
	config_file := get_config_file_with_fallback("path", DETECTED_SHELL)
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

	// Check if path already exists
	new_entry := fmt.aprintf("add_to_path \"%s\"", target_path)
	defer delete(new_entry)

	for line in lines {
		if strings.contains(line, target_path) && strings.contains(line, "add_to_path") {
			fmt.println("Path already exists:", target_path)
			return
		}
	}

	// Find the last export PATH line and insert before it
	export_line_idx := -1
	for i := len(lines) - 1; i >= 0; i -= 1 {
		if strings.has_prefix(strings.trim_space(lines[i]), "export PATH=") {
			export_line_idx = i
			break
		}
	}

	if export_line_idx == -1 {
		fmt.eprintln("ERROR: Could not find export PATH line in config file")
		os.exit(1)
	}

	// Insert new path before export line
	new_lines := make([]string, len(lines) + 1)
	defer delete(new_lines)

	copy(new_lines[:export_line_idx], lines[:export_line_idx])
	new_lines[export_line_idx] = new_entry
	copy(new_lines[export_line_idx + 1:], lines[export_line_idx:])

	// Create backup before modifying
	if !create_backup_with_prompt(config_file) {
		print_info("Operation cancelled")
		os.exit(1)
	}

	// Write back to file
	new_content := strings.join(new_lines, "\n")
	defer delete(new_content)

	write_ok := safe_write_file(config_file, transmute([]byte)new_content)
	if !write_ok {
		os.exit(1)
	}

	// Cleanup old backups (keep last 5)
	cleanup_old_backups(config_file, 5)

	print_success("Path added successfully: %s", target_path)
}

remove_path :: proc(path: string) {
	// Dry-run mode check
	if DRY_RUN {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould remove from path.%s:%s", BRIGHT_CYAN, SHELL_EXT, RESET)
		fmt.printfln("  Path entry containing: %s", path)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Use shell-aware config file with fallback for backward compatibility
	config_file := get_config_file_with_fallback("path", DETECTED_SHELL)
	defer delete(config_file)

	content, read_ok := safe_read_file(config_file)
	if !read_ok {
		os.exit(1)
	}
	defer delete(content)

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	// Filter out lines containing the path
	filtered_lines := make([dynamic]string)
	defer delete(filtered_lines)

	removed := false
	for line in lines {
		if strings.contains(line, path) && strings.contains(line, "add_to_path") {
			removed = true
			continue
		}
		append(&filtered_lines, line)
	}

	if !removed {
		print_warning("Path not found: %s", path)
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

	print_success("Path removed successfully: %s", path)
}

remove_path_interactive :: proc() {
	items := extract_path_items()
	defer {
		// Clean up the items array properly
		for item in items {
			delete(item)
		}
		delete(items)
	}

	if len(items) == 0 {
		print_warning("No PATH entries found to remove")
		return
	}

	prompt := "Select PATH entry to remove"
	if DRY_RUN {
		prompt = "Select PATH entry to remove (DRY RUN - no changes will be made)"
	}

	selected, ok := interactive_fuzzy_select(items, prompt)
	if !ok {
		print_info("Operation cancelled")
		return
	}

	// Clone the selected item before items get cleaned up
	selected_copy := strings.clone(selected)
	defer delete(selected_copy)

	remove_path(selected_copy)
}

// Interactive fuzzy finder for PATH entries with details and actions
list_paths_interactive :: proc() {
	// Check if wayu is initialized first
	if !check_wayu_initialized() {
		os.exit(1)
	}

	items := extract_path_items()
	defer {
		for item in items {
			delete(item)
		}
		delete(items)
	}

	if len(items) == 0 {
		print_info("No PATH entries found")
		return
	}

	// Convert to FuzzyItems with metadata
	fuzzy_items := make([]FuzzyItem, len(items))
	defer delete(fuzzy_items)

	for item, i in items {
		expanded := expand_env_vars(item)
		defer delete(expanded)

		exists := os.exists(expanded)
		is_dir := os.is_dir(expanded)

		// Create metadata
		metadata := make(map[string]string)
		metadata["path"] = strings.clone(item)
		metadata["expanded"] = strings.clone(expanded)
		metadata["exists"] = exists ? "true" : "false"
		metadata["is_dir"] = is_dir ? "true" : "false"

		fuzzy_items[i] = FuzzyItem{
			display = item,
			value = item,
			metadata = metadata,
			icon = exists ? "✓" : "✗",
			color = exists ? get_success() : get_error(),
		}
	}

	// Define actions
	actions := []FuzzyAction{
		{
			name = "remove",
			key_name = "Del",
			key_code = 127,  // Delete key
			handler = proc(item: ^FuzzyItem) -> bool {
				// Remove the path
				path := item.value
				remove_path(path)
				return true  // Refresh list
			},
			description = "Remove",
		},
	}

	// Create details function
	details_fn := proc(item: ^FuzzyItem) -> string {
		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)

		path := item.metadata["path"]
		expanded := item.metadata["expanded"]
		exists := item.metadata["exists"] == "true"

		// Use simple text without ANSI codes for better alignment
		fmt.sbprintf(&builder, "Path: %s\n", path)
		fmt.sbprintf(&builder, "Expanded: %s\n", expanded)
		fmt.sbprintf(&builder, "\n")

		if exists {
			fmt.sbprintf(&builder, "Status: Directory exists\n")

			// Try to get more info
			info, err := os.stat(expanded)
			if err == 0 {
				mode := info.mode
				fmt.sbprintf(&builder, "Permissions: %o\n", mode & 0o777)
			}

			// Count files (simplified - just check if readable)
			dir_handle, open_err := os.open(expanded)
			if open_err == 0 {
				defer os.close(dir_handle)
				file_infos, read_err := os.read_dir(dir_handle, -1)
				if read_err == 0 {
					defer os.file_info_slice_delete(file_infos)
					fmt.sbprintf(&builder, "Files: %d items\n", len(file_infos))
				}
			}
		} else {
			fmt.sbprintf(&builder, "Status: Directory missing\n")
		}

		fmt.sbprintf(&builder, "\n")
		fmt.sbprintf(&builder, "Actions:\n")
		fmt.sbprintf(&builder, "  Del - Remove from PATH\n")
		fmt.sbprintf(&builder, "  Enter - Exit and select\n")

		return strings.clone(strings.to_string(builder))
	}

	// Create fuzzy view
	view := new_fuzzy_view(
		"🚀 PATH Entries",
		fuzzy_items,
		details_fn,
		actions,
	)

	// Cleanup metadata
	defer {
		for item in fuzzy_items {
			for key, val in item.metadata {
				delete(val)
			}
			delete(item.metadata)
		}
	}

	// Run interactive fuzzy finder
	selected, ok := fuzzy_run(&view)
	fuzzy_view_destroy(&view)

	if ok {
		fmt.printf("\n%sSelected:%s %s\n", get_primary(), RESET, selected.value)
	}
}

// Static table view for PATH entries (for scripts/automation)
list_paths_static :: proc() {
	// Check if wayu is initialized first
	if !check_wayu_initialized() {
		os.exit(1)
	}

	// Use shell-aware config file with fallback for backward compatibility
	config_file := get_config_file_with_fallback("path", DETECTED_SHELL)
	defer delete(config_file)

	content, read_ok := safe_read_file(config_file)
	if !read_ok {
		os.exit(1)
	}
	defer delete(content)

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	// Extract paths for table display
	paths := make([dynamic]string)
	defer {
		for path in paths {
			delete(path)
		}
		delete(paths)
	}

	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "add_to_path") {
			// Extract path from add_to_path "path"
			start := strings.index(trimmed, "\"")
			if start != -1 {
				end := strings.last_index(trimmed, "\"")
				if end != -1 && end > start {
					path := trimmed[start + 1:end]
					append(&paths, strings.clone(path))
				}
			}
		}
	}

	if len(paths) == 0 {
		print_info("No PATH entries found")
		return
	}

	// Analyze paths for duplicates and issues
	path_analysis := analyze_paths(paths[:])
	defer cleanup_path_analysis(&path_analysis)

	// Create and configure table with enhanced headers
	headers := []string{"Entry", "Status", "Issues"}
	table := new_table(headers)
	defer table_destroy(&table)

	// Style the table
	table_style(&table, style_foreground(new_style(), "white"))
	table_header_style(&table, style_bold(style_foreground(new_style(), "cyan"), true))
	table_border(&table, .Normal)

	// Add rows to table with enhanced status information
	for path, i in paths {
		// Expand environment variables in the path before checking existence
		expanded_path := expand_env_vars(path)
		defer delete(expanded_path)

		// Check existence and build status
		status := ""
		issues := ""

		if !os.exists(expanded_path) {
			status = fmt.aprintf("%s Missing", SYMBOL_CHECK_ERROR)
		} else {
			status = fmt.aprintf("%s Exists", SYMBOL_CHECK_SUCCESS)
		}

		// Check for duplicates
		if path_analysis.duplicate_indices[i] {
			if len(issues) > 0 {
				issues = fmt.aprintf("%s, Duplicate", issues)
			} else {
				issues = "Duplicate"
			}
		}

		// Check for common issues
		if strings.has_suffix(expanded_path, "/") && len(expanded_path) > 1 {
			if len(issues) > 0 {
				issues = fmt.aprintf("%s, Trailing slash", issues)
			} else {
				issues = "Trailing slash"
			}
		}

		if len(issues) == 0 {
			issues = "None"
		}

		row := []string{path, status, issues}
		table_add_row(&table, row)
	}

	// Print header with summary
	duplicates_count := count_duplicates(path_analysis.duplicate_indices)
	missing_count := count_missing_paths(paths[:])

	if duplicates_count > 0 || missing_count > 0 {
		fmt.println()
		if missing_count > 0 {
			print_warning("⚠️  Found %d missing directories", missing_count)
		}
		if duplicates_count > 0 {
			print_warning("⚠️  Found %d duplicate entries", duplicates_count)
		}
	}

	table_output := table_render(table)
	defer delete(table_output)
	fmt.print(table_output)

	// Print helpful suggestions if issues found
	if duplicates_count > 0 || missing_count > 0 {
		fmt.println()
		print_info("💡 Suggestions:")
		if missing_count > 0 {
			print_info("   • Remove missing directories: wayu path clean")
		}
		if duplicates_count > 0 {
			print_info("   • Remove duplicates: wayu path dedup")
		}
	}
}

print_path_help :: proc() {
	// Title
	fmt.printf("\n%s%swayu path - Manage PATH entries%s\n\n", BOLD, get_primary(), RESET)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu path add [path]    Add path to PATH (uses PWD if no path)")
	fmt.println("  wayu path rm [path]     Remove path from PATH (interactive if no path)")
	fmt.println("  wayu path list          List all PATH entries with status")
	fmt.println("  wayu path clean         Remove missing directories from PATH")
	fmt.println("  wayu path dedup         Remove duplicate PATH entries")
	fmt.println("  wayu path help          Show this help")

	// Examples section
	fmt.printf("\n%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %swayu path add /usr/local/bin%s\n", get_muted(), RESET)
	fmt.printf("  %swayu path add              # Adds current directory%s\n", get_muted(), RESET)
	fmt.printf("  %swayu path rm /usr/local/bin%s\n", get_muted(), RESET)
	fmt.printf("  %swayu path rm               # Interactive removal%s\n", get_muted(), RESET)
	fmt.printf("  %swayu path clean --dry-run  # Preview which paths would be removed%s\n", get_muted(), RESET)
	fmt.printf("  %swayu path dedup            # Remove duplicate entries%s\n", get_muted(), RESET)
	fmt.println()
}

// Helper function to expand environment variables in path strings
expand_env_vars :: proc(path: string) -> string {
	result := strings.clone(path)

	// Common environment variables to expand
	home := os.get_env("HOME")
	defer delete(home)
	oss := os.get_env("OSS")
	defer delete(oss)
	user := os.get_env("USER")
	defer delete(user)
	pwd := os.get_current_directory()
	defer delete(pwd)

	env_vars := map[string]string{
		"$HOME" = home,
		"$OSS" = oss,
		"$USER" = user,
		"$PWD" = pwd,
	}
	defer delete(env_vars)

	for var, value in env_vars {
		if len(value) > 0 && strings.contains(result, var) {
			new_result, _ := strings.replace_all(result, var, value)
			delete(result)
			result = new_result
		}
	}

	return result
}

// Advanced PATH analysis functionality inspired by pathos
PathAnalysis :: struct {
	duplicate_indices: []bool,
	expanded_paths: []string,
}

analyze_paths :: proc(paths: []string) -> PathAnalysis {
	duplicate_indices := make([]bool, len(paths))
	expanded_paths := make([]string, len(paths))

	// Expand all paths and store them
	for path, i in paths {
		expanded_paths[i] = expand_env_vars(path)
	}

	// Check for duplicates
	for i in 0..<len(expanded_paths) {
		for j in i + 1..<len(expanded_paths) {
			if expanded_paths[i] == expanded_paths[j] {
				duplicate_indices[i] = true
				duplicate_indices[j] = true
			}
		}
	}

	return PathAnalysis{
		duplicate_indices = duplicate_indices,
		expanded_paths = expanded_paths,
	}
}

cleanup_path_analysis :: proc(analysis: ^PathAnalysis) {
	delete(analysis.duplicate_indices)
	for path in analysis.expanded_paths {
		delete(path)
	}
	delete(analysis.expanded_paths)
}

count_duplicates :: proc(duplicate_indices: []bool) -> int {
	count := 0
	for is_duplicate in duplicate_indices {
		if is_duplicate {
			count += 1
		}
	}
	return count
}

count_missing_paths :: proc(paths: []string) -> int {
	count := 0
	for path in paths {
		expanded_path := expand_env_vars(path)
		defer delete(expanded_path)
		if !os.exists(expanded_path) {
			count += 1
		}
	}
	return count
}

// Clean missing paths functionality inspired by pathos
clean_missing_paths :: proc() {
	// Check if wayu is initialized first
	if !check_wayu_initialized() {
		os.exit(1)
	}

	// Use shell-aware config file with fallback for backward compatibility
	config_file := get_config_file_with_fallback("path", DETECTED_SHELL)
	defer delete(config_file)

	content, read_ok := safe_read_file(config_file)
	if !read_ok {
		os.exit(1)
	}
	defer delete(content)

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	// Extract paths and check which ones are missing
	paths := make([dynamic]string)
	missing_paths := make([dynamic]string)
	defer {
		for path in paths {
			delete(path)
		}
		delete(paths)
		for path in missing_paths {
			delete(path)
		}
		delete(missing_paths)
	}

	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "add_to_path") {
			// Extract path from add_to_path "path"
			start := strings.index(trimmed, "\"")
			if start != -1 {
				end := strings.last_index(trimmed, "\"")
				if end != -1 && end > start {
					path := trimmed[start + 1:end]
					append(&paths, strings.clone(path))

					// Check if this path is missing
					expanded_path := expand_env_vars(path)
					defer delete(expanded_path)
					if !os.exists(expanded_path) {
						append(&missing_paths, strings.clone(path))
					}
				}
			}
		}
	}

	if len(missing_paths) == 0 {
		print_success("✅ No missing directories found in PATH")
		return
	}

	// Dry-run mode check
	if DRY_RUN {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		print_warning("Would remove %d missing directories:", len(missing_paths))
		for path in missing_paths {
			fmt.printfln("  - %s", path)
		}
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Show what will be removed and ask for confirmation
	print_header("Clean Missing PATH Entries", "🧹")
	fmt.println()
	print_warning("Found %d missing directories to remove:", len(missing_paths))
	for path in missing_paths {
		fmt.printfln("  - %s", path)
	}
	fmt.println()

	// Ask for confirmation
	fmt.print("Continue with cleanup? [y/N]: ")
	input_buf: [10]byte
	n, err := os.read(os.stdin, input_buf[:])
	if err != 0 || n == 0 {
		print_info("Operation cancelled")
		return
	}

	response := strings.trim_space(string(input_buf[:n]))
	if response != "y" && response != "Y" {
		print_info("Operation cancelled")
		return
	}

	// Filter out missing paths
	filtered_lines := make([dynamic]string)
	defer delete(filtered_lines)

	removed_count := 0
	for line in lines {
		trimmed := strings.trim_space(line)
		should_keep := true

		if strings.has_prefix(trimmed, "add_to_path") {
			// Check if this line contains a missing path
			for missing_path in missing_paths {
				if strings.contains(line, missing_path) {
					should_keep = false
					removed_count += 1
					break
				}
			}
		}

		if should_keep {
			append(&filtered_lines, line)
		}
	}

	// Create backup before modifying
	if !create_backup_with_prompt(config_file) {
		print_info("Operation cancelled")
		os.exit(1)
	}

	// Write cleaned content back to file
	new_content := strings.join(filtered_lines[:], "\n")
	defer delete(new_content)

	write_ok := safe_write_file(config_file, transmute([]byte)new_content)
	if !write_ok {
		os.exit(1)
	}

	// Cleanup old backups (keep last 5)
	cleanup_old_backups(config_file, 5)

	print_success("✅ Removed %d missing directories from PATH", removed_count)
}

// Remove duplicate paths functionality inspired by pathos
remove_duplicate_paths :: proc() {
	// Check if wayu is initialized first
	if !check_wayu_initialized() {
		os.exit(1)
	}

	// Use shell-aware config file with fallback for backward compatibility
	config_file := get_config_file_with_fallback("path", DETECTED_SHELL)
	defer delete(config_file)

	content, read_ok := safe_read_file(config_file)
	if !read_ok {
		os.exit(1)
	}
	defer delete(content)

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	// Extract paths and find duplicates
	paths := make([dynamic]string)
	expanded_paths := make([dynamic]string)
	line_indices := make([dynamic]int)
	defer {
		for path in paths {
			delete(path)
		}
		delete(paths)
		for path in expanded_paths {
			delete(path)
		}
		delete(expanded_paths)
		delete(line_indices)
	}

	// Build list of path entries with their line indices
	for line, i in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "add_to_path") {
			// Extract path from add_to_path "path"
			start := strings.index(trimmed, "\"")
			if start != -1 {
				end := strings.last_index(trimmed, "\"")
				if end != -1 && end > start {
					path := trimmed[start + 1:end]
					expanded_path := expand_env_vars(path)

					append(&paths, strings.clone(path))
					append(&expanded_paths, expanded_path)
					append(&line_indices, i)
				}
			}
		}
	}

	// Find duplicates (keep first occurrence, mark others for removal)
	duplicate_indices := make([dynamic]int)
	defer delete(duplicate_indices)

	for i in 0..<len(expanded_paths) {
		for j in i + 1..<len(expanded_paths) {
			if expanded_paths[i] == expanded_paths[j] {
				append(&duplicate_indices, line_indices[j])
			}
		}
	}

	if len(duplicate_indices) == 0 {
		print_success("✅ No duplicate entries found in PATH")
		return
	}

	// Dry-run mode check
	if DRY_RUN {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		print_warning("Would remove %d duplicate entries:", len(duplicate_indices))
		for idx in duplicate_indices {
			fmt.printfln("  - %s", strings.trim_space(lines[idx]))
		}
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Show what will be removed and ask for confirmation
	print_header("Remove Duplicate PATH Entries", "🔗")
	fmt.println()
	print_warning("Found %d duplicate entries to remove:", len(duplicate_indices))
	for idx in duplicate_indices {
		fmt.printfln("  - %s", strings.trim_space(lines[idx]))
	}
	fmt.println()

	// Ask for confirmation
	fmt.print("Continue with deduplication? [y/N]: ")
	input_buf: [10]byte
	n, err := os.read(os.stdin, input_buf[:])
	if err != 0 || n == 0 {
		print_info("Operation cancelled")
		return
	}

	response := strings.trim_space(string(input_buf[:n]))
	if response != "y" && response != "Y" {
		print_info("Operation cancelled")
		return
	}

	// Create backup before modifying
	if !create_backup_with_prompt(config_file) {
		print_info("Operation cancelled")
		os.exit(1)
	}

	// Filter out duplicate lines
	filtered_lines := make([dynamic]string)
	defer delete(filtered_lines)

	for line, i in lines {
		should_keep := true
		for dup_idx in duplicate_indices {
			if i == dup_idx {
				should_keep = false
				break
			}
		}
		if should_keep {
			append(&filtered_lines, line)
		}
	}

	// Write deduplicated content back to file
	new_content := strings.join(filtered_lines[:], "\n")
	defer delete(new_content)

	write_ok := safe_write_file(config_file, transmute([]byte)new_content)
	if !write_ok {
		os.exit(1)
	}

	// Cleanup old backups (keep last 5)
	cleanup_old_backups(config_file, 5)

	print_success("✅ Removed %d duplicate entries from PATH", len(duplicate_indices))
}
