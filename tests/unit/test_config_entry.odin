package test_wayu

import wayu "../../src"
import "core:strings"
import "core:testing"

// ============================================================================
// parse_args_to_entry tests
// ============================================================================

@(test)
test_parse_args_to_path_entry :: proc(t: ^testing.T) {
	args := []string{"/usr/local/bin"}
	entry := wayu.parse_args_to_entry(&wayu.PATH_SPEC, args)
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.type, wayu.ConfigEntryType.PATH)
	testing.expect_value(t, entry.name, "/usr/local/bin")
	testing.expect_value(t, entry.value, "")
}

@(test)
test_parse_args_to_alias_entry :: proc(t: ^testing.T) {
	args := []string{"ll", "ls -la"}
	entry := wayu.parse_args_to_entry(&wayu.ALIAS_SPEC, args)
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.type, wayu.ConfigEntryType.ALIAS)
	testing.expect_value(t, entry.name, "ll")
	testing.expect_value(t, entry.value, "ls -la")
}

@(test)
test_parse_args_to_constant_entry :: proc(t: ^testing.T) {
	args := []string{"MY_VAR", "my_value"}
	entry := wayu.parse_args_to_entry(&wayu.CONSTANTS_SPEC, args)
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.type, wayu.ConfigEntryType.CONSTANT)
	testing.expect_value(t, entry.name, "MY_VAR")
	testing.expect_value(t, entry.value, "my_value")
}

@(test)
test_parse_args_to_alias_with_spaces :: proc(t: ^testing.T) {
	args := []string{"gc", "git", "commit", "-m"}
	entry := wayu.parse_args_to_entry(&wayu.ALIAS_SPEC, args)
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "gc")
	testing.expect_value(t, entry.value, "git commit -m")
}

@(test)
test_parse_args_to_entry_empty :: proc(t: ^testing.T) {
	args := []string{}
	entry := wayu.parse_args_to_entry(&wayu.PATH_SPEC, args)
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "")
}

// ============================================================================
// is_entry_complete tests
// ============================================================================

@(test)
test_is_entry_complete_path :: proc(t: ^testing.T) {
	complete := wayu.ConfigEntry {
		type  = .PATH,
		name  = "/usr/bin",
		value = "",
	}
	testing.expect(t, wayu.is_entry_complete(complete), "PATH with name should be complete")

	incomplete := wayu.ConfigEntry {
		type  = .PATH,
		name  = "",
		value = "",
	}
	testing.expect(
		t,
		!wayu.is_entry_complete(incomplete),
		"PATH without name should be incomplete",
	)
}

@(test)
test_is_entry_complete_alias :: proc(t: ^testing.T) {
	complete := wayu.ConfigEntry {
		type  = .ALIAS,
		name  = "ll",
		value = "ls -la",
	}
	testing.expect(t, wayu.is_entry_complete(complete), "Alias with name+value should be complete")

	no_value := wayu.ConfigEntry {
		type  = .ALIAS,
		name  = "ll",
		value = "",
	}
	testing.expect(
		t,
		!wayu.is_entry_complete(no_value),
		"Alias without value should be incomplete",
	)

	no_name := wayu.ConfigEntry {
		type  = .ALIAS,
		name  = "",
		value = "ls -la",
	}
	testing.expect(t, !wayu.is_entry_complete(no_name), "Alias without name should be incomplete")
}

@(test)
test_is_entry_complete_constant :: proc(t: ^testing.T) {
	complete := wayu.ConfigEntry {
		type  = .CONSTANT,
		name  = "MY_VAR",
		value = "hello",
	}
	testing.expect(
		t,
		wayu.is_entry_complete(complete),
		"Constant with name+value should be complete",
	)

	no_value := wayu.ConfigEntry {
		type  = .CONSTANT,
		name  = "MY_VAR",
		value = "",
	}
	testing.expect(
		t,
		!wayu.is_entry_complete(no_value),
		"Constant without value should be incomplete",
	)
}

// ============================================================================
// ConfigEntrySpec contract verification
// ============================================================================

@(test)
test_path_spec_fields :: proc(t: ^testing.T) {
	spec := &wayu.PATH_SPEC
	testing.expect_value(t, spec.type, wayu.ConfigEntryType.PATH)
	testing.expect_value(t, spec.display_name, "PATH")
	testing.expect_value(t, spec.fields_count, 1)
	testing.expect(t, spec.has_clean, "PATH should support clean")
	testing.expect(t, spec.has_dedup, "PATH should support dedup")
}

@(test)
test_alias_spec_fields :: proc(t: ^testing.T) {
	spec := &wayu.ALIAS_SPEC
	testing.expect_value(t, spec.type, wayu.ConfigEntryType.ALIAS)
	testing.expect_value(t, spec.display_name, "Alias")
	testing.expect_value(t, spec.fields_count, 2)
	testing.expect(t, !spec.has_clean, "Alias should not support clean")
	testing.expect(t, !spec.has_dedup, "Alias should not support dedup")
}

@(test)
test_constants_spec_fields :: proc(t: ^testing.T) {
	spec := &wayu.CONSTANTS_SPEC
	testing.expect_value(t, spec.type, wayu.ConfigEntryType.CONSTANT)
	testing.expect_value(t, spec.display_name, "Constant")
	testing.expect_value(t, spec.fields_count, 2)
	testing.expect(t, !spec.has_clean, "Constants should not support clean")
	testing.expect(t, !spec.has_dedup, "Constants should not support dedup")
}

// ============================================================================
// cleanup_entry memory safety
// ============================================================================

@(test)
test_cleanup_entry_with_empty_fields :: proc(t: ^testing.T) {
	entry := wayu.ConfigEntry {
		type  = .PATH,
		name  = "",
		value = "",
		line  = "",
	}
	wayu.cleanup_entry(&entry)
}

@(test)
test_cleanup_entry_with_allocated_fields :: proc(t: ^testing.T) {
	entry := wayu.ConfigEntry {
		type  = .ALIAS,
		name  = strings.clone("test_name"),
		value = strings.clone("test_value"),
		line  = strings.clone(`alias test_name="test_value"`),
	}
	wayu.cleanup_entry(&entry)
}
