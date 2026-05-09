// lock.odin - Lock file management for wayu
//
// Reads wayu.lock for integrity tracking (used by hot_reload and static_gen).
// Write, update, and verify logic was removed as dead code (only lock_read
// had external callers). lock_cleanup is kept as the public cleanup API
// for callers that receive a LockFile from lock_read.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

LOCK_FILE_NAME :: "wayu.lock"
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
	lock := LockFile{
		version = LOCK_VERSION,
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

	if current_entry.name != "" {
		append(&entries, current_entry)
	}

	if len(entries) > 0 {
		lock.entries = make([]LockEntry, len(entries))
		copy(lock.entries, entries[:])
	}

	return lock, true
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

	for &entry in lock.entries {
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
	}
	delete(lock.entries)
}
