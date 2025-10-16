// path.odin - PATH entry management (refactored to use config_entry abstraction)
//
// This module manages PATH entries using the generic config_entry system.
// It provides PATH-specific functionality like clean and dedup operations.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// Main handler for PATH commands - delegates to generic handler
handle_path_command :: proc(action: Action, args: []string) {
	#partial switch action {
	case .CLEAN:
		clean_missing_paths()
	case .DEDUP:
		remove_duplicate_paths()
	case:
		// All other actions (ADD, REMOVE, LIST, HELP) are handled generically
		handle_config_command(&PATH_SPEC, action, args)
	}
}

// ============================================================================
// PATH-specific operations (clean and dedup)
// ============================================================================

// Clean missing paths - remove directories that no longer exist
clean_missing_paths :: proc() {
	// Check if wayu is initialized first
	if !check_wayu_initialized() {
		os.exit(1)
	}

	// Read all PATH entries
	entries := read_config_entries(&PATH_SPEC)
	defer cleanup_entries(&entries)

	// Find missing paths
	missing_entries := make([dynamic]ConfigEntry)
	defer {
		for &entry in missing_entries {
			cleanup_entry(&entry)
		}
		delete(missing_entries)
	}

	for entry in entries {
		expanded := expand_env_vars(entry.name)
		defer delete(expanded)

		if !os.exists(expanded) {
			// Clone the entry for the missing list
			missing_entry := ConfigEntry{
				type = entry.type,
				name = strings.clone(entry.name),
				value = strings.clone(entry.value),
				line = strings.clone(entry.line),
			}
			append(&missing_entries, missing_entry)
		}
	}

	if len(missing_entries) == 0 {
		print_success("✅ No missing directories found in PATH")
		return
	}

	// Dry-run mode check
	if DRY_RUN {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		print_warning("Would remove %d missing directories:", len(missing_entries))
		for entry in missing_entries {
			fmt.printfln("  - %s", entry.name)
		}
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Show what will be removed and ask for confirmation
	print_header("Clean Missing PATH Entries", "🧹")
	fmt.println()
	print_warning("Found %d missing directories to remove:", len(missing_entries))
	for entry in missing_entries {
		fmt.printfln("  - %s", entry.name)
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

	// Get config file
	config_file := get_config_file_with_fallback(PATH_SPEC.file_name, DETECTED_SHELL)
	defer delete(config_file)

	// Read current content
	content, read_ok := safe_read_file(config_file)
	if !read_ok { os.exit(1) }
	defer delete(content)

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	// Filter out missing paths
	new_lines := make([dynamic]string)
	defer {
		for line in new_lines {
			delete(line)
		}
		delete(new_lines)
	}

	removed_count := 0
	for line in lines {
		entry, ok := PATH_SPEC.parse_line(line)
		if ok {
			defer cleanup_entry(&entry)

			// Check if this is a missing path
			is_missing := false
			for missing_entry in missing_entries {
				if entry.name == missing_entry.name {
					is_missing = true
					removed_count += 1
					break
				}
			}

			if is_missing {
				continue
			}
		}
		append(&new_lines, strings.clone(line))
	}

	// Create backup before modifying
	if !create_backup_with_prompt(config_file) {
		print_info("Operation cancelled")
		os.exit(1)
	}

	// Write back
	new_content := strings.join(new_lines[:], "\n")
	defer delete(new_content)

	write_ok := safe_write_file(config_file, transmute([]byte)new_content)
	if !write_ok { os.exit(1) }

	// Cleanup old backups
	cleanup_old_backups(config_file, 5)

	print_success("✅ Removed %d missing directories from PATH", removed_count)
}

// Remove duplicate paths
remove_duplicate_paths :: proc() {
	// Check if wayu is initialized first
	if !check_wayu_initialized() {
		os.exit(1)
	}

	// Read all PATH entries
	entries := read_config_entries(&PATH_SPEC)
	defer cleanup_entries(&entries)

	// Find duplicates by expanding paths
	expanded_paths := make([]string, len(entries))
	defer {
		for path in expanded_paths {
			delete(path)
		}
		delete(expanded_paths)
	}

	for entry, i in entries {
		expanded_paths[i] = expand_env_vars(entry.name)
	}

	// Track which indices are duplicates (keep first, mark rest)
	duplicate_indices := make([dynamic]int)
	defer delete(duplicate_indices)

	for i in 0..<len(expanded_paths) {
		for j in i + 1..<len(expanded_paths) {
			if expanded_paths[i] == expanded_paths[j] {
				append(&duplicate_indices, j)
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
			fmt.printfln("  - %s", entries[idx].name)
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
		fmt.printfln("  - %s", entries[idx].name)
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

	// Get config file
	config_file := get_config_file_with_fallback(PATH_SPEC.file_name, DETECTED_SHELL)
	defer delete(config_file)

	// Read current content
	content, read_ok := safe_read_file(config_file)
	if !read_ok { os.exit(1) }
	defer delete(content)

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	// Build list of names to remove
	names_to_remove := make([dynamic]string)
	defer {
		for name in names_to_remove {
			delete(name)
		}
		delete(names_to_remove)
	}

	for idx in duplicate_indices {
		append(&names_to_remove, strings.clone(entries[idx].name))
	}

	// Filter out duplicates
	new_lines := make([dynamic]string)
	defer {
		for line in new_lines {
			delete(line)
		}
		delete(new_lines)
	}

	removed_count := 0
	for line in lines {
		entry, ok := PATH_SPEC.parse_line(line)
		if ok {
			defer cleanup_entry(&entry)

			// Check if this is a duplicate to remove
			is_duplicate := false
			for name in names_to_remove {
				if entry.name == name {
					is_duplicate = true
					removed_count += 1
					// Remove this name from the list so we only skip it once
					for i in 0..<len(names_to_remove) {
						if names_to_remove[i] == name {
							// Remove by swapping with last and shrinking
							last_idx := len(names_to_remove) - 1
							if i != last_idx {
								names_to_remove[i] = names_to_remove[last_idx]
							}
							resize(&names_to_remove, last_idx)
							break
						}
					}
					break
				}
			}

			if is_duplicate {
				continue
			}
		}
		append(&new_lines, strings.clone(line))
	}

	// Create backup before modifying
	if !create_backup_with_prompt(config_file) {
		print_info("Operation cancelled")
		os.exit(1)
	}

	// Write back
	new_content := strings.join(new_lines[:], "\n")
	defer delete(new_content)

	write_ok := safe_write_file(config_file, transmute([]byte)new_content)
	if !write_ok { os.exit(1) }

	// Cleanup old backups
	cleanup_old_backups(config_file, 5)

	print_success("✅ Removed %d duplicate entries from PATH", removed_count)
}

// ============================================================================
// PATH-specific helpers
// ============================================================================

// Extract PATH items as a list of strings (for backward compatibility with old code)
extract_path_items :: proc() -> []string {
	entries := read_config_entries(&PATH_SPEC)
	defer cleanup_entries(&entries)

	items := make([]string, len(entries))
	for entry, i in entries {
		items[i] = strings.clone(entry.name)
	}

	return items
}

// Expand environment variables in path strings
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
