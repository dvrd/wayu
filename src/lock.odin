// lock.odin - Lock file management for wayu
//
// This module implements the wayu.lock file system for tracking configuration
// integrity with SHA256 hashes. It provides generation, verification, and
// update operations for lock files.

package wayu

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// ============================================================================
// LOCK FILE CONSTANTS
// ============================================================================

LOCK_FILE_NAME :: "wayu.lock"
LOCK_VERSION   :: "1.0.0"

// ============================================================================
// LOCK FILE OPERATIONS
// ============================================================================

// Read a lock file from the given path
lock_read :: proc(path: string) -> (LockFile, bool) {
	lock := LockFile{}

	if !os.exists(path) {
		return lock, false
	}

	content, read_ok := safe_read_file(path)
	if !read_ok {
		return lock, false
	}
	defer delete(content)

	return parse_lock_file(string(content))
}

// Write a lock file to the given path
lock_write :: proc(path: string, lock: LockFile) -> bool {
	content := format_lock_file(lock)
	defer delete(content)

	write_ok := safe_write_file(path, transmute([]byte)content)
	return write_ok
}

// Generate SHA256 hash for a config entry
lock_generate_hash :: proc(entry: ConfigEntry) -> string {
	// Normalize the entry content for consistent hashing
	normalized := normalize_entry_for_hash(entry)
	defer delete(normalized)

	// Generate SHA256 hash using sha2 context
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)normalized)

	hash_bytes: [sha2.DIGEST_SIZE_256]byte
	sha2.final(&ctx, hash_bytes[:])

	// Encode to hex
	encoded, _ := hex.encode(hash_bytes[:])
	result := strings.clone(string(encoded))
	delete(encoded)
	return result
}

// Add an entry to the lock file
lock_add_entry :: proc(lock: ^LockFile, entry: LockEntry) -> bool {
	// Check if entry already exists
	for i := 0; i < len(lock.entries); i += 1 {
		if lock.entries[i].name == entry.name && lock.entries[i].type == entry.type {
			// Update existing entry - need to create new slice
			new_entries := make([]LockEntry, len(lock.entries))
			copy(new_entries, lock.entries)
			new_entries[i] = entry
			delete(lock.entries)
			lock.entries = new_entries
			return true
		}
	}

	// Add new entry - create new slice with one more element
	new_entries := make([]LockEntry, len(lock.entries) + 1)
	copy(new_entries, lock.entries)
	new_entries[len(lock.entries)] = entry
	delete(lock.entries)
	lock.entries = new_entries
	return true
}

// Remove an entry from the lock file.
//
// The removed entry's heap-allocated strings are freed here so the caller
// doesn't need to remember which entry it dropped. lock_add_entry takes
// ownership of the strings it receives, so this is the inverse.
lock_remove_entry :: proc(lock: ^LockFile, name: string, type: ConfigType) -> bool {
	for i := 0; i < len(lock.entries); i += 1 {
		if lock.entries[i].name == name && lock.entries[i].type == type {
			// Free the removed entry's owned strings first.
			removed := lock.entries[i]
			if len(removed.name)        > 0 do delete(removed.name)
			if len(removed.value)       > 0 do delete(removed.value)
			if len(removed.hash)        > 0 do delete(removed.hash)
			if len(removed.source)      > 0 do delete(removed.source)
			if len(removed.added_at)    > 0 do delete(removed.added_at)
			if len(removed.modified_at) > 0 do delete(removed.modified_at)

			// Remove by creating new slice without this element
			new_entries := make([]LockEntry, len(lock.entries) - 1)
			copy(new_entries[:i], lock.entries[:i])
			copy(new_entries[i:], lock.entries[i+1:])
			delete(lock.entries)
			lock.entries = new_entries
			return true
		}
	}
	return false
}

// Find an entry in the lock file
lock_find_entry :: proc(lock: LockFile, name: string, type: ConfigType) -> (LockEntry, bool) {
	for entry in lock.entries {
		if entry.name == name && entry.type == type {
			return entry, true
		}
	}
	return LockEntry{}, false
}

// ============================================================================
// LOCK FILE GENERATION
// ============================================================================

// Generate a complete lock file from current configuration
generate_lock_file :: proc() -> (LockFile, bool) {
	lock := LockFile{
		version      = LOCK_VERSION,
		generated_at = generate_rfc3339_timestamp(),
	}

	// Use dynamic array during building, then convert to slice
	entries := make([dynamic]LockEntry)
	defer delete(entries)

	// Generate PATH entries
	path_entries := read_config_entries(&PATH_SPEC)
	defer cleanup_entries(&path_entries)

	for entry in path_entries {
		lock_entry := config_entry_to_lock_entry(entry, .PATH)
		append(&entries, lock_entry)
	}

	// Generate alias entries
	alias_entries := read_config_entries(&ALIAS_SPEC)
	defer cleanup_entries(&alias_entries)

	for entry in alias_entries {
		lock_entry := config_entry_to_lock_entry(entry, .ALIAS)
		append(&entries, lock_entry)
	}

	// Generate constant entries
	const_entries := read_config_entries(&CONSTANTS_SPEC)
	defer cleanup_entries(&const_entries)

	for entry in const_entries {
		lock_entry := config_entry_to_lock_entry(entry, .CONSTANT)
		append(&entries, lock_entry)
	}

	// Generate completion entries
	completion_entries := read_completion_entries()
	defer cleanup_entries(&completion_entries)

	for entry in completion_entries {
		lock_entry := config_entry_to_lock_entry(entry, .COMPLETION)
		append(&entries, lock_entry)
	}

	// Convert dynamic array to slice for LockFile
	if len(entries) > 0 {
		lock.entries = make([]LockEntry, len(entries))
		copy(lock.entries, entries[:])
	}

	return lock, true
}

// Update the lock file with current configuration
update_lock_file :: proc() -> bool {
	lock_file_path := fmt.aprintf("%s/%s", WAYU_CONFIG, LOCK_FILE_NAME)
	defer delete(lock_file_path)

	// Ensure config directory exists
	if !os.exists(WAYU_CONFIG) {
		os.make_directory(WAYU_CONFIG)
	}

	lock, ok := generate_lock_file()
	if !ok {
		return false
	}
	defer free_lock_entries(&lock)

	return lock_write(lock_file_path, lock)
}

// ============================================================================
// LOCK VERIFICATION
// ============================================================================

// Verification result for a single entry
VerificationEntry :: struct {
	name:      string,
	type:      ConfigType,
	expected:  string,
	actual:    string,
	valid:     bool,
	message:   string,
}

// Complete verification result
VerificationResult :: struct {
	valid:     bool,
	passed:    int,
	failed:    int,
	missing:   int,
	extra:     int,
	entries:   []VerificationEntry,
}

// Verify the current configuration against the lock file
verify_lock_file :: proc() -> (VerificationResult, bool) {
	// Use dynamic array during building
	entries_dyn := make([dynamic]VerificationEntry)
	defer delete(entries_dyn)

	result := VerificationResult{
		valid = true,
	}

	lock_file_path := fmt.aprintf("%s/%s", WAYU_CONFIG, LOCK_FILE_NAME)
	defer delete(lock_file_path)

	// Check if lock file exists
	if !os.exists(lock_file_path) {
		result.valid = false
		return result, false
	}

	// Read lock file
	lock, lock_ok := lock_read(lock_file_path)
	if !lock_ok {
		result.valid = false
		return result, false
	}
	defer free_lock_entries(&lock)

	// Build map of current entries for efficient lookup
	current_entries := build_current_entry_map()
	defer delete(current_entries)

	// Verify each entry in lock file
	for lock_entry in lock.entries {
		verified := verify_single_entry(lock_entry, current_entries)
		append(&entries_dyn, verified)

		if verified.valid {
			result.passed += 1
		} else {
			result.failed += 1
			result.valid = false
		}

		// Mark as found
		key := fmt.tprintf("%s:%d", lock_entry.name, lock_entry.type)
		delete_key(&current_entries, key)
	}

	// Any remaining entries in current_entries are extra (not in lock file)
	for key, current in current_entries {
		append(&entries_dyn, VerificationEntry{
			name    = current.name,
			type    = current.type,
			valid   = false,
			message = "Entry not in lock file (extra)",
		})
		result.extra += 1
	}

	// Convert dynamic array to slice
	if len(entries_dyn) > 0 {
		result.entries = make([]VerificationEntry, len(entries_dyn))
		copy(result.entries, entries_dyn[:])
	}

	return result, true
}

// ============================================================================
// INTERNAL HELPERS
// ============================================================================

@(private="file")
config_entry_to_lock_entry :: proc(entry: ConfigEntry, type: ConfigType) -> LockEntry {
	hash := lock_generate_hash(entry)

	return LockEntry{
		type        = type,
		name        = strings.clone(entry.name),
		value       = strings.clone(entry.value),
		hash        = hash,
		source      = "manual",
		added_at    = generate_rfc3339_timestamp(),
		modified_at = generate_rfc3339_timestamp(),
		metadata    = make(map[string]string),
	}
}

@(private="file")
normalize_entry_for_hash :: proc(entry: ConfigEntry) -> string {
	// Normalize entry content for consistent hashing
	// Format: "TYPE:NAME:VALUE:LINE"
	return fmt.aprintf("%s:%s:%s:%s",
		entry.type,
		strings.trim_space(entry.name),
		strings.trim_space(entry.value),
		strings.trim_space(entry.line),
	)
}

@(private="file")
generate_rfc3339_timestamp :: proc() -> string {
	now := time.now()
	timestamp, _ := time.time_to_rfc3339(now, 0, false)
	return timestamp
}

@(private="file")
format_lock_file :: proc(lock: LockFile) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// Write header
	fmt.sbprintln(&builder, "# wayu.lock - Configuration lock file")
	fmt.sbprintf(&builder, "# Version: %s\n", lock.version)
	fmt.sbprintf(&builder, "# Generated: %s\n", lock.generated_at)
	fmt.sbprintln(&builder)

	fmt.sbprintf(&builder, "version = \"%s\"\n", lock.version)
	fmt.sbprintf(&builder, "generated_at = \"%s\"\n", lock.generated_at)
	fmt.sbprintln(&builder)

	// Write entries
	for entry, i in lock.entries {
		fmt.sbprintln(&builder, "[[entries]]")

		fmt.sbprintf(&builder, "type = \"%s\"\n", config_type_to_string(entry.type))
		fmt.sbprint(&builder, "name = \"")
		json_escape_into(&builder, entry.name)
		fmt.sbprintln(&builder, "\"")
		fmt.sbprintf(&builder, "hash = \"%s\"\n", entry.hash)
		fmt.sbprintf(&builder, "source = \"%s\"\n", entry.source)
		fmt.sbprintf(&builder, "added_at = \"%s\"\n", entry.added_at)
		fmt.sbprintf(&builder, "modified_at = \"%s\"\n", entry.modified_at)

		if len(entry.value) > 0 {
			fmt.sbprint(&builder, "value = \"")
			json_escape_into(&builder, entry.value)
			fmt.sbprintln(&builder, "\"")
		}

		// Write metadata if any
		if len(entry.metadata) > 0 {
			fmt.sbprintln(&builder, "[metadata]")
			for key, value in entry.metadata {
				fmt.sbprintf(&builder, "%s = \"", key)
				json_escape_into(&builder, value)
				fmt.sbprintln(&builder, "\"")
			}
		}

		fmt.sbprintln(&builder)
	}

	return strings.clone(strings.to_string(builder))
}

@(private="file")
parse_lock_file :: proc(content: string) -> (LockFile, bool) {
	lock := LockFile{
		version = LOCK_VERSION,
	}

	// Use dynamic array during parsing, then convert to slice
	entries := make([dynamic]LockEntry)
	defer delete(entries)

	lines := strings.split_lines(content)
	defer delete(lines)

	current_entry: LockEntry
	in_metadata := false

	for line in lines {
		trimmed := strings.trim_space(line)

		// Skip comments and empty lines
		if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") {
			continue
		}

		// Parse key = "value" format
		if strings.has_prefix(trimmed, "[[entries]]") {
			if current_entry.name != "" {
				append(&entries, current_entry)
				current_entry = LockEntry{}
			}
			in_metadata = false
			continue
		}

		if strings.has_prefix(trimmed, "[metadata]") {
			in_metadata = true
			if current_entry.metadata == nil {
				current_entry.metadata = make(map[string]string)
			}
			continue
		}

		// Parse key = value pairs (split on first '=' only)
		eq_idx := strings.index(trimmed, "=")
		if eq_idx < 0 {
			continue
		}

		key := strings.trim_space(trimmed[:eq_idx])
		value := strings.trim_space(trimmed[eq_idx+1:])

		// Remove quotes
		if strings.has_prefix(value, "\"") && strings.has_suffix(value, "\"") {
			value = value[1:len(value)-1]
		}

		if in_metadata {
			if current_entry.metadata == nil {
				current_entry.metadata = make(map[string]string)
			}
			current_entry.metadata[key] = value
		} else {
			switch key {
			case "version":
				lock.version = strings.clone(value)
			case "generated_at":
				lock.generated_at = strings.clone(value)
			case "type":
				current_entry.type = string_to_config_type(value)
			case "name":
				current_entry.name = strings.clone(value)
			case "value":
				current_entry.value = strings.clone(value)
			case "hash":
				current_entry.hash = strings.clone(value)
			case "source":
				current_entry.source = strings.clone(value)
			case "added_at":
				current_entry.added_at = strings.clone(value)
			case "modified_at":
				current_entry.modified_at = strings.clone(value)
			}
		}
	}

	// Don't forget the last entry
	if current_entry.name != "" {
		append(&entries, current_entry)
	}

	// Convert dynamic array to slice
	if len(entries) > 0 {
		lock.entries = make([]LockEntry, len(entries))
		copy(lock.entries, entries[:])
	}

	return lock, true
}

@(private="file")
config_type_to_string :: proc(t: ConfigType) -> string {
	switch t {
	case .PATH:        return "path"
	case .ALIAS:        return "alias"
	case .CONSTANT:     return "constant"
	case .PLUGIN:       return "plugin"
	case .COMPLETION:   return "completion"
	}
	return "unknown"
}

@(private="file")
string_to_config_type :: proc(s: string) -> ConfigType {
	switch s {
	case "path":        return .PATH
	case "alias":        return .ALIAS
	case "constant":     return .CONSTANT
	case "plugin":       return .PLUGIN
	case "completion":   return .COMPLETION
	}
	return .PATH
}

// Write `str` into the given builder with JSON-style escaping for ", \, \n,
// \t. Previously this function returned a heap-allocated clone and the
// call sites threw the result into fmt.sbprintf without freeing, leaking
// one allocation per serialized entry.
@(private="file")
json_escape_into :: proc(builder: ^strings.Builder, str: string) {
	for r in str {
		switch r {
		case '"':  strings.write_string(builder, "\\\"")
		case '\\': strings.write_string(builder, "\\\\")
		case '\n': strings.write_string(builder, "\\n")
		case '\t': strings.write_string(builder, "\\t")
		case:
			strings.write_rune(builder, r)
		}
	}
}

// Public wrapper so callers outside this file (e.g. unit tests) can clean
// up a LockFile returned by lock_read without having to remember every
// heap-allocated field.
lock_cleanup :: proc(lock: ^LockFile) {
	free_lock_entries(lock)
}

@(private="file")
free_lock_entries :: proc(lock: ^LockFile) {
	// Top-level fields cloned by parse_lock_file — parse them back on read,
	// free them on cleanup. Before this fix the two strings leaked on every
	// round-trip (reported at parse_lock_file:461 and :463 by the tracking
	// allocator).
	if len(lock.version) > 0 {
		delete(lock.version)
		lock.version = ""
	}
	if len(lock.generated_at) > 0 {
		delete(lock.generated_at)
		lock.generated_at = ""
	}

	for &entry in lock.entries {
		if entry.name != "" {
			delete(entry.name)
		}
		if entry.value != "" {
			delete(entry.value)
		}
		if entry.hash != "" {
			delete(entry.hash)
		}
		if entry.source != "" {
			delete(entry.source)
		}
		if entry.added_at != "" {
			delete(entry.added_at)
		}
		if entry.modified_at != "" {
			delete(entry.modified_at)
		}
		for key, value in entry.metadata {
			delete(key)
			delete(value)
		}
		delete(entry.metadata)
	}
	delete(lock.entries)
}

@(private="file")
build_current_entry_map :: proc() -> map[string]CurrentEntry {
	entries := make(map[string]CurrentEntry)

	// Add PATH entries
	path_entries := read_config_entries(&PATH_SPEC)
	defer cleanup_entries(&path_entries)

	for entry in path_entries {
		key := fmt.tprintf("%s:%d", entry.name, ConfigType.PATH)
		entries[key] = CurrentEntry{
			name  = entry.name,
			type  = .PATH,
			value = entry.value,
			hash  = lock_generate_hash(entry),
		}
	}

	// Add alias entries
	alias_entries := read_config_entries(&ALIAS_SPEC)
	defer cleanup_entries(&alias_entries)

	for entry in alias_entries {
		key := fmt.tprintf("%s:%d", entry.name, ConfigType.ALIAS)
		entries[key] = CurrentEntry{
			name  = entry.name,
			type  = .ALIAS,
			value = entry.value,
			hash  = lock_generate_hash(entry),
		}
	}

	// Add constant entries
	const_entries := read_config_entries(&CONSTANTS_SPEC)
	defer cleanup_entries(&const_entries)

	for entry in const_entries {
		key := fmt.tprintf("%s:%d", entry.name, ConfigType.CONSTANT)
		entries[key] = CurrentEntry{
			name  = entry.name,
			type  = .CONSTANT,
			value = entry.value,
			hash  = lock_generate_hash(entry),
		}
	}

	return entries
}

@(private="file")
CurrentEntry :: struct {
	name:  string,
	type:  ConfigType,
	value: string,
	hash:  string,
}

@(private="file")
verify_single_entry :: proc(lock_entry: LockEntry, current_map: map[string]CurrentEntry) -> VerificationEntry {
	key := fmt.tprintf("%s:%d", lock_entry.name, lock_entry.type)

	current, found := current_map[key]
	if !found {
		return VerificationEntry{
			name    = lock_entry.name,
			type    = lock_entry.type,
			expected = lock_entry.hash,
			actual  = "",
			valid   = false,
			message = "Entry not found in current configuration",
		}
	}

	if current.hash != lock_entry.hash {
		return VerificationEntry{
			name     = lock_entry.name,
			type     = lock_entry.type,
			expected = lock_entry.hash,
			actual   = current.hash,
			valid    = false,
			message  = "Hash mismatch - entry has been modified",
		}
	}

	return VerificationEntry{
		name     = lock_entry.name,
		type     = lock_entry.type,
		expected = lock_entry.hash,
		actual   = current.hash,
		valid    = true,
		message  = "OK",
	}
}

// ============================================================================
// COMPLETION ENTRIES HELPER
// ============================================================================

@(private="file")
read_completion_entries :: proc() -> []ConfigEntry {
	config_file := fmt.aprintf("%s/completions.%s", WAYU_CONFIG, SHELL_EXT)
	defer delete(config_file)

	if !os.exists(config_file) {
		return nil
	}

	content, read_ok := safe_read_file(config_file)
	if !read_ok {
		return nil
	}
	defer delete(content)

	entries := make([dynamic]ConfigEntry)
	defer delete(entries)

	lines := strings.split_lines(string(content))
	defer delete(lines)

	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") {
			continue
		}

		// Parse completion line: fpath+=("/path/to/_completion")
		if strings.has_prefix(trimmed, "fpath+=(") {
			start := strings.index(trimmed, "\"")
			if start >= 0 {
				end := strings.index(trimmed[start+1:], "\"")
				if end >= 0 {
					name := trimmed[start+1:start+1+end]
					append(&entries, ConfigEntry{
						type  = .PATH,  // Store as PATH type for ConfigEntry
						name  = strings.clone(name),
						value = "",
						line  = strings.clone(line),
					})
				}
			}
		}
	}

	result := make([]ConfigEntry, len(entries))
	copy(result, entries[:])
	return result
}
