// test_validation.odin - Tests for input validation module

package test_wayu

import "core:testing"
import wayu "../src"

@(test)
test_validate_identifier_valid :: proc(t: ^testing.T) {
	result := wayu.validate_identifier("my_alias", "Alias")
	testing.expect(t, result.valid, "Valid identifier should pass")

	result2 := wayu.validate_identifier("MY_CONST", "Constant")
	testing.expect(t, result2.valid, "Valid constant should pass")

	result3 := wayu.validate_identifier("_private", "Alias")
	testing.expect(t, result3.valid, "Underscore prefix should be valid")
}

@(test)
test_validate_identifier_empty :: proc(t: ^testing.T) {
	result := wayu.validate_identifier("", "Alias")
	testing.expect(t, !result.valid, "Empty name should fail")
	testing.expect(t, len(result.error_message) > 0, "Should have error message")
}

@(test)
test_validate_identifier_invalid_start :: proc(t: ^testing.T) {
	result := wayu.validate_identifier("123abc", "Alias")
	testing.expect(t, !result.valid, "Name starting with digit should fail")

	result2 := wayu.validate_identifier("-alias", "Alias")
	testing.expect(t, !result2.valid, "Name starting with dash should fail")
}

@(test)
test_validate_identifier_invalid_chars :: proc(t: ^testing.T) {
	result := wayu.validate_identifier("my-alias", "Alias")
	testing.expect(t, !result.valid, "Name with dash should fail")

	result2 := wayu.validate_identifier("my.alias", "Alias")
	testing.expect(t, !result2.valid, "Name with dot should fail")

	result3 := wayu.validate_identifier("my alias", "Alias")
	testing.expect(t, !result3.valid, "Name with space should fail")
}

@(test)
test_validate_identifier_reserved :: proc(t: ^testing.T) {
	result := wayu.validate_identifier("if", "Alias")
	testing.expect(t, !result.valid, "Reserved word 'if' should fail")

	result2 := wayu.validate_identifier("export", "Constant")
	testing.expect(t, !result2.valid, "Reserved word 'export' should fail")
}

@(test)
test_sanitize_shell_value :: proc(t: ^testing.T) {
	// Test double quote escaping
	result := wayu.sanitize_shell_value("echo \"hello\"")
	expected := "echo \\\"hello\\\""
	testing.expect_value(t, result, expected)
	defer delete(result)

	// Test backtick escaping
	result2 := wayu.sanitize_shell_value("echo `date`")
	expected2 := "echo \\`date\\`"
	testing.expect_value(t, result2, expected2)
	defer delete(result2)

	// Test dollar sign escaping
	result3 := wayu.sanitize_shell_value("echo $HOME")
	expected3 := "echo \\$HOME"
	testing.expect_value(t, result3, expected3)
	defer delete(result3)
}

@(test)
test_validate_alias :: proc(t: ^testing.T) {
	result := wayu.validate_alias("ll", "ls -la")
	testing.expect(t, result.valid, "Valid alias should pass")

	result2 := wayu.validate_alias("ll", "")
	testing.expect(t, !result2.valid, "Empty command should fail")

	result3 := wayu.validate_alias("", "ls -la")
	testing.expect(t, !result3.valid, "Empty name should fail")
}

@(test)
test_validate_constant :: proc(t: ^testing.T) {
	result := wayu.validate_constant("MY_VAR", "value")
	testing.expect(t, result.valid, "Valid constant should pass")

	// Lowercase warning but still valid
	result2 := wayu.validate_constant("my_var", "value")
	testing.expect(t, result2.valid, "Lowercase constant should still be valid")
}

@(test)
test_validate_path :: proc(t: ^testing.T) {
	result := wayu.validate_path("/usr/local/bin")
	testing.expect(t, result.valid, "Valid path should pass")

	result2 := wayu.validate_path("")
	testing.expect(t, !result2.valid, "Empty path should fail")

	result3 := wayu.validate_path("   ")
	testing.expect(t, !result3.valid, "Whitespace-only path should fail")
}

@(test)
test_validate_identifier_long_name :: proc(t: ^testing.T) {
	// Create a name that's exactly 255 characters (should pass)
	long_name := make([]byte, 255)
	defer delete(long_name)
	for i in 0 ..< 255 {
		long_name[i] = 'a'
	}
	result := wayu.validate_identifier(string(long_name), "Alias")
	testing.expect(t, result.valid, "255 character name should pass")

	// Create a name that's 256 characters (should fail)
	too_long := make([]byte, 256)
	defer delete(too_long)
	for i in 0 ..< 256 {
		too_long[i] = 'a'
	}
	result2 := wayu.validate_identifier(string(too_long), "Alias")
	testing.expect(t, !result2.valid, "256 character name should fail")
}
