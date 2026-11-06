package test_wayu

// Tests for the shell-quoting helpers (shell.odin), the minimal TOML line
// value parser used by the init generator, alias-listing parsing
// (env_snapshot.odin) and prompt context detection generation.

import "core:testing"
import "core:strings"
import wayu "../../src"

@(test)
test_shell_single_quote :: proc(t: ^testing.T) {
	q := wayu.shell_single_quote("git log --format='%h'", context.temp_allocator)
	testing.expect_value(t, q, `'git log --format='\''%h'\'''`)
	testing.expect_value(t, wayu.shell_single_quote("", context.temp_allocator), "''")
	testing.expect_value(t, wayu.shell_single_quote("ünï $HOME", context.temp_allocator), "'ünï $HOME'")
}

@(test)
test_shell_double_quote_env :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.shell_double_quote_env("$HOME/go", context.temp_allocator), `"$HOME/go"`)
	testing.expect_value(t, wayu.shell_double_quote_env(`a"b\c`, context.temp_allocator), `"a\"b\\c"`)
	testing.expect_value(t, wayu.shell_double_quote_env("x`id`$(id)${HOME}", context.temp_allocator), "\"x\\`id\\`\\$(id)${HOME}\"")
	testing.expect_value(t, wayu.shell_double_quote_env("héllo ✓", context.temp_allocator), `"héllo ✓"`)
}

@(test)
test_shell_double_quote_literal :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.shell_double_quote_literal(`/a b/$x"`, context.temp_allocator), `"/a b/\$x\""`)
}

@(test)
test_escape_fish_string :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.escape_fish_string(`it's a\b $x *`, context.temp_allocator), `'it\'s a\\b $x *'`)
	testing.expect_value(t, wayu.fish_double_quote_env(`$HOME/"x"\$(id)*`, context.temp_allocator), `"$HOME/\"x\"\\\$(id)*"`)
}

@(test)
test_expand_leading_tilde :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.expand_leading_tilde_to_home_var("~/x", context.temp_allocator), "$HOME/x")
	testing.expect_value(t, wayu.expand_leading_tilde_to_home_var("~", context.temp_allocator), "$HOME")
	testing.expect_value(t, wayu.expand_leading_tilde_to_home_var("a~/x", context.temp_allocator), "a~/x")
}

@(test)
test_identifier_and_alias_name_checks :: proc(t: ^testing.T) {
	testing.expect(t, wayu.is_shell_var_name("GO_PATH1"), "GO_PATH1 is an identifier")
	testing.expect(t, !wayu.is_shell_var_name("1X"), "leading digit rejected")
	testing.expect(t, !wayu.is_shell_var_name("A-B"), "dash rejected")
	testing.expect(t, wayu.is_safe_alias_name("g.st-x"), "dots/dashes allowed in alias names")
	testing.expect(t, !wayu.is_safe_alias_name("a;rm"), "metachar rejected")
	testing.expect(t, !wayu.is_safe_alias_name("a b"), "space rejected")
}

@(test)
test_parse_toml_line_value :: proc(t: ^testing.T) {
	Case :: struct { raw, want: string, ok: bool }
	cases := []Case{
		{`"git log --format='%h'"`, "git log --format='%h'", true},
		{`"x" # comment`, "x", true},
		{`""`, "", true},
		{`'lit \n $HOME'`, `lit \n $HOME`, true},
		{`'a' # c`, "a", true},
		{`"say \"hi\""`, `say "hi"`, true},
		{`"unterminated`, "", false},
		{`true # bool`, "true", true},
	}
	for c in cases {
		got, ok := wayu.parse_toml_line_value(c.raw)
		defer if ok { delete(got) }
		testing.expectf(t, ok == c.ok, "ok mismatch for %s", c.raw)
		if ok && c.ok {
			testing.expectf(t, got == c.want, "parse %s: got %q want %q", c.raw, got, c.want)
		}
	}
}

@(test)
test_parse_alias_listing_zsh_and_bash :: proc(t: ^testing.T) {
	out := make(map[string]string)
	defer {
		for k, v in out { delete(k); delete(v) }
		delete(out)
	}
	text := "ll='ls -la'\nalias gl='git log --format='\\''%h'\\'''\nrun-help=man\n'a-b'='x y'\n"
	wayu.parse_alias_listing(text, &out)
	testing.expect_value(t, out["ll"], "ls -la")
	testing.expect_value(t, out["gl"], "git log --format='%h'")
	testing.expect_value(t, out["run-help"], "man")
	testing.expect_value(t, out["a-b"], "x y")
}

@(test)
test_context_detect_condition :: proc(t: ^testing.T) {
	cond := wayu.context_detect_condition([]string{"*.kt", "Makefile", "bad;rm -rf"})
	testing.expect(t, strings.contains(cond, "(){ [[ -e $1 ]] } *.kt(NY1)"), "glob detect uses null-glob probe")
	testing.expect(t, strings.contains(cond, "[[ -e 'Makefile' ]]"), "plain detect uses -e test")
	testing.expect(t, !strings.contains(cond, "rm"), "unsafe detect entries are dropped")
}
