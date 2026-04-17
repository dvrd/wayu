// path.odin - PATH entry management (refactored to use config_entry abstraction)
//
// This module manages PATH entries using the generic config_entry system.
// It provides PATH-specific functionality like clean and dedup operations.

#+feature dynamic-literals
package wayu

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Main handler for PATH commands.
// When wayu.toml exists, PATH becomes TOML-native; otherwise we preserve the
// legacy shell-file workflow used by older tests and configs.
handle_path_command :: proc(action: Action, args: []string) {
	toml_file := fmt.aprintf("%s/%s", WAYU_CONFIG, WAYU_TOML)
	defer delete(toml_file)

	use_toml := os.exists(toml_file)

	#partial switch action {
	case .CLEAN:
		clean_missing_paths()
	case .DEDUP:
		remove_duplicate_paths()
	case .ADD:
		if len(args) == 0 {
			print_error("Usage: wayu path add <path>")
			os.exit(EXIT_USAGE)
		}
		entry := ConfigEntry{type = .PATH, name = args[0], value = "", line = ""}
		result := validate_path_entry(entry)
		if !result.valid {
			print_error(result.error_message)
			delete(result.error_message)
			os.exit(EXIT_DATAERR)
		}
		expanded := expand_env_vars(args[0])
		defer delete(expanded)
		if !os.exists(expanded) {
			print_error("Path does not exist: %s", args[0])
			os.exit(EXIT_NOINPUT)
		}
		if use_toml {
			hook_pre_path_add(args[0])
			if toml_path_add(args[0]) {
				print_success("✅ Added to wayu.toml: %s", args[0])
				fmt.printfln("   Run 'wayu build eval' and reload your shell to apply.")
				hook_post_path_add(args[0])
			} else {
				os.exit(EXIT_IOERR)
			}
		} else {
			handle_config_command(&PATH_SPEC, action, args)
		}
	case .REMOVE:
		if use_toml {
			if len(args) == 0 {
				print_error("Usage: wayu path remove <path>")
				os.exit(EXIT_USAGE)
			}
			hook_pre_path_remove(args[0])
			if toml_path_remove(args[0]) {
				print_success("✅ Removed from wayu.toml: %s", args[0])
				fmt.printfln("   Run 'wayu build eval' and reload your shell to apply.")
				hook_post_path_remove(args[0])
			} else {
				os.exit(EXIT_IOERR)
			}
		} else {
			handle_config_command(&PATH_SPEC, action, args)
		}
	case .LIST:
		if use_toml {
			toml_path_list()
		} else {
			handle_config_command(&PATH_SPEC, action, args)
		}
	case:
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
		os.exit(EXIT_CONFIG)
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

	// Check for --yes flag (required for confirmation)
	if !YES_FLAG {
		print_error("This operation requires confirmation.")
		fmt.println()
		fmt.printfln("Found %d missing directories to remove:", len(missing_entries))
		for entry in missing_entries {
			fmt.printfln("  - %s", entry.name)
		}
		fmt.println()
		fmt.printfln("Add --yes flag to proceed:")
		fmt.printfln("  wayu path clean --yes")
		os.exit(EXIT_GENERAL)
	}

	// Show what will be removed
	print_header("Clean Missing PATH Entries", "🧹")
	fmt.println()
	print_warning("Found %d missing directories to remove:", len(missing_entries))
	for entry in missing_entries {
		fmt.printfln("  - %s", entry.name)
	}
	fmt.println()

	// Get config file
	config_file := get_config_file_with_fallback(PATH_SPEC.file_name, DETECTED_SHELL)
	defer delete(config_file)

	// Read current content
	content, read_ok := safe_read_file(config_file)
	if !read_ok { os.exit(EXIT_IOERR) }
	defer delete(content)

	content_str := string(content)
	// Use temp allocator for the lines array since it's only needed during this function
	lines := strings.split(content_str, "\n", context.temp_allocator)
	// No need to defer delete - temp allocator manages this

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

	print_success("✅ Removed %d missing directories from PATH", removed_count)
}

// Remove duplicate paths
remove_duplicate_paths :: proc() {
	// Check if wayu is initialized first
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
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

	// Check for --yes flag (required for confirmation)
	if !YES_FLAG {
		print_error("This operation requires confirmation.")
		fmt.println()
		fmt.printfln("Found %d duplicate entries to remove:", len(duplicate_indices))
		for idx in duplicate_indices {
			fmt.printfln("  - %s", entries[idx].name)
		}
		fmt.println()
		fmt.printfln("Add --yes flag to proceed:")
		fmt.printfln("  wayu path dedup --yes")
		os.exit(EXIT_GENERAL)
	}

	// Show what will be removed
	print_header("Remove Duplicate PATH Entries", "🔗")
	fmt.println()
	print_warning("Found %d duplicate entries to remove:", len(duplicate_indices))
	for idx in duplicate_indices {
		fmt.printfln("  - %s", entries[idx].name)
	}
	fmt.println()

	// Get config file
	config_file := get_config_file_with_fallback(PATH_SPEC.file_name, DETECTED_SHELL)
	defer delete(config_file)

	// Read current content
	content, read_ok := safe_read_file(config_file)
	if !read_ok { os.exit(EXIT_IOERR) }
	defer delete(content)

	content_str := string(content)
	// Use temp allocator for the lines array since it's only needed during this function
	lines := strings.split(content_str, "\n", context.temp_allocator)
	// No need to defer delete - temp allocator manages this

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

// is_env_var_char returns true for characters valid in a shell identifier:
// A-Z, a-z, 0-9, underscore.
@(private="file")
is_env_var_char :: proc(c: byte) -> bool {
	return (c >= 'A' && c <= 'Z') ||
	       (c >= 'a' && c <= 'z') ||
	       (c >= '0' && c <= '9') ||
	       c == '_'
}

// Expand environment variables in path strings.
// Handles $VAR and ${VAR} syntax for any variable present in the environment.
// Unresolved tokens (variable not set or empty) are left as-is.
// The caller must delete the returned string.
expand_env_vars :: proc(path: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	i := 0
	for i < len(path) {
		if path[i] != '$' {
			strings.write_byte(&builder, path[i])
			i += 1
			continue
		}

		// We are at a '$' — determine token length and variable name.
		token_start := i
		i += 1 // skip '$'

		var_name: string
		token_len: int

		if i < len(path) && path[i] == '{' {
			// ${VAR} syntax — find closing '}'
			i += 1 // skip '{'
			name_start := i
			for i < len(path) && path[i] != '}' {
				i += 1
			}
			var_name = path[name_start:i]
			if i < len(path) {
				i += 1 // skip '}'
			}
			token_len = i - token_start
		} else {
			// $VAR syntax — scan identifier characters
			name_start := i
			for i < len(path) && is_env_var_char(path[i]) {
				i += 1
			}
			var_name = path[name_start:i]
			token_len = i - token_start
		}

		if len(var_name) == 0 {
			// Bare '$' with no identifier — emit as-is
			strings.write_byte(&builder, '$')
			continue
		}

		value := os.get_env(var_name, context.allocator)
		defer delete(value)

		if len(value) > 0 {
			strings.write_string(&builder, value)
		} else {
			// Variable not set or empty — preserve original token
			strings.write_string(&builder, path[token_start : token_start + token_len])
		}
	}

	result := strings.clone(strings.to_string(builder))

	// Resolve relative paths (., .., ./, ../) and any remaining ~ to absolute.
	abs_path, abs_err := filepath.abs(result, context.allocator)
	if abs_err == nil {
		delete(result)
		result = abs_path
	}

	return result
}

// ============================================================================
// wayu.toml PATH operations
// ============================================================================

WAYU_TOML :: "wayu.toml"

// Lee los [[paths]] de wayu.toml y retorna la lista (caller debe liberar)
toml_path_read :: proc() -> [dynamic]string {
	config_file := fmt.aprintf("%s/%s", WAYU_CONFIG, WAYU_TOML)
	defer delete(config_file)

	content, ok := safe_read_file(config_file)
	if !ok { return make([dynamic]string) }
	defer delete(content)

	paths := make([dynamic]string)
	lines := strings.split(string(content), "\n")
	defer delete(lines)

	in_paths := false
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "[[paths]]" {
			in_paths = true
			continue
		}
		if strings.has_prefix(trimmed, "[") {
			in_paths = false
			continue
		}
		if in_paths && strings.has_prefix(trimmed, "path = ") {
			value := strings.trim_space(trimmed[7:])
			if len(value) >= 2 && value[0] == '"' && value[len(value)-1] == '"' {
				append(&paths, strings.clone(value[1:len(value)-1]))
				in_paths = false
			}
		}
	}

	return paths
}

// Lista los paths de wayu.toml en stdout
toml_path_list :: proc() {
	paths := toml_path_read()
	defer {
		for p in paths { delete(p) }
		delete(paths)
	}

	print_header("PATH (wayu.toml)", PATH_SPEC.icon)
	fmt.println()

	if len(paths) == 0 {
		fmt.printfln("  No paths configured in wayu.toml")
		return
	}

	for p, i in paths {
		exists := os.exists(p)
		marker := "  "
		if !exists { marker = "✗ " }
		fmt.printfln("%s%d. %s", marker, i+1, p)
	}

	fmt.println()
	fmt.printfln("Total: %d paths", len(paths))
}

// Agrega un path al final de wayu.toml
toml_path_add :: proc(path: string) -> bool {
	config_file := fmt.aprintf("%s/%s", WAYU_CONFIG, WAYU_TOML)
	defer delete(config_file)

	// Verificar duplicado
	existing := toml_path_read()
	defer {
		for p in existing { delete(p) }
		delete(existing)
	}
	for p in existing {
		if p == path {
			print_warning("Path already exists in wayu.toml: %s", path)
			return true
		}
	}

	content, ok := safe_read_file(config_file)
	if !ok { return false }
	defer delete(content)

	// Construir nueva entrada
	new_entry := fmt.aprintf("\n[[paths]]\npath = \"%s\"\n", path)
	defer delete(new_entry)

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, string(content))
	strings.write_string(&builder, new_entry)

	new_content := strings.clone(strings.to_string(builder))
	defer delete(new_content)

	if !create_backup_cli(config_file) { return false }
	return safe_write_file(config_file, transmute([]byte)new_content)
}

// Elimina un path del wayu.toml
toml_path_remove :: proc(path: string) -> bool {
	config_file := fmt.aprintf("%s/%s", WAYU_CONFIG, WAYU_TOML)
	defer delete(config_file)

	content, ok := safe_read_file(config_file)
	if !ok { return false }
	defer delete(content)

	lines := strings.split(string(content), "\n")
	defer delete(lines)

	new_lines := make([dynamic]string)
	defer {
		for line in new_lines { delete(line) }
		delete(new_lines)
	}

	found := false
	i := 0
	for i < len(lines) {
		trimmed := strings.trim_space(lines[i])
		if trimmed == "[[paths]]" {
			// Buscar la línea path = "..." que sigue
			j := i + 1
			for j < len(lines) && strings.trim_space(lines[j]) == "" {
				j += 1
			}
			if j < len(lines) {
				next := strings.trim_space(lines[j])
				target := fmt.aprintf("path = \"%s\"", path)
				is_match := next == target
				delete(target)
				if is_match {
					found = true
					i = j + 1
					continue
				}
			}
		}
		append(&new_lines, strings.clone(lines[i]))
		i += 1
	}

	if !found {
		print_error("Path not found in wayu.toml: %s", path)
		return false
	}

	if !create_backup_cli(config_file) { return false }

	new_content := strings.join(new_lines[:], "\n")
	defer delete(new_content)
	return safe_write_file(config_file, transmute([]byte)new_content)
}
