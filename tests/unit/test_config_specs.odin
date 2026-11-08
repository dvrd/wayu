package test_wayu

import "core:testing"
import "core:strings"
import wayu "../../src"

// ============================================================================
// Additional Parse Edge Cases
// ============================================================================

@(test)
test_parse_alias_line_no_quotes :: proc(t: ^testing.T) {
	_, ok := wayu.parse_alias_line("alias ll=ls")
	testing.expect(t, !ok, "Alias without quotes should be rejected")
}

@(test)
test_parse_constant_line_empty_name :: proc(t: ^testing.T) {
	_, ok := wayu.parse_constant_line(`export ="value"`)
	testing.expect(t, !ok, "Export with empty name should be rejected")
}

@(test)
test_parse_constant_line_spaces_in_value :: proc(t: ^testing.T) {
	entry, ok := wayu.parse_constant_line(`export MSG="hello world"`)
	testing.expect(t, ok, "Should parse constant with spaces in value")
	defer wayu.cleanup_entry(&entry)

	testing.expect_value(t, entry.name, "MSG")
	testing.expect_value(t, entry.value, "hello world")
}
