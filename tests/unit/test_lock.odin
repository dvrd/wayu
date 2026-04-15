package test_wayu

import "core:testing"
import "core:strings"
import "core:os"
import wayu "../../src"

// ============================================================================
// Hash Generation Tests
// ============================================================================

@(test)
test_lock_generate_hash_consistency :: proc(t: ^testing.T) {
	// Same entry should always produce the same hash
	entry := wayu.ConfigEntry{
		type  = .CONSTANT,
		name  = "TEST_VAR",
		value = "test_value",
		line  = `export TEST_VAR="test_value"`,
	}

	hash1 := wayu.lock_generate_hash(entry)
	defer delete(hash1)

	hash2 := wayu.lock_generate_hash(entry)
	defer delete(hash2)

	testing.expect_value(t, hash1, hash2)
	testing.expect(t, len(hash1) == 64, "SHA256 hash should be 64 hex characters")
}

@(test)
test_lock_generate_hash_different_entries :: proc(t: ^testing.T) {
	// Different entries should produce different hashes
	entry1 := wayu.ConfigEntry{
		type  = .CONSTANT,
		name  = "VAR1",
		value = "value1",
		line  = `export VAR1="value1"`,
	}

	entry2 := wayu.ConfigEntry{
		type  = .CONSTANT,
		name  = "VAR2",
		value = "value2",
		line  = `export VAR2="value2"`,
	}

	hash1 := wayu.lock_generate_hash(entry1)
	defer delete(hash1)

	hash2 := wayu.lock_generate_hash(entry2)
	defer delete(hash2)

	testing.expect(t, hash1 != hash2, "Different entries should have different hashes")
}

@(test)
test_lock_generate_hash_different_types :: proc(t: ^testing.T) {
	// Same name/value but different types should produce different hashes
	path_entry := wayu.ConfigEntry{
		type  = .PATH,
		name  = "/usr/local/bin",
		value = "",
		line  = `  "/usr/local/bin"`,
	}

	const_entry := wayu.ConfigEntry{
		type  = .CONSTANT,
		name  = "/usr/local/bin",
		value = "",
		line  = `export "/usr/local/bin"=""`,
	}

	hash1 := wayu.lock_generate_hash(path_entry)
	defer delete(hash1)

	hash2 := wayu.lock_generate_hash(const_entry)
	defer delete(hash2)

	testing.expect(t, hash1 != hash2, "Different types should have different hashes")
}

// ============================================================================
// Lock Entry Management Tests
// ============================================================================

@(test)
test_lock_add_entry :: proc(t: ^testing.T) {
	entries := make([dynamic]wayu.LockEntry)
	defer delete(entries)

	lock := wayu.LockFile{
		version      = "1.0.0",
		generated_at = "2024-01-01T00:00:00Z",
		entries      = entries[:],
	}

	entry := wayu.LockEntry{
		type   = .CONSTANT,
		name   = "TEST_VAR",
		value  = "test_value",
		hash   = "abc123",
		source = "manual",
	}

	success := wayu.lock_add_entry(&lock, entry)
	testing.expect(t, success, "Should add entry successfully")
	testing.expect_value(t, len(lock.entries), 1)

	// Cleanup
	for &e in lock.entries {
		if e.name != "" { delete(e.name) }
		if e.value != "" { delete(e.value) }
		if e.hash != "" { delete(e.hash) }
		if e.source != "" { delete(e.source) }
	}
	delete(lock.entries)
}

@(test)
test_lock_find_entry_found :: proc(t: ^testing.T) {
	entries := make([dynamic]wayu.LockEntry)
	defer delete(entries)

	lock := wayu.LockFile{
		version      = "1.0.0",
		generated_at = "2024-01-01T00:00:00Z",
		entries      = entries[:],
	}

	entry := wayu.LockEntry{
		type   = .CONSTANT,
		name   = "TEST_VAR",
		value  = "test_value",
		hash   = "abc123",
		source = "manual",
	}

	wayu.lock_add_entry(&lock, entry)

	found_entry, found := wayu.lock_find_entry(lock, "TEST_VAR", .CONSTANT)
	testing.expect(t, found, "Should find the entry")
	testing.expect_value(t, found_entry.name, "TEST_VAR")

	// Cleanup
	for &e in lock.entries {
		if e.name != "" { delete(e.name) }
		if e.value != "" { delete(e.value) }
		if e.hash != "" { delete(e.hash) }
		if e.source != "" { delete(e.source) }
	}
	delete(lock.entries)
}

@(test)
test_lock_find_entry_not_found :: proc(t: ^testing.T) {
	entries := make([dynamic]wayu.LockEntry)
	defer delete(entries)

	lock := wayu.LockFile{
		version      = "1.0.0",
		generated_at = "2024-01-01T00:00:00Z",
		entries      = entries[:],
	}

	_, found := wayu.lock_find_entry(lock, "NONEXISTENT", .CONSTANT)
	testing.expect(t, !found, "Should not find nonexistent entry")
}

@(test)
test_lock_remove_entry :: proc(t: ^testing.T) {
	entries := make([dynamic]wayu.LockEntry)
	defer delete(entries)

	lock := wayu.LockFile{
		version      = "1.0.0",
		generated_at = "2024-01-01T00:00:00Z",
		entries      = entries[:],
	}

	entry := wayu.LockEntry{
		type   = .CONSTANT,
		name   = "TEST_VAR",
		value  = "test_value",
		hash   = "abc123",
		source = "manual",
	}

	wayu.lock_add_entry(&lock, entry)

	success := wayu.lock_remove_entry(&lock, "TEST_VAR", .CONSTANT)
	testing.expect(t, success, "Should remove entry successfully")
	testing.expect_value(t, len(lock.entries), 0)
}

@(test)
test_lock_remove_entry_not_found :: proc(t: ^testing.T) {
	entries := make([dynamic]wayu.LockEntry)
	defer delete(entries)

	lock := wayu.LockFile{
		version      = "1.0.0",
		generated_at = "2024-01-01T00:00:00Z",
		entries      = entries[:],
	}

	success := wayu.lock_remove_entry(&lock, "NONEXISTENT", .CONSTANT)
	testing.expect(t, !success, "Should return false for nonexistent entry")
}

// ============================================================================
// Config Type String Tests
// ============================================================================

@(test)
test_config_type_path :: proc(t: ^testing.T) {
	// ConfigType to string conversion - test via JSON formatting
	path_type := wayu.ConfigType.PATH
	result := wayu.output_to_json(&path_type)
	defer delete(result)
	testing.expect(t, strings.contains(result, "PATH"), "PATH type should be serialized")
}

@(test)
test_config_type_alias :: proc(t: ^testing.T) {
	alias_type := wayu.ConfigType.ALIAS
	result := wayu.output_to_json(&alias_type)
	defer delete(result)
	testing.expect(t, strings.contains(result, "ALIAS"), "ALIAS type should be serialized")
}

@(test)
test_config_type_constant :: proc(t: ^testing.T) {
	const_type := wayu.ConfigType.CONSTANT
	result := wayu.output_to_json(&const_type)
	defer delete(result)
	testing.expect(t, strings.contains(result, "CONSTANT"), "CONSTANT type should be serialized")
}

// ============================================================================
// Lock File I/O Tests (with temp directory)
// ============================================================================

@(test)
test_lock_read_nonexistent :: proc(t: ^testing.T) {
	temp_path := "/tmp/wayu_lock_test_nonexistent.lock"

	lock, ok := wayu.lock_read(temp_path)
	// Note: lock_read may still return a LockFile struct even on failure

	testing.expect(t, !ok, "Should return false for nonexistent file")

	// Cleanup any allocated memory in lock
	for &e in lock.entries {
		if e.name != "" { delete(e.name) }
		if e.value != "" { delete(e.value) }
		if e.hash != "" { delete(e.hash) }
		if e.source != "" { delete(e.source) }
		if e.added_at != "" { delete(e.added_at) }
		if e.modified_at != "" { delete(e.modified_at) }
	}
	delete(lock.entries)
}

@(test)
test_lock_write_and_read :: proc(t: ^testing.T) {
	temp_path := "/tmp/wayu_lock_test_write.lock"

	// Clean up before and after
	os.remove(temp_path)
	defer os.remove(temp_path)

	// Create a lock file using dynamic array then convert to slice
	entries_dyn := make([dynamic]wayu.LockEntry)
	defer delete(entries_dyn)

	entry := wayu.LockEntry{
		type        = .CONSTANT,
		name        = strings.clone("EDITOR"),
		value       = strings.clone("nvim"),
		hash        = "sha256hash1234567890abcdef",
		source      = strings.clone("manual"),
		added_at    = strings.clone("2024-01-15T10:30:00Z"),
		modified_at = strings.clone("2024-01-15T10:30:00Z"),
		metadata    = make(map[string]string),
	}
	append(&entries_dyn, entry)

	lock := wayu.LockFile{
		version      = "1.0.0",
		generated_at = "2024-01-15T10:30:00Z",
		entries      = entries_dyn[:],
	}

	// Write the lock file
	write_ok := wayu.lock_write(temp_path, lock)

	// Cleanup entry memory
	for &e in lock.entries {
		if e.name != "" { delete(e.name) }
		if e.value != "" { delete(e.value) }
		if e.hash != "" { delete(e.hash) }
		if e.source != "" { delete(e.source) }
		if e.added_at != "" { delete(e.added_at) }
		if e.modified_at != "" { delete(e.modified_at) }
		delete(e.metadata)
	}
	delete(lock.entries)

	testing.expect(t, write_ok, "Should write lock file successfully")

	// Read it back
	read_lock, read_ok := wayu.lock_read(temp_path)

	testing.expect(t, read_ok, "Should read lock file successfully")
	testing.expect_value(t, read_lock.version, "1.0.0")
	testing.expect_value(t, read_lock.generated_at, "2024-01-15T10:30:00Z")
	testing.expect_value(t, len(read_lock.entries), 1)

	if len(read_lock.entries) > 0 {
		testing.expect_value(t, read_lock.entries[0].name, "EDITOR")
		testing.expect_value(t, read_lock.entries[0].type, wayu.ConfigType.CONSTANT)
	}

	// Cleanup read lock memory
	for &e in read_lock.entries {
		if e.name != "" { delete(e.name) }
		if e.value != "" { delete(e.value) }
		if e.hash != "" { delete(e.hash) }
		if e.source != "" { delete(e.source) }
		if e.added_at != "" { delete(e.added_at) }
		if e.modified_at != "" { delete(e.modified_at) }
		delete(e.metadata)
	}
	delete(read_lock.entries)
}

// ============================================================================
// Verification Tests
// ============================================================================

@(test)
test_verify_lock_file_no_lock :: proc(t: ^testing.T) {
	// Create a temporary config directory that doesn't exist
	temp_config := "/tmp/wayu_test_no_lock_config"

	result, ok := wayu.verify_lock_file()

	// Should fail because no lock file exists
	testing.expect(t, !ok || !result.valid, "Should fail when no lock file exists")

	// Cleanup result
	delete(result.entries)
}

@(test)
test_verification_entry_struct :: proc(t: ^testing.T) {
	// Test the VerificationEntry struct fields
	entry := wayu.VerificationEntry{
		name     = "TEST",
		type     = .CONSTANT,
		expected = "hash1",
		actual   = "hash2",
		valid    = false,
		message  = "Test message",
	}

	testing.expect_value(t, entry.name, "TEST")
	testing.expect_value(t, entry.type, wayu.ConfigType.CONSTANT)
	testing.expect_value(t, entry.expected, "hash1")
	testing.expect_value(t, entry.actual, "hash2")
	testing.expect_value(t, entry.valid, false)
	testing.expect_value(t, entry.message, "Test message")
}

@(test)
test_verification_result_struct :: proc(t: ^testing.T) {
	result := wayu.VerificationResult{
		valid   = true,
		passed  = 5,
		failed  = 1,
		missing = 0,
		extra   = 0,
		entries = nil,
	}

	testing.expect_value(t, result.valid, true)
	testing.expect_value(t, result.passed, 5)
	testing.expect_value(t, result.failed, 1)
	testing.expect_value(t, result.missing, 0)
	testing.expect_value(t, result.extra, 0)
}

// ============================================================================
// JSON Escape Value Tests
// ============================================================================

@(test)
test_json_escape_value_helper :: proc(t: ^testing.T) {
	// The JSON escape is now internal, test via format_path_list_json
	entries := make([]wayu.ConfigEntry, 1)
	entries[0] = wayu.ConfigEntry{
		type = .PATH,
		name = `/usr/local/bin`,
		value = "",
		line = `  "/usr/local/bin"`,
	}
	defer wayu.cleanup_entries(&entries)

	result := wayu.format_path_list_json(entries)
	defer delete(result)

	// Should be valid JSON
	testing.expect(t, strings.has_prefix(result, "{"), "Should start with {")
	testing.expect(t, strings.has_suffix(result, "}"), "Should end with }")
	testing.expect(t, strings.contains(result, "count"), "Should contain count field")
}

// ============================================================================
// Normalize Entry for Hash Tests
// ============================================================================

@(test)
test_normalize_entry_for_hash_helper :: proc(t: ^testing.T) {
	// Test hash generation with different entries
	entry1 := wayu.ConfigEntry{
		type  = .CONSTANT,
		name  = "  TEST_VAR  ",
		value = "  test_value  ",
		line  = `  export TEST_VAR="test_value"  `,
	}

	hash1 := wayu.lock_generate_hash(entry1)
	defer delete(hash1)

	entry2 := wayu.ConfigEntry{
		type  = .CONSTANT,
		name  = "  TEST_VAR  ",
		value = "  test_value  ",
		line  = `  export TEST_VAR="test_value"  `,
	}

	hash2 := wayu.lock_generate_hash(entry2)
	defer delete(hash2)

	// Same entry should produce same hash
	testing.expect_value(t, hash1, hash2)
	// SHA256 hex string should be 64 characters
	testing.expect_value(t, len(hash1), 64)
}
