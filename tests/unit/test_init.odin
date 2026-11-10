package test_wayu

import wayu "../../src"
import "core:os"
import "core:strings"
import "core:testing"

// OKAMI-213: [paths] values become shell words expanded at source time;
// each referenced var guards the entry so an unset var drops it.
@(test)
test_path_value_shell_word :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"/opt/bin", "'/opt/bin'"},
		{"$HOME/bin", `${HOME:+"${HOME}"'/bin'}`},
		{"${GOPATH}/bin", `${GOPATH:+"${GOPATH}"'/bin'}`},
		{"$A/x/$B", `${A:+${B:+"${A}"'/x/'"${B}"}}`},
		{"/a$/b", "'/a$/b'"}, // bare '$' stays literal
		{"/x/${A:-y}", "'/x/${A:-y}'"}, // non-simple ${...} stays literal
		{"/it's", `'/it'\''s'`},
	}
	for c in cases {
		got := wayu.path_value_shell_word(c[0], context.allocator)
		defer delete(got)
		testing.expectf(t, got == c[1], "%q -> %q, want %q", c[0], got, c[1])
	}
}

@(test)
test_path_value_fish_word :: proc(t: ^testing.T) {
	word, guard := wayu.path_value_fish_word("$GOPATH/bin", context.temp_allocator)
	testing.expect_value(t, word, `"$GOPATH"'/bin'`)
	testing.expect_value(t, guard, `test -n "$GOPATH"; and `)
	word2, guard2 := wayu.path_value_fish_word("/opt/bin", context.temp_allocator)
	testing.expect_value(t, word2, "'/opt/bin'")
	testing.expect_value(t, guard2, "")
}

@(test)
test_parse_args_init :: proc(t: ^testing.T) {
	args := []string{"init"}
	parsed := wayu.parse_args(args)

	testing.expect_value(t, parsed.command, wayu.Command.INIT)
}

@(test)
test_zshrc_detection_patterns :: proc(t: ^testing.T) {
	// Test different ways wayu might be sourced in .zshrc
	test_contents := []string {
		`source "/Users/test/.config/wayu/init.zsh"`,
		`source /Users/test/.config/wayu/init.zsh`,
		`source "$HOME/.config/wayu/init.zsh"`,
		`source $HOME/.config/wayu/init.zsh`,
	}

	for content in test_contents {
		has_wayu :=
			strings.contains(content, "wayu/init.zsh") ||
			strings.contains(content, "wayu") && strings.contains(content, "source")
		testing.expect(t, has_wayu, "Should detect wayu in .zshrc")
	}
}

@(test)
test_zshrc_without_wayu :: proc(t: ^testing.T) {
	test_content := `# My .zshrc
export PATH="/usr/local/bin:$PATH"
alias ll="ls -la"
# Some other config
`

	// Should not contain wayu references
	has_wayu := strings.contains(test_content, "wayu")
	testing.expect(t, !has_wayu, "Should not detect wayu in clean .zshrc")
}

@(test)
test_template_structure :: proc(t: ^testing.T) {
	// Test that templates have proper structure
	testing.expect(
		t,
		strings.has_prefix(wayu.INIT_TEMPLATE_ZSH, "#!/usr/bin/env zsh"),
		"INIT_TEMPLATE_ZSH should have zsh shebang",
	)
	testing.expect(
		t,
		strings.has_prefix(wayu.TOOLS_TEMPLATE_ZSH, "#!/usr/bin/env zsh"),
		"TOOLS_TEMPLATE_ZSH should have zsh shebang",
	)
}

@(test)
test_init_template_loads_core_only :: proc(t: ^testing.T) {
	// init.<ext> sources the compiled core (which sources tools/extra) and
	// nothing else; there are no per-type shell files any more.
	for tmpl in ([]string {
			wayu.INIT_TEMPLATE_ZSH,
			wayu.INIT_TEMPLATE_BASH,
			wayu.INIT_TEMPLATE_FISH,
		}) {
		testing.expect(
			t,
			strings.contains(tmpl, "$WAYU_DATA_DIR/core."),
			"init template must source core.<ext>",
		)
		for stale in ([]string{"constants.", "aliases.", "/path."}) {
			testing.expectf(
				t,
				!strings.contains(tmpl, stale),
				"init template must not reference %s files",
				stale,
			)
		}
	}
}

@(test)
test_tools_template_has_examples :: proc(t: ^testing.T) {
	// tools.zsh is now an escape hatch — the canonical place for tool init
	// is the [tools] table in wayu.toml, with built-in recipes for
	// nvm/conda/evalcache/lazy. Verify the template documents that contract
	// and gives users at least one concrete example to copy.
	testing.expect(
		t,
		strings.contains(wayu.TOOLS_TEMPLATE_ZSH, "[tools]"),
		"TOOLS_TEMPLATE_ZSH should reference the declarative [tools] table",
	)
	testing.expect(
		t,
		strings.contains(wayu.TOOLS_TEMPLATE_ZSH, "wayu.toml"),
		"TOOLS_TEMPLATE_ZSH should point users at wayu.toml",
	)
	testing.expect(
		t,
		strings.contains(wayu.TOOLS_TEMPLATE_ZSH, "nvm") ||
		strings.contains(wayu.TOOLS_TEMPLATE_ZSH, "NVM"),
		"TOOLS_TEMPLATE_ZSH should still show an example referencing nvm",
	)
}

// OKAMI-235: init.<ext> is only rewritten when it matches a template wayu
// shipped. The templates shipped now must be in that list, so the next
// template change keeps recognising (and upgrading) today's files.
@(test)
test_current_init_templates_are_known :: proc(t: ^testing.T) {
	for s in ([]wayu.ShellType{.ZSH, .BASH, .FISH}) {
		testing.expectf(
			t,
			wayu.is_known_init_template(wayu.get_init_template(s)),
			"init template for %v: add its fnv64a hash to KNOWN_INIT_TEMPLATE_HASHES",
			s,
		)
	}
	testing.expect(
		t,
		!wayu.is_known_init_template("# Wayu Shell Initialization\nexport MY_CUSTOM=1\n"),
	)
}

// OKAMI-275: [tools] args become quoted argv words; anything that would run
// code or expand at startup is refused with a reason.
@(test)
test_tool_args_to_shell :: proc(t: ^testing.T) {
	good := [][2]string {
		{"init zsh", "init zsh"},
		{"init zsh --cmd cd", "init zsh --cmd cd"},
		{"init  zsh\t--x=1", "init zsh --x=1"},
		{`init --hook 'a b'`, `init --hook 'a b'`},
		{`init "it's"`, `init 'it'\''s'`},
		{`--opt {a,b}`, `--opt '{a,b}'`},
		{`--config $HOME/x`, `--config "${HOME}/x"`},
		{
			`--config ${XDG_CONFIG_HOME:-$HOME/.config}/t`,
			`--config "${XDG_CONFIG_HOME:-${HOME}/.config}/t"`,
		},
		{`--config ~/t`, `--config "${HOME}/t"`},
		{`'$literal'`, `'$literal'`},
		{"", ""},
	}
	for c in good {
		out, reason, ok := wayu.tool_args_to_shell(c[0])
		defer delete(out)
		testing.expectf(
			t,
			ok && out == c[1],
			"%q -> %q (ok=%v %s), want %q",
			c[0],
			out,
			ok,
			reason,
			c[1],
		)
	}
	bad := []string {
		"init zsh\ntouch /tmp/pwn",
		"init zsh; touch /tmp/pwn",
		"init zsh && x",
		"init | sh",
		"init > /tmp/x",
		"init $(id)",
		"init `id`",
		"init *",
		"init ?",
		"init [ab]",
		`init "$HOME"'$x'`,
		"init 'unterminated",
	}
	for b in bad {
		_, reason, ok := wayu.tool_args_to_shell(b)
		testing.expectf(t, !ok && len(reason) > 0, "%q must be refused", b)
	}
}

// OKAMI-313: core.bash gets `init bash` for `args = "init zsh"` (and core.zsh
// `init zsh` for `init bash`); other words are left alone.
@(test)
test_tool_args_retarget :: proc(t: ^testing.T) {
	cases := [][3]string {
		{"init zsh", "bash", "init bash"},
		{"init zsh --cmd cd", "bash", "init bash --cmd cd"},
		{"completion --zsh", "bash", "completion --bash"},
		{"init bash", "zsh", "init zsh"},
		{"init zshrc 'zsh x'", "bash", "init zshrc 'zsh x'"},
		{"init zsh", "", "init zsh"},
	}
	for c in cases {
		out, reason, ok := wayu.tool_args_to_shell(c[0], retarget = c[1])
		defer delete(out)
		testing.expectf(
			t,
			ok && out == c[2],
			"%q (%s) -> %q (ok=%v %s), want %q",
			c[0],
			c[1],
			out,
			ok,
			reason,
			c[2],
		)
	}
}

// OKAMI-268: fish args are fish-quoted and retargeted to fish.
@(test)
test_tool_args_to_fish :: proc(t: ^testing.T) {
	good := [][2]string {
		{"init zsh", "'init' 'fish'"},
		{"--bash", "'--fish'"},
		{`init bash --cmd 'a b'`, `'init' 'fish' '--cmd' 'a b'`},
		{`init "it's"`, `'init' 'it\'s'`},
		{`--config $HOME/x`, `'--config' "$HOME/x"`},
		{`--config ~/t`, `'--config' "$HOME/t"`},
		{"", ""},
	}
	for c in good {
		out, reason, ok := wayu.tool_args_to_fish(c[0])
		testing.expectf(
			t,
			ok && out == c[1],
			"%q -> %q (ok=%v %s), want %q",
			c[0],
			out,
			ok,
			reason,
			c[1],
		)
	}
	_, reason, ok := wayu.tool_args_to_fish("init $(id)")
	testing.expectf(t, !ok && len(reason) > 0, "command substitution must be refused")
}
