package test_wayu

// Tests for the shell-quoting helpers (shell.odin), the minimal TOML line
// value parser used by the init generator, alias-listing parsing
// (env_snapshot.odin) and prompt context detection generation.

import wayu "../../src"
import "core:strings"
import "core:testing"

@(test)
test_shell_single_quote :: proc(t: ^testing.T) {
	q := wayu.shell_single_quote("git log --format='%h'", context.temp_allocator)
	testing.expect_value(t, q, `'git log --format='\''%h'\'''`)
	testing.expect_value(t, wayu.shell_single_quote("", context.temp_allocator), "''")
	testing.expect_value(
		t,
		wayu.shell_single_quote("ünï $HOME", context.temp_allocator),
		"'ünï $HOME'",
	)
}

@(test)
test_shell_double_quote_env :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		wayu.shell_double_quote_env("$HOME/go", context.temp_allocator),
		`"${HOME}/go"`,
	)
	testing.expect_value(
		t,
		wayu.shell_double_quote_env(`a"b\c`, context.temp_allocator),
		`"a\"b\\c"`,
	)
	testing.expect_value(
		t,
		wayu.shell_double_quote_env("x`id`$(id)${HOME}", context.temp_allocator),
		"\"x\\`id\\`\\$(id)${HOME}\"",
	)
	testing.expect_value(
		t,
		wayu.shell_double_quote_env("héllo ✓", context.temp_allocator),
		`"héllo ✓"`,
	)
}

// Only named-variable references expand; anything that used to break the
// generated file (unclosed `${`) or run code (zsh `${(e)...}`) is literal.
@(test)
test_shell_double_quote_env_dollar_forms :: proc(t: ^testing.T) {
	Case :: struct {
		src, want: string,
	}
	cases := []Case {
		{`pa${ss`, `"pa\${ss"`}, // unclosed: was a syntax error
		{`${(e):-$(id)}`, `"\${(e):-\$(id)}"`}, // zsh flag: evaluated its text
		{`a${1abc}`, `"a\${1abc}"`}, // zsh: bad substitution aborted core
		{`$HOME:h[1]`, `"${HOME}:h[1]"`}, // no zsh modifier / subscript
		{`a$1$$b$`, `"a\$1\$${b}\$"`}, // positional/special/trailing
		{`${X:-$(id)}`, `"${X:-\$(id)}"`}, // default kept, body escaped
		{`${A:-${B}}/x`, `"${A:-${B}}/x"`}, // nested
		{`${#HOME}`, `"${#HOME}"`},
		{`a$%b`, `"a\$%b"`},
		// Operators that evaluate text stay literal (OKAMI-174).
		{`${X@P}`, `"\${X@P}"`}, // bash 4.4+: prompt-expands X, runs $(...)
		{`${X[Y]}`, `"\${X[Y]}"`}, // subscript: arithmetic on Y's value
		{`${X:Y}`, `"\${X:Y}"`}, // substring: arithmetic; zsh modifier error
		{`${X: -1}`, `"\${X: -1}"`},
		{`${X^}`, `"\${X^}"`}, // bash 4 only; zsh bad substitution
		{`${#X:-a}`, `"\${#X:-a}"`},
		{`${A:-${B@P}}`, `"${A:-\${B@P}}"`}, // nested body checked too
		{`${X=a}${X:=a}${X+a}${X:+a}${X?a}${X:?a}`, `"${X=a}${X:=a}${X+a}${X:+a}${X?a}${X:?a}"`},
		{
			`${X#a}${X##a}${X%a}${X%%a}${X/a/b}${X//a/b}`,
			`"${X#a}${X##a}${X%a}${X%%a}${X/a/b}${X//a/b}"`,
		},
	}
	for c in cases {
		got := wayu.shell_double_quote_env(c.src, context.temp_allocator)
		testing.expectf(
			t,
			got == c.want,
			"shell_double_quote_env(%q) = %s, want %s",
			c.src,
			got,
			c.want,
		)
	}
}

@(test)
test_fish_double_quote_env_dollar_forms :: proc(t: ^testing.T) {
	Case :: struct {
		src, want: string,
	}
	cases := []Case {
		{`${HOME}/go`, `"$HOME/go"`}, // fish rejects ${ at parse time
		{`$HOME[1]x`, `"$HOME""[1]x"`}, // no fish index
		{`${HOME}bin`, `"$HOME""bin"`}, // no longer name
		{`$HOMEé/${HOME}本`, `"$HOME""é/$HOME""本"`}, // fish names take non-ASCII letters
		{`pa${ss`, `"pa\${ss"`},
		{`a$`, `"a\$"`},
		{`$$x$1`, `"\$$x\$1"`},
		{`${X:-y}`, `"\${X:-y}"`}, // no fish equivalent: literal
	}
	for c in cases {
		got := wayu.fish_double_quote_env(c.src, context.temp_allocator)
		testing.expectf(
			t,
			got == c.want,
			"fish_double_quote_env(%q) = %s, want %s",
			c.src,
			got,
			c.want,
		)
	}
}

@(test)
test_shell_double_quote_literal :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		wayu.shell_double_quote_literal(`/a b/$x"`, context.temp_allocator),
		`"/a b/\$x\""`,
	)
}

@(test)
test_escape_fish_string :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		wayu.escape_fish_string(`it's a\b $x *`, context.temp_allocator),
		`'it\'s a\\b $x *'`,
	)
	testing.expect_value(
		t,
		wayu.fish_double_quote_env(`$HOME/"x"\$(id)*`, context.temp_allocator),
		`"$HOME/\"x\"\\\$(id)*"`,
	)
}

@(test)
test_expand_leading_tilde :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		wayu.expand_leading_tilde_to_home_var("~/x", context.temp_allocator),
		"$HOME/x",
	)
	testing.expect_value(
		t,
		wayu.expand_leading_tilde_to_home_var("~", context.temp_allocator),
		"$HOME",
	)
	testing.expect_value(
		t,
		wayu.expand_leading_tilde_to_home_var("a~/x", context.temp_allocator),
		"a~/x",
	)
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
test_toml_kv_line_quote_stripping :: proc(t: ^testing.T) {
	Case :: struct {
		raw, want: string,
		ok:        bool,
	}
	cases := []Case {
		{`"git log --format='%h'"`, "git log --format='%h'", true},
		{`"x" # comment`, "x", true},
		{`""`, "", true},
		{`'lit \n $HOME'`, `lit \n $HOME`, true},
		{`'a' # c`, "a", true},
		{`"say \"hi\""`, `say "hi"`, true},
		{`true # bool`, "true", true},
	}
	for c in cases {
		_, got, ok := wayu.toml_parse_kv_line(
			strings.concatenate({"k = ", c.raw}, context.temp_allocator),
		)
		defer if ok {
			delete(got)
		}
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
		for k, v in out {delete(k); delete(v)}
		delete(out)
	}
	text := "ll='ls -la'\nalias gl='git log --format='\\''%h'\\'''\nrun-help=man\n'a-b'='x y'\n"
	wayu.parse_alias_listing(text, &out)
	testing.expect_value(t, out["ll"], "ls -la")
	testing.expect_value(t, out["gl"], "git log --format='%h'")
	testing.expect_value(t, out["run-help"], "man")
	testing.expect_value(t, out["a-b"], "x y")
}

// fish's `alias` prints `alias name 'value'`; it used to parse to nothing,
// so every wayu alias showed as inactive under fish.
@(test)
test_parse_alias_listing_fish :: proc(t: ^testing.T) {
	out := make(map[string]string)
	defer {
		for k, v in out {delete(k); delete(v)}
		delete(out)
	}
	text := "alias ll 'ls -la'\nalias sq 'echo it\\'s \\\\ x'\nalias bare git\nalias eq 'a=b c'\n"
	wayu.parse_alias_listing(text, &out)
	testing.expect_value(t, out["ll"], "ls -la")
	testing.expect_value(t, out["sq"], `echo it's \ x`)
	testing.expect_value(t, out["bare"], "git")
	testing.expect_value(t, out["eq"], "a=b c")
}

@(test)
test_context_detect_condition :: proc(t: ^testing.T) {
	cond := wayu.context_detect_condition([]string{"*.kt", "Makefile", "bad;rm -rf"})
	testing.expect(
		t,
		strings.contains(cond, "(){ [[ -e $1 ]] } *.kt(NY1)"),
		"glob detect uses null-glob probe",
	)
	testing.expect(t, strings.contains(cond, "[[ -e 'Makefile' ]]"), "plain detect uses -e test")
	testing.expect(t, !strings.contains(cond, "rm"), "unsafe detect entries are dropped")
}
