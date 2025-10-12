// completions.odin - Manage Zsh completion scripts

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

COMPLETIONS_FILE :: "completions"

// Handle completions command
handle_completions_command :: proc(action: Action, args: []string) {
	switch action {
	case .ADD:
		if len(args) < 2 {
			print_error_simple("Usage: wayu completions add <name> <source-file>")
			fmt.println("Example: wayu completions add jj /path/to/_jj")
			os.exit(1)
		}
		add_completion(args[0], args[1])
	case .REMOVE:
		if len(args) == 0 {
			remove_completion_interactive()
		} else {
			remove_completion(args[0])
		}
	case .LIST:
		list_completions()
	case .RESTORE:
		// RESTORE action is handled by backup command, not completions command
		fmt.eprintln("ERROR: restore action not supported for completions command")
		fmt.println("Use: wayu backup restore completions")
		os.exit(1)
	case .CLEAN:
		fmt.eprintln("ERROR: clean action not supported for completions command")
		fmt.println("The clean action only applies to path entries")
		os.exit(1)
	case .DEDUP:
		fmt.eprintln("ERROR: dedup action not supported for completions command")
		fmt.println("The dedup action only applies to path entries")
		os.exit(1)
	case .HELP:
		print_completions_help()
	case .UNKNOWN:
		fmt.eprintln("Unknown completions action")
		print_completions_help()
		os.exit(1)
	}
}

// Add completion from source file
add_completion :: proc(name: string, source_path: string) {
	// Validate source file exists
	if !os.exists(source_path) {
		print_error_with_context(.FILE_NOT_FOUND, source_path)
		os.exit(1)
	}

	// Normalize name (add underscore if missing)
	completion_name := name
	allocated_name := false
	if !strings.has_prefix(name, "_") {
		completion_name = fmt.aprintf("_%s", name)
		allocated_name = true
	}

	// Read source file
	content, read_ok := safe_read_file(source_path)
	if !read_ok {
		os.exit(1)
	}
	defer delete(content)

	// Destination directory
	completions_dir := fmt.aprintf("%s/completions", WAYU_CONFIG)
	defer delete(completions_dir)

	// Ensure completions directory exists
	if !os.exists(completions_dir) {
		print_error_with_context(.CONFIG_NOT_INITIALIZED, WAYU_CONFIG)
		os.exit(1)
	}

	dest_path := fmt.aprintf("%s/%s", completions_dir, completion_name)
	defer delete(dest_path)

	// Check if already exists
	if os.exists(dest_path) {
		fmt.printfln("%sWarning:%s Completion '%s' already exists. Overwriting.",
			WARNING, RESET, completion_name)
	}

	// Dry-run mode check
	if DRY_RUN {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould copy to completions directory:%s", BRIGHT_CYAN, RESET)
		fmt.printfln("  %s -> %s", source_path, dest_path)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		// Clean up allocated name if needed
		if allocated_name {
			delete(completion_name)
		}
		return
	}

	// Create backup before modifying
	if !create_backup_with_prompt(dest_path) {
		print_info("Operation cancelled")
		os.exit(1)
	}

	// Write to destination
	write_ok := safe_write_file(dest_path, content)
	if !write_ok {
		os.exit(1)
	}

	// Cleanup old backups (keep last 5)
	cleanup_old_backups(dest_path, 5)

	print_success("Added completion: %s", completion_name)
	fmt.printfln("\n%sNext steps:%s", BRIGHT_CYAN, RESET)
	fmt.printfln("  source ~/.config/wayu/init.zsh")
	fmt.printfln("  or restart your shell")

	// Clean up allocated name if needed
	if allocated_name {
		delete(completion_name)
	}
}

// Remove completion file
remove_completion :: proc(name: string) {
	// Normalize name
	completion_name := name
	allocated_name := false
	if !strings.has_prefix(name, "_") {
		completion_name = fmt.aprintf("_%s", name)
		allocated_name = true
	}

	// Build path
	completions_dir := fmt.aprintf("%s/completions", WAYU_CONFIG)
	defer delete(completions_dir)

	file_path := fmt.aprintf("%s/%s", completions_dir, completion_name)
	defer delete(file_path)

	// Check exists
	if !os.exists(file_path) {
		print_error_simple("Completion not found: %s", completion_name)
		fmt.printfln("\nRun %swayu completions list%s to see available completions",
			MUTED, RESET)
		os.exit(1)
	}

	// Dry-run mode check
	if DRY_RUN {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould remove completion file:%s", BRIGHT_CYAN, RESET)
		fmt.printfln("  %s", file_path)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		// Clean up allocated name if needed
		if allocated_name {
			delete(completion_name)
		}
		return
	}

	// Create backup before removing
	if !create_backup_with_prompt(file_path) {
		print_info("Operation cancelled")
		os.exit(1)
	}

	// Remove file
	err := os.remove(file_path)
	if err != 0 {
		print_error_simple("Failed to remove completion: %s", completion_name)
		os.exit(1)
	}

	// Cleanup old backups (keep last 5)
	cleanup_old_backups(file_path, 5)

	print_success("Removed completion: %s", completion_name)

	// Clean up allocated name if needed
	if allocated_name {
		delete(completion_name)
	}
}

// Interactive removal using fuzzy finder
remove_completion_interactive :: proc() {
	items := extract_completion_items()
	defer {
		for item in items {
			delete(item)
		}
		delete(items)
	}

	if len(items) == 0 {
		print_warning("No completions found to remove")
		return
	}

	prompt_text := "Select completion to remove (Ctrl+C to cancel):"
	if DRY_RUN {
		prompt_text = "Select completion to remove (DRY RUN - no changes will be made):"
	}

	prompt := fmt.aprintf(prompt_text)
	defer delete(prompt)

	selected, ok := interactive_fuzzy_select(items, prompt)
	if !ok {
		print_info("Operation cancelled")
		return
	}

	// Clone before parent is freed
	selected_copy := strings.clone(selected)
	defer delete(selected_copy)

	remove_completion(selected_copy)
}

// List all completions with metadata
list_completions :: proc() {
	// Check if wayu is initialized first
	if !check_wayu_initialized() {
		os.exit(1)
	}

	completions_dir := fmt.aprintf("%s/completions", WAYU_CONFIG)
	defer delete(completions_dir)

	// Check directory exists
	if !os.exists(completions_dir) {
		print_error_with_context(.CONFIG_NOT_INITIALIZED, WAYU_CONFIG)
		os.exit(1)
	}

	// Read directory
	dir_handle, err := os.open(completions_dir)
	if err != 0 {
		print_error_simple("Failed to open completions directory")
		os.exit(1)
	}
	defer os.close(dir_handle)

	file_infos, read_err := os.read_dir(dir_handle, -1)
	if read_err != 0 {
		print_error_simple("Failed to read completions directory")
		os.exit(1)
	}
	defer os.file_info_slice_delete(file_infos)

	// Filter completion files
	completion_files := make([dynamic]os.File_Info)
	defer delete(completion_files)

	for info in file_infos {
		if strings.has_prefix(info.name, "_") && !info.is_dir {
			// Skip backup files
			if strings.contains(info.name, ".backup.") {
				continue
			}
			append(&completion_files, info)
		}
	}

	// Print header
	print_header("Shell Completions")
	fmt.println()

	if len(completion_files) == 0 {
		print_info("No completions installed")
		fmt.printfln("\nAdd completions with: %swayu completions add <name> <source-file>%s",
			MUTED, RESET)
		return
	}

	// Print each completion
	for info, i in completion_files {
		// Read first line for description
		file_path := fmt.aprintf("%s/%s", completions_dir, info.name)
		defer delete(file_path)

		first_line := ""
		content, read_ok := os.read_entire_file_from_filename(file_path)
		if read_ok {
			defer delete(content)
			lines := strings.split(string(content), "\n")
			defer delete(lines)
			if len(lines) > 0 {
				first_line = strings.trim_space(lines[0])
				if len(first_line) > 60 {
					truncated := fmt.aprintf("%s...", first_line[:60])
					defer delete(truncated)
					first_line = truncated
				}
			}
		}

		// Print completion info
		fmt.printf("  %s%s%d.%s ", MUTED, BOLD, i+1, RESET)
		fmt.printf("%s%s%s", PRIMARY, info.name, RESET)

		// Size
		size_kb := f32(info.size) / 1024.0
		fmt.printf(" %s(%.1f KB)%s", MUTED, size_kb, RESET)

		fmt.println()

		if len(first_line) > 0 {
			fmt.printf("     %s%s%s\n", MUTED, first_line, RESET)
		}
	}

	fmt.printfln("\n%sTotal:%s %d completion(s)", BRIGHT_CYAN, RESET, len(completion_files))
}

// Help for completions command
print_completions_help :: proc() {
	print_header("Completions Command")
	fmt.println()

	fmt.printfln("%sUSAGE:%s", BRIGHT_CYAN, RESET)
	fmt.printfln("  wayu completions %s<action>%s [arguments]", MUTED, RESET)
	fmt.println()

	fmt.printfln("%sACTIONS:%s", BRIGHT_CYAN, RESET)
	fmt.printfln("  %sadd%s     Add completion from source file", BOLD, RESET)
	fmt.printfln("  %sremove%s  Remove completion (alias: rm)", BOLD, RESET)
	fmt.printfln("  %slist%s    List all installed completions (alias: ls)", BOLD, RESET)
	fmt.printfln("  %shelp%s    Show this help message", BOLD, RESET)
	fmt.println()

	fmt.printfln("%sEXAMPLES:%s", BRIGHT_CYAN, RESET)
	fmt.printfln("  # Add jujutsu completion")
	fmt.printfln("  wayu completions add jj /path/to/_jj")
	fmt.println()
	fmt.printfln("  # List all completions")
	fmt.printfln("  wayu completions list")
	fmt.println()
	fmt.printfln("  # Remove completion interactively")
	fmt.printfln("  wayu completions rm")
	fmt.println()
	fmt.printfln("  # Remove specific completion")
	fmt.printfln("  wayu completions rm jj")
	fmt.println()

	fmt.printfln("%sNOTES:%s", BRIGHT_CYAN, RESET)
	fmt.printfln("  • Completion files are stored in ~/.config/wayu/completions/")
	fmt.printfln("  • Files are automatically prefixed with '_' if not already")
	fmt.printfln("  • Restart your shell or run 'source ~/.config/wayu/init.zsh' after adding completions")
}