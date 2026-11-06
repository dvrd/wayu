// test_toml.odin - Unit tests for TOML configuration module

package test_wayu

import "core:testing"
import "core:strings"
import "core:fmt"
import wayu "../../src"

// ============================================================================
// TOML PARSING TESTS
// ============================================================================

@(test)
test_toml_parse_basic :: proc(t: ^testing.T) {
 content := `
version = "1.0"
shell = "zsh"
wayu_version = "3.4.0"
`
 config, ok := wayu.toml_parse(content)
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "Basic TOML parsing should succeed")
 testing.expect(t, config.version == "1.0", "Version should be 1.0")
 testing.expect(t, config.shell == "zsh", "Shell should be zsh")
}

@(test)
test_toml_parse_path_config :: proc(t: ^testing.T) {
 content := `
[paths]
local_bin = "/usr/local/bin"
cargo_bin = "$HOME/.cargo/bin"
`
 config, ok := wayu.toml_parse(content)
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "Path config parsing should succeed")
 testing.expect(t, len(config.path.entries) == 2, "Should have 2 path entries")
}

@(test)
test_toml_parse_aliases :: proc(t: ^testing.T) {
 content := `
[aliases]
ll  = "ls -la"
gcm = "git commit -m"
`
 config, ok := wayu.toml_parse(content)
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "Alias parsing should succeed")
 testing.expect(t, len(config.aliases) == 2, "Should have 2 aliases")
 // Map iteration order isn't guaranteed; check by name search.
 found_ll := false
 for a in config.aliases {
  if a.name == "ll" && a.command == "ls -la" { found_ll = true; break }
 }
 testing.expect(t, found_ll, `Should contain ll = "ls -la"`)
}

@(test)
test_toml_parse_constants :: proc(t: ^testing.T) {
 content := `
[env]
EDITOR  = "nvim"
API_KEY = "secret123"
`
 config, ok := wayu.toml_parse(content)
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "Env parsing should succeed")
 testing.expect(t, len(config.constants) == 2, "Should have 2 env entries")
 found_editor := false
 for c in config.constants {
  if c.name == "EDITOR" && c.value == "nvim" && c.export {
   found_editor = true; break
  }
 }
 testing.expect(t, found_editor, `Should contain EDITOR = "nvim" (exported)`)
}

@(test)
test_toml_parse_plugins :: proc(t: ^testing.T) {
 content := `
[[plugins]]
name = "zsh-autosuggestions"
source = "github:zsh-users/zsh-autosuggestions"
version = "v0.7.0"
defer = true
priority = 50

[[plugins]]
name = "fast-syntax-highlighting"
source = "github:zdharma-continuum/fast-syntax-highlighting"
`
 config, ok := wayu.toml_parse(content)
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "Plugin parsing should succeed")
 testing.expect(t, len(config.plugins) == 2, "Should have 2 plugins")
 testing.expect(t, config.plugins[0].name == "zsh-autosuggestions", "First plugin name should match")
 testing.expect(t, config.plugins[0].defer_load == true, "First plugin should be deferred")
 testing.expect(t, config.plugins[0].priority == 50, "First plugin priority should be 50")
}

@(test)
test_toml_parse_profile :: proc(t: ^testing.T) {
 content := `
[profile.work]
condition = "test $WORK_ENV = production"

[profile.work.path]
entries = ["/work/tools/bin"]

[[profile.work.aliases]]
name = "work"
command = "cd /work"

[[profile.work.constants]]
name = "WORK_ENV"
value = "production"
`
 config, ok := wayu.toml_parse(content)
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "Profile parsing should succeed")
 testing.expect(t, len(config.profiles) == 1, "Should have 1 profile")

 profile, found := config.profiles["work"]
 testing.expect(t, found, "Should find 'work' profile")
 testing.expect(t, profile.condition == "test $WORK_ENV = production", "Profile condition should match")
}

@(test)
test_toml_parse_settings :: proc(t: ^testing.T) {
 content := `
[settings]
auto_backup = true
fuzzy_fallback = true
dry_run_default = false
`
 config, ok := wayu.toml_parse(content)
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "Settings parsing should succeed")
 testing.expect(t, config.settings.auto_backup == true, "auto_backup should be true")
 testing.expect(t, config.settings.fuzzy_fallback == true, "fuzzy_fallback should be true")
 testing.expect(t, config.settings.dry_run_default == false, "dry_run_default should be false")
}

// ============================================================================
// TOML VALIDATION TESTS
// ============================================================================

@(test)
test_toml_validate_valid_config :: proc(t: ^testing.T) {
 content := `
version = "1.0"
shell = "zsh"

[aliases]
ll = "ls -la"
`
 config, ok := wayu.toml_parse(content)
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "Parsing should succeed")

 result := wayu.toml_validate(config)
 defer if result.error_message != "" do delete(result.error_message)

 testing.expect(t, result.valid, "Valid config should pass validation")
}

@(test)
test_toml_validate_invalid_shell :: proc(t: ^testing.T) {
 content := `
version = "1.0"
shell = "invalid_shell"
`
 config, ok := wayu.toml_parse(content)
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "Parsing should succeed even with invalid shell")

 result := wayu.toml_validate(config)
 defer if result.error_message != "" do delete(result.error_message)

 testing.expect(t, !result.valid, "Invalid shell should fail validation")
}

@(test)
test_toml_validate_invalid_alias :: proc(t: ^testing.T) {
 content := `
version = "1.0"

[aliases]
if = "echo test"
`
 config, ok := wayu.toml_parse(content)
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "Parsing should succeed")

 result := wayu.toml_validate(config)
 defer if result.error_message != "" do delete(result.error_message)

 testing.expect(t, !result.valid, "Reserved word alias should fail validation")
}

@(test)
test_toml_parse_empty :: proc(t: ^testing.T) {
 config, ok := wayu.toml_parse("")
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "Empty TOML parsing should succeed")
}

@(test)
test_toml_parse_comments :: proc(t: ^testing.T) {
 content := `
# This is a comment
version = "1.0"  # inline comment

# Another comment
shell = "bash"
`
 config, ok := wayu.toml_parse(content)
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "TOML with comments should parse")
 testing.expect(t, config.version == "1.0", "Version should be 1.0")
 testing.expect(t, config.shell == "bash", "Shell should be bash")
}

@(test)
test_toml_parse_rejects_malformed_input :: proc(t: ^testing.T) {
 bad_inputs := []string{
  "version = \"1.0",
  "[paths",
  "= \"value\"",
  "x = [1,",
  "x = { a = 1",
  "shell = zsh",
  "not a key value line",
 }

 for input in bad_inputs {
  config, ok := wayu.toml_parse(input)
  defer wayu.cleanup_toml_config(&config)
  testing.expect(t, !ok, fmt.tprintf("Malformed TOML should fail: %s", input))
 }
}

@(test)
test_toml_parse_unescapes_basic_strings :: proc(t: ^testing.T) {
 content := "[aliases]\nq = \"echo \\\"hi\\\"\"\n[env]\nMULTI = \"a\\nb\"\nTAB = \"a\\tb\"\nLITERAL = 'a\\nb'\n"
 config, ok := wayu.toml_parse(content)
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "Escaped TOML strings should parse")

 found_alias := false
 for a in config.aliases {
  if a.name == "q" && a.command == "echo \"hi\"" { found_alias = true; break }
 }
 testing.expect(t, found_alias, "Basic string escaped quotes should unescape")

 found_multi := false
 found_tab := false
 found_literal := false
 for c in config.constants {
  if c.name == "MULTI" && c.value == "a\nb" { found_multi = true }
  if c.name == "TAB" && c.value == "a\tb" { found_tab = true }
  if c.name == "LITERAL" && c.value == `a\nb` { found_literal = true }
 }
 testing.expect(t, found_multi, "Basic string \\n should unescape to newline")
 testing.expect(t, found_tab, "Basic string \\t should unescape to tab")
 testing.expect(t, found_literal, "Literal single-quoted string should preserve backslash")
}

@(test)
test_toml_parse_escaped_hash_is_not_comment :: proc(t: ^testing.T) {
 content := "[aliases]\nq = \"echo \\\"# not a comment\\\"\" # real comment\n"
 config, ok := wayu.toml_parse(content)
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "Escaped quote before hash should not break comment stripping")
 testing.expect(t, len(config.aliases) == 1, "Alias should be parsed")
 testing.expect(t, config.aliases[0].command == "echo \"# not a comment\"", "Hash inside escaped quotes should be preserved")
}

@(test)
test_toml_profile_keys_survive_after_parse :: proc(t: ^testing.T) {
 config, ok := wayu.toml_parse("[profile.work]\ncondition = \"true\"\n")
 defer wayu.cleanup_toml_config(&config)
 testing.expect(t, ok, "Profile config should parse")

 noise := make([]string, 128)
 defer delete(noise)
 for i in 0..<len(noise) {
  noise[i] = fmt.tprintf("allocation-noise-%d", i)
 }

 _, found := config.profiles["work"]
 testing.expect(t, found, "Profile map key should remain valid after parser arena is released")
}

// Regression: strip_toml_section must NOT prepend bytes to the output.
// A prior bug used strings.builder_make(len(content)) which pre-filled the
// builder with len(content) zero bytes, corrupting the head of wayu.toml on
// every alias/constant write. Guard that the head byte stays '['.
@(test)
test_strip_toml_section_no_leading_padding :: proc(t: ^testing.T) {
 content := "[shell]\ntype = \"ZSH\"\n\n[env]\nFOO = \"bar\"\n"
 out := wayu.strip_toml_section(content, "env")
 defer delete(out)

 testing.expect(t, len(out) > 0, "stripped output should be non-empty")
 testing.expect(t, out[0] == '[', "stripped output must start with '[' (no padding)")
 testing.expect(t, strings.has_prefix(out, "[shell]"), "head section must be preserved verbatim")
 testing.expect(t, !strings.contains(out, "[env]"), "stripped section must be removed")
 testing.expect(t, !strings.contains_rune(out, rune(0)), "output must contain no NUL bytes")
}

// Regression: replace_toml_table_section must preserve the file head and only
// rewrite the targeted section body.
@(test)
test_replace_toml_table_section_preserves_head :: proc(t: ^testing.T) {
 content := "[shell]\ntype = \"ZSH\"\n\n[paths]\nold = \"/old\"\n"
 body := []string{"new_a = \"/a\"", "new_b = \"/b\""}
 out := wayu.replace_toml_table_section(content, "paths", body)
 defer delete(out)

 testing.expect(t, strings.has_prefix(out, "[shell]"), "head section must be preserved")
 testing.expect(t, strings.contains(out, "new_a = \"/a\""), "new body entry a must be present")
 testing.expect(t, strings.contains(out, "new_b = \"/b\""), "new body entry b must be present")
 testing.expect(t, !strings.contains(out, "old = \"/old\""), "old body entry must be replaced")
}

// ---------------------------------------------------------------------------
// Value / header parsing regressions (quote stripping, comments, UTF-8)
// ---------------------------------------------------------------------------

@(test)
test_toml_parse_kv_line_keeps_inner_single_quote :: proc(t: ^testing.T) {
	// Old reader trimmed `"` then `'` independently → lost the trailing `'`.
	key, val, ok := wayu.toml_parse_kv_line(`glf = "git log --format='%h'"`)
	defer delete(val)
	testing.expect(t, ok)
	testing.expect_value(t, key, "glf")
	testing.expect_value(t, val, "git log --format='%h'")
}

@(test)
test_toml_parse_kv_line_strips_inline_comment :: proc(t: ^testing.T) {
	_, val, ok := wayu.toml_parse_kv_line(`EDITOR = "nvim" # my editor`)
	defer delete(val)
	testing.expect(t, ok)
	testing.expect_value(t, val, "nvim")

	// A `#` inside the string is data, not a comment.
	_, val2, ok2 := wayu.toml_parse_kv_line(`X = "a # b"`)
	defer delete(val2)
	testing.expect(t, ok2)
	testing.expect_value(t, val2, "a # b")
}

@(test)
test_toml_parse_kv_line_literal_and_empty :: proc(t: ^testing.T) {
	// 'literal' strings are verbatim (no escape processing).
	_, lit, ok := wayu.toml_parse_kv_line(`P = 'C:\path\n'`)
	defer delete(lit)
	testing.expect(t, ok)
	testing.expect_value(t, lit, `C:\path\n`)

	// Empty quoted value is a real value, not "skip this line".
	_, empty, ok2 := wayu.toml_parse_kv_line(`FOO = ""`)
	defer delete(empty)
	testing.expect(t, ok2, "FOO = \"\" must parse (was dropped on next rewrite)")
	testing.expect_value(t, empty, "")
}

@(test)
test_unescape_toml_string_utf8 :: proc(t: ^testing.T) {
	out := wayu.unescape_toml_string("café ☕")
	defer delete(out)
	testing.expect_value(t, out, "café ☕") // was mangled to cafÃ©

	out2 := wayu.unescape_toml_string(`caf\u00e9 \U0001F600 \"q\"`)
	defer delete(out2)
	testing.expect_value(t, out2, "café 😀 \"q\"")

	// Malformed \u stays literal.
	out3 := wayu.unescape_toml_string(`\u12`)
	defer delete(out3)
	testing.expect_value(t, out3, `\u12`)
}

@(test)
test_toml_line_is_section_with_comment :: proc(t: ^testing.T) {
	testing.expect(t, wayu.toml_line_is_section("[env]", "env"))
	testing.expect(t, wayu.toml_line_is_section("[env]  # vars", "env"))
	testing.expect(t, wayu.toml_line_is_section("[ env ]", "env"))
	testing.expect(t, !wayu.toml_line_is_section("[[env]]", "env"))
	testing.expect(t, !wayu.toml_line_is_section("[environment]", "env"))
}

@(test)
test_replace_toml_table_section_header_comment_no_duplicate :: proc(t: ^testing.T) {
	content := "[shell]\ntype = \"zsh\"\n\n[env]  # my vars\n# keep me\nA = \"1\"\n\n[paths]\nx = \"/x\"\n"
	body := []string{`A = "1"`, `B = "2"`}
	out := wayu.replace_toml_table_section(content, "env", body)
	defer delete(out)

	testing.expect_value(t, strings.count(out, "[env]"), 1)
	testing.expect(t, strings.contains(out, "[env]  # my vars"), "header comment must survive")
	testing.expect(t, strings.contains(out, "# keep me"), "comment inside the table must survive")
	testing.expect(t, strings.contains(out, `B = "2"`))
	testing.expect(t, strings.contains(out, "[paths]\nx = \"/x\""), "following table untouched")
	// Result must still be valid for wayu's own sanity checker.
	testing.expect(t, wayu.toml_content_is_sane(out), "rewritten TOML must be sane")
}

@(test)
test_strip_toml_section_header_with_comment :: proc(t: ^testing.T) {
	content := "[aliases]  # c\nll = \"ls\"\n[env]\nA = \"1\"\n"
	out := wayu.strip_toml_section(content, "aliases")
	defer delete(out)
	testing.expect(t, !strings.contains(out, "ll ="), "commented header must be recognised")
	testing.expect(t, strings.contains(out, "[env]"))
}
