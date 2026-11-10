// test_validation.odin - Tests for input validation module

package test_wayu

import wayu "../../src"
import "core:testing"

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
	defer delete(result.error_message)
	testing.expect(t, !result.valid, "Empty name should fail")
	testing.expect(t, len(result.error_message) > 0, "Should have error message")
}

@(test)
test_validate_identifier_invalid_start :: proc(t: ^testing.T) {
	result := wayu.validate_identifier("123abc", "Alias")
	defer delete(result.error_message)
	testing.expect(t, !result.valid, "Name starting with digit should fail")

	result2 := wayu.validate_identifier("-alias", "Alias")
	defer delete(result2.error_message)
	testing.expect(t, !result2.valid, "Name starting with dash should fail")
}

@(test)
test_validate_identifier_invalid_chars :: proc(t: ^testing.T) {
	result := wayu.validate_identifier("my-alias", "Constant")
	defer delete(result.error_message)
	testing.expect(t, !result.valid, "Name with dash should fail unless allowed")

	result2 := wayu.validate_identifier("my.alias", "Alias")
	defer delete(result2.error_message)
	testing.expect(t, !result2.valid, "Name with dot should fail")

	result3 := wayu.validate_identifier("my alias", "Alias")
	defer delete(result3.error_message)
	testing.expect(t, !result3.valid, "Name with space should fail")
}

@(test)
test_validate_identifier_reserved :: proc(t: ^testing.T) {
	result := wayu.validate_identifier("if", "Alias")
	defer delete(result.error_message)
	testing.expect(t, !result.valid, "Reserved word 'if' should fail")

	result2 := wayu.validate_identifier("export", "Constant")
	defer delete(result2.error_message)
	testing.expect(t, !result2.valid, "Reserved word 'export' should fail")
}

@(test)
test_validate_alias :: proc(t: ^testing.T) {
	result := wayu.validate_alias("ll", "ls -la")
	testing.expect(t, result.valid, "Valid alias should pass")

	result2 := wayu.validate_alias("ll", "")
	defer delete(result2.error_message)
	testing.expect(t, !result2.valid, "Empty command should fail")

	result3 := wayu.validate_alias("", "ls -la")
	defer delete(result3.error_message)
	testing.expect(t, !result3.valid, "Empty name should fail")
}

@(test)
test_validate_constant :: proc(t: ^testing.T) {
	result := wayu.validate_constant("MY_VAR", "value")
	testing.expect(t, result.valid, "Valid constant should pass")
	testing.expect_value(t, result.warning, "")

	// Lowercase produces a warning but is still valid — caller prints, not the validator
	result2 := wayu.validate_constant("my_var", "value")
	testing.expect(t, result2.valid, "Lowercase constant should still be valid")
	testing.expect(t, len(result2.warning) > 0, "Lowercase constant should produce a warning")
	defer delete(result2.warning)
}

@(test)
test_validate_path :: proc(t: ^testing.T) {
	result := wayu.validate_path("/usr/local/bin")
	testing.expect(t, result.valid, "Valid path should pass")

	result2 := wayu.validate_path("")
	defer delete(result2.error_message)
	testing.expect(t, !result2.valid, "Empty path should fail")

	result3 := wayu.validate_path("   ")
	defer delete(result3.error_message)
	testing.expect(t, !result3.valid, "Whitespace-only path should fail")
}

// OKAMI-214: ':' would split into extra (even relative) PATH entries and a
// newline breaks the generated line-oriented files.
@(test)
test_validate_path_rejects_separator_and_newline :: proc(t: ^testing.T) {
	for bad in ([]string{"/x/a:.", "/x/co:lon", ":", "/x/a\nb", "/x/a\rb"}) {
		r := wayu.validate_path(bad)
		defer delete(r.error_message)
		testing.expectf(t, !r.valid, "%q should be rejected", bad)
	}
	ok := wayu.validate_path("/x/with space/and-$VAR")
	testing.expect(t, ok.valid, "spaces and $VAR stay allowed")
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
	defer delete(result2.error_message)
	testing.expect(t, !result2.valid, "256 character name should fail")
}

@(test)
test_validate_identifier_rejects_non_ascii :: proc(t: ^testing.T) {
	for name in ([]string{"café", "naïve_x", "ñ", "x y"}) {
		result := wayu.validate_identifier(name, "Alias")
		testing.expectf(t, !result.valid, "non-ASCII name %q must be rejected", name)
		delete(result.error_message)
	}
	ok := wayu.validate_identifier("Ok_Name_9", "Alias")
	testing.expect(t, ok.valid)
}

@(test)
test_validate_alias_allows_inner_hyphen :: proc(t: ^testing.T) {
	ok := wayu.validate_alias("onlead-logs", "echo hi")
	defer delete(ok.error_message)
	testing.expect(t, ok.valid, "alias name with an inner hyphen is valid")

	lead := wayu.validate_alias("-x", "echo hi")
	defer delete(lead.error_message)
	testing.expect(t, !lead.valid, "alias name starting with '-' is rejected")

	c := wayu.validate_constant("MY-VAR", "v")
	defer delete(c.error_message)
	testing.expect(t, !c.valid, "constant names still reject hyphens")

	f := wayu.validate_identifier("my-fn", "Function")
	defer delete(f.error_message)
	testing.expect(t, !f.valid, "function names still reject hyphens")
}

// OKAMI-366: one alias name rule; every name it accepts is one the
// generator emits (is_safe_alias_name).
@(test)
test_alias_name_error_shared_rule :: proc(t: ^testing.T) {
	for n in ([]string {
			"..",
			"g.st",
			"1x",
			"k8s-ctx",
			"ll",
			"_x",
			"a+b",
			"@x",
			"cd",
			"ls",
			"cat",
			"echo",
			"test",
		}) {
		testing.expectf(t, wayu.alias_name_error(n) == "", "%s should be valid", n)
		testing.expectf(t, wayu.is_safe_alias_name(n), "%s must be emittable", n)
	}
	for n in ([]string {
			"",
			"-x",
			"a b",
			"a/b",
			"a^b",
			"a=b",
			"a$b",
			".",
			"if",
			"done",
			"local",
			"export",
			"café",
			"a\x00b",
		}) {
		testing.expectf(t, wayu.alias_name_error(n) != "", "%q should be invalid", n)
	}
}

// OKAMI-304: protected environment names.
@(test)
test_protected_env_names :: proc(t: ^testing.T) {
	for n in ([]string{"PATH", "path", "HOME", "IFS", "ZDOTDIR", "WAYU_DATA_DIR", "WAYU_X"}) {
		testing.expectf(t, wayu.protected_env_name_error(n) != "", "%s should be protected", n)
	}
	for n in ([]string{"EDITOR", "GOPATH", "PATHX", "WAYU"}) {
		testing.expectf(t, wayu.protected_env_name_error(n) == "", "%s should be allowed", n)
	}
}

// OKAMI-331: NUL and invalid UTF-8 values are data errors.
@(test)
test_stored_value_error :: proc(t: ^testing.T) {
	testing.expect(t, wayu.stored_value_error("v", "café") == "")
	testing.expect(t, wayu.stored_value_error("v", "a\x00b") != "")
	testing.expect(t, wayu.stored_value_error("v", "a\xffb") != "")
}
