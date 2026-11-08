// lock.odin - Lock file management for wayu
//
// Reads wayu.lock for integrity tracking (used by hot_reload and static_gen).
// Write, update, and verify logic was removed as dead code (only lock_read
// had external callers). lock_cleanup is kept as the public cleanup API
// for callers that receive a LockFile from lock_read.

package wayu

import "core:os"
import "core:strings"

LOCK_VERSION   :: "1.0.0"

// Read a lock file from the given path.
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

// Parse a lock file from its text content.
@(private="file")
parse_lock_file :: proc(content: string) -> (LockFile, bool) {
	// Every string in the returned LockFile is owned (freed by lock_cleanup),
	// including the default version.
	lock := LockFile{
		version = strings.clone(LOCK_VERSION),
	}

	entries := make([dynamic]LockEntry)
	defer delete(entries)

	lines := strings.split_lines(content)
	defer delete(lines)

	current_entry: LockEntry
	in_metadata := false

	for line in lines {
		trimmed := strings.trim_space(line)

		if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") {
			continue
		}

		if strings.has_prefix(trimmed, "[[entries]]") {
			// Each [[entries]] starts a fresh entry. One without a name is
			// dropped (freed), so its fields never bleed into the next.
			if current_entry.name != "" {
				append(&entries, current_entry)
			} else {
				free_lock_entry(&current_entry)
			}
			current_entry = LockEntry{}
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

		eq_idx := strings.index(trimmed, "=")
		if eq_idx < 0 {
			continue
		}

		key := strings.trim_space(trimmed[:eq_idx])
		value := strings.trim_space(trimmed[eq_idx+1:])

		if strings.has_prefix(value, "\"") && strings.has_suffix(value, "\"") {
			value = value[1:len(value)-1]
		}

		if in_metadata {
			if current_entry.metadata == nil {
				current_entry.metadata = make(map[string]string)
			}
			// Keys/values point into `content`, which the caller frees —
			// clone both. On a duplicate key, replace the old value.
			if key in current_entry.metadata {
				old_key, old_val := delete_key(&current_entry.metadata, key)
				delete(old_key)
				delete(old_val)
			}
			current_entry.metadata[strings.clone(key)] = strings.clone(value)
		} else {
			switch key {
			case "version":
				replace_owned_string(&lock.version, value)
			case "generated_at":
				replace_owned_string(&lock.generated_at, value)
			case "type":
				current_entry.type = string_to_config_type(value)
			case "name":
				replace_owned_string(&current_entry.name, value)
			case "value":
				replace_owned_string(&current_entry.value, value)
			case "hash":
				replace_owned_string(&current_entry.hash, value)
			case "source":
				replace_owned_string(&current_entry.source, value)
			case "added_at":
				replace_owned_string(&current_entry.added_at, value)
			case "modified_at":
				replace_owned_string(&current_entry.modified_at, value)
			}
		}
	}

	if current_entry.name != "" {
		append(&entries, current_entry)
	} else {
		free_lock_entry(&current_entry)
	}

	if len(entries) > 0 {
		lock.entries = make([]LockEntry, len(entries))
		copy(lock.entries, entries[:])
	}

	return lock, true
}

// Free the previous owned value (if any) and store a clone of `value`.
@(private="file")
replace_owned_string :: proc(field: ^string, value: string) {
	if len(field^) > 0 {
		delete(field^)
	}
	field^ = strings.clone(value)
}

@(private="file")
string_to_config_type :: proc(s: string) -> ConfigType {
	switch s {
	case "path":       return .PATH
	case "alias":      return .ALIAS
	case "constant":   return .CONSTANT
	case "plugin":     return .PLUGIN
	case "completion": return .COMPLETION
	}
	return .PATH
}

// Public cleanup wrapper so callers outside this file can free a LockFile
// returned by lock_read without knowing every heap-allocated field.
lock_cleanup :: proc(lock: ^LockFile) {
	free_lock_entries(lock)
}

@(private="file")
free_lock_entries :: proc(lock: ^LockFile) {
	if len(lock.version) > 0 {
		delete(lock.version)
		lock.version = ""
	}
	if len(lock.generated_at) > 0 {
		delete(lock.generated_at)
		lock.generated_at = ""
	}

	for &entry in lock.entries { free_lock_entry(&entry) }
	delete(lock.entries)
}

@(private="file")
free_lock_entry :: proc(entry: ^LockEntry) {
	if entry.name != ""        do delete(entry.name)
	if entry.value != ""       do delete(entry.value)
	if entry.hash != ""        do delete(entry.hash)
	if entry.source != ""      do delete(entry.source)
	if entry.added_at != ""    do delete(entry.added_at)
	if entry.modified_at != "" do delete(entry.modified_at)
	for key, value in entry.metadata {
		delete(key)
		delete(value)
	}
	delete(entry.metadata)
	entry^ = {}
}
