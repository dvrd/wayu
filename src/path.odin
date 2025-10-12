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
			// Use current working directory
			cwd := os.get_current_directory()
			add_path(cwd)
		} else {
			add_path(args[0])
		}
	case .REMOVE:
		if len(args) == 0 {
			remove_path_interactive()
		} else {
			remove_path(args[0])
		}
	case .LIST:
		list_paths()
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

list_paths :: proc() {
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

	fmt.printf("%s%s🗂️  Current PATH entries:%s\n", PRIMARY, BOLD, RESET)
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "add_to_path") {
			// Extract path from add_to_path "path"
			start := strings.index(trimmed, "\"")
			if start != -1 {
				end := strings.last_index(trimmed, "\"")
				if end != -1 && end > start {
					path := trimmed[start + 1:end]
					fmt.printf("  %s\n", path)
				}
			}
		}
	}
}

print_path_help :: proc() {
	fmt.println("wayu path - Manage PATH entries")
	fmt.println("")
	fmt.println("USAGE:")
	fmt.println("  wayu path add [path]    Add path to PATH (uses PWD if no path)")
	fmt.println("  wayu path rm [path]     Remove path from PATH (interactive if no path)")
	fmt.println("  wayu path list          List all PATH entries")
	fmt.println("  wayu path help          Show this help")
	fmt.println("")
	fmt.println("EXAMPLES:")
	fmt.println("  wayu path add /usr/local/bin")
	fmt.println("  wayu path add              # Adds current directory")
	fmt.println("  wayu path rm /usr/local/bin")
	fmt.println("  wayu path rm               # Interactive removal")
}