// test_migrate.odin - Tests for migrate helpers (schema parser, legacy shell parser)

package test_wayu

import "core:fmt"
import "core:testing"
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

// Analyze `src` and return "kind:name=value" per entry plus the issue count.
// Strings are temp-allocated.
@(private = "file")
analyze :: proc(src: string, dialect := wayu.ShellDialect.POSIX) -> (entries: [dynamic]string, issues: int) {
	a := wayu.legacy_analyze(src, dialect)
	defer wayu.legacy_analysis_destroy(&a)
	entries = make([dynamic]string, context.temp_allocator)
	for e in a.entries {
		switch e.kind {
		case .Path:     append(&entries, fmt.tprintf("path:%s", e.value))
		case .Alias:    append(&entries, fmt.tprintf("alias:%s=%s", e.name, e.value))
		case .Constant: append(&entries, fmt.tprintf("env:%s=%s", e.name, e.value))
		}
	}
	return entries, len(a.issues)
}

@(test)
test_migrate_parse_alias_quoting :: proc(t: ^testing.T) {
	Case :: struct { line, want: string }
	cases := []Case{
		{`alias ll='ls -lah'`, "alias:ll=ls -lah"},
		{`alias k=kubectl`, "alias:k=kubectl"},
		{`alias gs="git status"`, "alias:gs=git status"},
		// Mixed quotes: inner double quotes belong to the command.
		{`alias glf='git log --format="%h %s"'`, `alias:glf=git log --format="%h %s"`},
		// Escapes are decoded once; $HOME stays for run time.
		{`alias dq="echo \"quoted\" $HOME"`, `alias:dq=echo "quoted" $HOME`},
		{`alias it='echo it'\''s'`, `alias:it=echo it's`},
		{`alias tab=$'a\tb'`, "alias:tab=a\tb"},
		{`alias x=a\ b # trailing comment`, "alias:x=a b"},
	}
	for c in cases {
		got, issues := analyze(c.line)
		testing.expectf(t, issues == 0, "%q: %d issue(s)", c.line, issues)
		testing.expectf(t, len(got) == 1 && got[0] == c.want, "%q: got %v want %q", c.line, got, c.want)
	}

	multi, issues := analyze(`alias a=1 b='2 3'`)
	testing.expect_value(t, issues, 0)
	testing.expect_value(t, len(multi), 2)
}

@(test)
test_migrate_parse_export_forms :: proc(t: ^testing.T) {
	Case :: struct { line, want: string }
	cases := []Case{
		{`export SINGLE='a b'`, "env:SINGLE=a b"},
		{`export BARE=value`, "env:BARE=value"},
		{`export GREETING='say "hi" now'`, `env:GREETING=say "hi" now`},
		{`export ESC="tab\\there \"q\""`, `env:ESC=tab\there "q"`},
		{`export GOBIN="$HOME/go/bin"`, "env:GOBIN=$HOME/go/bin"},
		{`export D=~/x`, "env:D=~/x"},
		{`typeset -x T=1`, "env:T=1"},
		{`declare -gx G=2`, "env:G=2"},
	}
	for c in cases {
		got, issues := analyze(c.line)
		testing.expectf(t, issues == 0, "%q: %d issue(s)", c.line, issues)
		testing.expectf(t, len(got) == 1 && got[0] == c.want, "%q: got %v want %q", c.line, got, c.want)
	}

	two, issues := analyze("export A=1 B=2")
	testing.expect_value(t, issues, 0)
	testing.expect_value(t, len(two), 2)
}

@(test)
test_migrate_parse_reports_unparsed :: proc(t: ^testing.T) {
	// Each of these must be reported, never silently dropped or hoisted.
	bad := []string{
		"alias multi='line one\nline two'",
		"if [ -n \"$X\" ]; then\n  export COND=1\nfi",
		"greet() {\n  echo hi\n}",
		`export NOW="$(date)"`,
		"export TICK=\"`date`\"",
		`export LIT='$HOME'`,     // literal $ would start expanding
		`export Q='~/x'`,         // quoted ~ would expand
		`PLAIN=1`,                // not exported
		`export PATH="/x:$PATH"`, // belongs in [paths]
		`alias -g G='| grep'`,
		`alias broken='oops`,
		`source ~/.other`,
		`export A=1; export B=2`,
	}
	for src in bad {
		got, issues := analyze(src)
		testing.expectf(t, issues > 0, "%q: expected an issue, got entries %v", src, got)
		testing.expectf(t, len(got) == 0, "%q: expected no entries, got %v", src, got)
	}

	// An unterminated quote swallows the rest: later lines are not trusted.
	got, issues := analyze("alias a='x\nalias b=y\n")
	testing.expect_value(t, len(got), 0)
	testing.expect(t, issues > 0)
}

@(test)
test_migrate_parse_skips_scaffold_and_reads_paths :: proc(t: ^testing.T) {
	for tmpl in ([]string{wayu.PATH_TEMPLATE_ZSH, wayu.PATH_TEMPLATE_BASH, wayu.ALIASES_TEMPLATE_ZSH, wayu.CONSTANTS_TEMPLATE_BASH}) {
		got, issues := analyze(tmpl)
		testing.expectf(t, len(got) == 0 && issues == 0, "template must be empty: %v / %d issues", got, issues)
	}
	fish, fish_issues := analyze(wayu.PATH_TEMPLATE_FISH, .FISH)
	testing.expectf(t, len(fish) == 0 && fish_issues == 0, "fish template: %v / %d issues", fish, fish_issues)

	src := "#!/usr/bin/env zsh\nWAYU_PATHS=(\n  \"/opt/homebrew/bin\"\n  '/usr/local/bin'\n  \"$HOME/go/bin\"\n)\n"
	got, issues := analyze(src)
	testing.expect_value(t, issues, 0)
	testing.expect_value(t, len(got), 3)
	if len(got) == 3 {
		testing.expect_value(t, got[1], "path:/usr/local/bin")
		testing.expect_value(t, got[2], "path:$HOME/go/bin")
	}

	one, one_issues := analyze(`WAYU_PATHS=("/a" "/b")`)
	testing.expect_value(t, one_issues, 0)
	testing.expect_value(t, len(one), 2)

	// v2.x layout: add_to_path() helper + calls.
	v2 := `#!/usr/bin/env zsh

add_to_path() {
    local dir="$1"
    local position="${2:-prepend}"  # prepend or append, default is prepend

    # Check if directory exists
    if [ ! -d "$dir" ]; then
        return 1
    fi

    # Check if directory is already in PATH
    if [[ ":$PATH:" == *":$dir:"* ]]; then
        return 0
    fi

    # Add to PATH
    if [ "$position" = "append" ]; then
        export PATH="$PATH:$dir"
    else
        export PATH="$dir:$PATH"
    fi
}

add_to_path "/opt/v2/bin"

export PATH=$(echo "$PATH" | awk -v RS=':' -v ORS=':' '!seen[$0]++' | sed 's/:$//')
`
	old, old_issues := analyze(v2)
	testing.expect_value(t, old_issues, 0)
	testing.expect_value(t, len(old), 1)
	if len(old) == 1 { testing.expect_value(t, old[0], "path:/opt/v2/bin") }
}

@(test)
test_migrate_parse_fish :: proc(t: ^testing.T) {
	src := "alias ll 'ls -la'\nalias it 'it\\'s'\nset -gx EDITOR nvim\nset -gx MSG \"say \\\"hi\\\" $USER\"\nset -a WAYU_PATHS \"/opt/bin\"\nfish_add_path -g /usr/local/bin\n"
	got, issues := analyze(src, .FISH)
	testing.expect_value(t, issues, 0)
	want := []string{"alias:ll=ls -la", "alias:it=it's", "env:EDITOR=nvim", `env:MSG=say "hi" $USER`, "path:/opt/bin", "path:/usr/local/bin"}
	testing.expect_value(t, len(got), len(want))
	for w, i in want {
		if i < len(got) { testing.expect_value(t, got[i], w) }
	}

	_, list_issues := analyze("set -gx LIST a b", .FISH)
	testing.expect(t, list_issues > 0, "fish list variables are not single values")
	_, local_issues := analyze("set -g NOTEXPORTED 1", .FISH)
	testing.expect(t, local_issues > 0, "unexported fish variables are not constants")
}
