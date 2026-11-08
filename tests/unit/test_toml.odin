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

[shell]
type = "zsh"
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
  if c.name == "EDITOR" && c.value == "nvim" {
   found_editor = true; break
  }
 }
 testing.expect(t, found_editor, `Should contain EDITOR = "nvim"`)
}

@(test)
test_toml_parse_settings :: proc(t: ^testing.T) {
 content := `
[settings]
autosuggestions_accept_keys = ["^Y", "^[[121;5u"]
`
 config, ok := wayu.toml_parse(content)
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "Settings parsing should succeed")
 testing.expect_value(t, len(config.settings.autosuggestions_accept_keys), 2)
}

// Keys wayu does not read are reported (warnings) with their line; tables
// of the wrong shape ([[paths]]) are errors.
@(test)
test_toml_schema_issues :: proc(t: ^testing.T) {
 content := `wayu_version = "3.4.0"
[shell]
type = "zsh"
[settings]
auto_backup = true
autosuggestions_accept_keys = ["^Y"]
[tools]
zoxide = { args = "init zsh", bogus = 1 }
[prompt.username]
style_user = "red"
format = "x"
[constants]
X = "1"
Y = "2"
`
 issues := wayu.toml_content_schema_issues(content)
 want := []string{
  "unknown key wayu_version (ignored)",
  "unknown key settings.auto_backup (ignored)",
  "unknown key tools.zoxide.bogus (ignored)",
  "unknown key prompt.username.style_user (ignored)",
  "unknown table [constants] (ignored)",
 }
 want_lines := []int{1, 5, 8, 10, 12}
 testing.expect_value(t, len(issues), len(want))
 if len(issues) != len(want) { return }
 for is, i in issues {
  testing.expect_value(t, is.msg, want[i])
  testing.expect_value(t, is.line, want_lines[i])
  testing.expect(t, !is.is_error)
 }

 for bad in ([]string{"[[paths]]\npath = \"/usr/bin\"\n", "paths = \"x\"\n", "[[aliases]]\nname = \"ll\"\n"}) {
  errs := wayu.toml_content_schema_issues(bad)
  testing.expectf(t, len(errs) > 0 && errs[0].is_error, "%q must be a schema error", bad)
 }

 clean := wayu.toml_content_schema_issues("version = \"1.0\"\n[paths]\na = \"/a\"\n[aliases]\n\"g.st\" = \"git st\"\n[env]\nX = \"1\"\n[tools.atuin]\nkind = \"evalcache\"\n[prompt]\nenabled = true\n[prompt.contexts]\ngo = { format = \"go\", detect = [\"go.mod\"] }\n[prompt.interactive]\nasync_rprompt = false\n")
 testing.expectf(t, len(clean) == 0, "known keys must not be reported: %v", clean)
}

// ============================================================================
// TOML VALIDATION TESTS
// ============================================================================

@(test)
test_toml_validate_valid_config :: proc(t: ^testing.T) {
 content := `
version = "1.0"

[shell]
type = "zsh"

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

[shell]
type = "invalid_shell"
`
 config, ok := wayu.toml_parse(content)
 defer wayu.cleanup_toml_config(&config)

 testing.expect(t, ok, "Parsing should succeed even with invalid shell")

 result := wayu.toml_validate(config)
 defer if result.error_message != "" do delete(result.error_message)

 testing.expect(t, !result.valid, "Invalid shell should fail validation")
}

// OKAMI-277 (CFG-23): the scaffold's `[shell] type` is what gets validated,
// case-insensitively (pre-6.0 scaffolds wrote "ZSH" / "Bash").
@(test)
test_toml_shell_type_table_is_read_and_validated :: proc(t: ^testing.T) {
 cases := []struct{ value, want: string, valid: bool }{
  {"zsh", "zsh", true},
  {"ZSH", "zsh", true},
  {"Bash", "bash", true},
  {"fish", "fish", true},
  {"tcsh", "tcsh", false},
 }
 for c in cases {
  content := fmt.aprintf("[shell]\ntype = \"%s\"\n\n[aliases]\n", c.value)
  defer delete(content)
  config, ok := wayu.toml_parse(content)
  defer wayu.cleanup_toml_config(&config)
  testing.expect(t, ok, "Parsing should succeed")
  testing.expect_value(t, config.shell, c.want)

  result := wayu.toml_validate(config)
  defer if result.error_message != "" do delete(result.error_message)
  testing.expectf(t, result.valid == c.valid, "[shell] type = %q: valid=%v", c.value, result.valid)
 }
}

@(test)
test_wayu_toml_scaffold_uses_lowercase_shell_type :: proc(t: ^testing.T) {
 shells := []wayu.ShellType{.ZSH, .BASH, .FISH, .UNKNOWN}
 wants := []string{"zsh", "bash", "fish", "zsh"}
 for s, i in shells {
  scaffold := wayu.wayu_toml_scaffold(s)
  defer delete(scaffold)
  want := fmt.tprintf("[shell]\ntype = \"%s\"\n", wants[i])
  testing.expectf(t, strings.has_prefix(scaffold, want), "scaffold for %v: %q", s, scaffold)

  config, ok := wayu.toml_parse(scaffold)
  defer wayu.cleanup_toml_config(&config)
  testing.expect(t, ok, "scaffold must parse")
  result := wayu.toml_validate(config)
  defer if result.error_message != "" do delete(result.error_message)
  testing.expect(t, result.valid, "scaffold must validate")
 }
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
[shell]
type = "bash"  # inline comment
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

// Regression: toml_parse used a fixed arena capped at 1MB, so a large
// wayu.toml (thousands of aliases) exhausted it and crashed.
@(test)
test_toml_parse_large_config :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "[aliases]\n")
	N :: 6000
	for i in 0..<N {
		fmt.sbprintf(&b, "a_%d = \"echo some fairly long command number %d with --flags here\"\n", i, i)
	}
	config, ok := wayu.toml_parse(strings.to_string(b))
	defer wayu.cleanup_toml_config(&config)
	testing.expect(t, ok, "large config must parse")
	testing.expect_value(t, len(config.aliases), N)
}
