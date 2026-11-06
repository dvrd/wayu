// test_migrate.odin - Tests for migrate helpers (schema parser, shell quoting)

package test_wayu

import "core:testing"
import "core:strings"
import wayu "../../src"

@(test)
test_migrate_parse_toml_kv_decodes_once :: proc(t: ^testing.T) {
	Case :: struct { line, key, value: string, ok: bool }
	cases := []Case{
		{`a = "x \"y\" \\ z"`, "a", `x "y" \ z`, true},
		{`b = 'C:\Users\dan'`, "b", `C:\Users\dan`, true},
		{`c = "v" # trailing comment`, "c", "v", true},
		{`d = 'it''`, "", "", false},           // garbage after literal
		{`e = 42 # num`, "e", "42", true},
		{`f = "héllo"`, "f", "héllo", true},  // UTF-8 untouched
		{`g = "\u00e9"`, "g", "é", true},
		{`h = """multi"""`, "", "", false},
		{`# comment`, "", "", false},
	}
	for c in cases {
		k, v, ok := wayu.migrate_parse_toml_kv(c.line)
		testing.expectf(t, ok == c.ok, "%q: ok=%v want %v", c.line, ok, c.ok)
		if ok {
			testing.expectf(t, k == c.key, "%q: key=%q want %q", c.line, k, c.key)
			testing.expectf(t, v == c.value, "%q: value=%q want %q", c.line, v, c.value)
			delete(k); delete(v)
		}
	}
}

@(test)
test_migrate_parse_legacy_paths_keeps_keys :: proc(t: ^testing.T) {
	content := "[paths]\nmine = \"/opt/a\"\n\n[[paths]]\npath = \"/opt/a\"\n\n[[paths]]\nname = \"brew\"\npath = \"/opt/homebrew/bin\"\n"
	paths := wayu.parse_legacy_paths(content)
	defer { for p in paths { delete(p.key); delete(p.path) }; delete(paths) }

	testing.expect_value(t, len(paths), 2)
	found_mine, found_brew := false, false
	for p in paths {
		if p.key == "mine" && p.path == "/opt/a" { found_mine = true }
		if p.key == "brew" && p.path == "/opt/homebrew/bin" { found_brew = true }
	}
	testing.expect(t, found_mine, "user [paths] key must be preserved")
	testing.expect(t, found_brew, "[[paths]] name must become the key")
}

@(test)
test_migrate_shell_quoting :: proc(t: ^testing.T) {
	fq := wayu.migrate_fish_sq_quote(`it's a \ test`)
	defer delete(fq)
	testing.expect_value(t, fq, `'it\'s a \\ test'`)

	pq := wayu.migrate_posix_dq_quote("say \"hi\" $x `y` \\")
	defer delete(pq)
	testing.expect_value(t, pq, "\"say \\\"hi\\\" \\$x \\`y\\` \\\\\"")

	fd := wayu.migrate_posix_dq_to_fish_dq(`${HOME}/bin`)
	defer delete(fd)
	testing.expect_value(t, fd, `"{$HOME}/bin"`)

	pd := wayu.migrate_fish_dq_to_posix_dq(`{$HOME}/bin`)
	defer delete(pd)
	testing.expect_value(t, pd, `"${HOME}/bin"`)

	content := "#!/usr/bin/env zsh\nalias greet=\"echo 'hi'\"\n"
	out := wayu.convert_shell_content(content, .ZSH, .FISH, "aliases")
	defer delete(out)
	testing.expect(t, strings.contains(out, `alias greet 'echo \'hi\''`), out)
}
