package test_wayu

// Tests for the native zsh prompt generator (prompt.odin): opt-in gate,
// escaping of [prompt] config text, and the async temp-file handling.

import wayu "../../src"
import "core:strings"
import "core:testing"

@(test)
test_prompt_is_enabled_opt_in :: proc(t: ^testing.T) {
	testing.expect(t, !wayu.prompt_is_enabled(""), "no config -> off")
	testing.expect(t, !wayu.prompt_is_enabled("[aliases]\nll = \"ls\"\n"), "no [prompt] -> off")
	testing.expect(
		t,
		!wayu.prompt_is_enabled("[prompt]\nformat = \"{dir}\"\n"),
		"[prompt] without enabled -> off",
	)
	testing.expect(
		t,
		!wayu.prompt_is_enabled("[prompt]\nenabled = false\n"),
		"enabled = false -> off",
	)
	testing.expect(
		t,
		!wayu.prompt_is_enabled("[prompt.interactive]\nenabled = true\n"),
		"enabled in a subtable doesn't count",
	)
	testing.expect(
		t,
		!wayu.prompt_is_enabled("[settings]\nenabled = true\n[prompt]\n"),
		"enabled in another table doesn't count",
	)
	testing.expect(
		t,
		wayu.prompt_is_enabled("[prompt]\nformat = \"x\"\nenabled = true\n"),
		"enabled = true -> on",
	)
	testing.expect(
		t,
		wayu.prompt_is_enabled("[prompt]\n  enabled=true # opt in\n"),
		"comment and spacing tolerated",
	)
}

@(test)
test_prompt_dq_escape :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		wayu.prompt_dq_escape(`a"b\c$(id)` + "`x`"),
		`a\"b\\c\$(id)` + "\\`x\\`",
	)
	testing.expect_value(t, wayu.prompt_dq_escape("%n ➜"), "%n ➜")
}

@(test)
test_prompt_config_text_is_escaped :: proc(t: ^testing.T) {
	toml := `[prompt]
enabled = true
format = 'it"s $(id -un) {dir} {character}'

[prompt.character]
success_symbol = "[$(touch x)](green)"

[prompt.dir]
format = '[$dir "q" $(id)](cyan)'
`
	cfg := wayu.parse_full_prompt_config(toml)
	defer wayu.destroy_full_prompt_config(&cfg)
	out := wayu.generate_full_prompt(cfg)
	defer delete(out)

	testing.expect(
		t,
		strings.contains(out, `result+="it\"s \$(id -un) "`),
		"format literal escaped",
	)
	testing.expect(
		t,
		strings.contains(out, `%~ \"q\" \$(id)`),
		"module text escaped, $dir still substituted",
	)
	testing.expect(
		t,
		strings.contains(out, `char_symbol="\$(touch x)"`),
		"character symbol escaped",
	)
	testing.expect(t, !strings.contains(out, `"it"s`), "no raw quote splice")
	testing.expect(
		t,
		!strings.contains(out, `echo "$result"`),
		"print -r, not echo (no backslash escapes)",
	)
}

@(test)
test_prompt_interactive_values_quoted :: proc(t: ^testing.T) {
	toml := `[prompt.interactive]
toggle_enabled = true
toggle_key = "^X'; touch pwn; '"
rprompt_format = '[{git_pending} $(id)](242)'
`
	icfg := wayu.parse_interactive_config(toml)
	code := wayu.generate_interactive_prompt("", icfg)
	defer delete(code)

	testing.expect(
		t,
		strings.contains(code, `bindkey -M emacs '^X'\''; touch pwn; '\''' _wayu_toggle_prompt`),
		"toggle key single-quoted",
	)
	testing.expect(
		t,
		strings.contains(code, `git_pending="%F{242}${git_pending} \$(id)%f"`),
		"rprompt text escaped, token kept",
	)
}

@(test)
test_prompt_async_private_tempdir :: proc(t: ^testing.T) {
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	wayu.generate_async_feature(&sb, "[{git_pending}](242)")
	code := strings.to_string(sb)

	testing.expect(t, !strings.contains(code, ".wayu_async_$$"), "no predictable shared temp file")
	testing.expect(
		t,
		strings.contains(code, `zf_mkdir -m 700 -- "$_d"`),
		"private 0700 dir, builtin mkdir (no fork)",
	)
	testing.expect(
		t,
		strings.contains(code, `mktemp -d "${TMPDIR:-/tmp}/wayu-async.XXXXXX"`),
		"mktemp -d fallback without zsh/files",
	)
	testing.expect(
		t,
		strings.contains(code, "_wayu_async_worker &!") &&
		!strings.contains(code, "(_wayu_async_worker &)"),
		"worker started with one fork",
	)
	testing.expect(
		t,
		strings.contains(code, `mktemp "$dir/.w.XXXXXX"`),
		"worker writes a fresh (O_EXCL) file",
	)
	testing.expect(
		t,
		strings.contains(code, `mv -f -- "$tmpf" "$dir/data"`),
		"atomic rename into place",
	)
	testing.expect(
		t,
		strings.contains(code, "add-zsh-hook zshexit _wayu_async_cleanup"),
		"dir removed on shell exit",
	)
}

// GEN-19: the toggle is opt-in, bound after `bindkey -v` and in explicit
// keymaps (it used to land in the emacs map, then reset by `bindkey -v`).
@(test)
test_prompt_toggle_keymap :: proc(t: ^testing.T) {
	{
		icfg := wayu.parse_interactive_config("")
		code := wayu.generate_interactive_prompt("", icfg)
		defer delete(code)
		testing.expect(
			t,
			!strings.contains(code, "_wayu_toggle_prompt"),
			"toggle disabled by default",
		)
	}
	{
		icfg := wayu.parse_interactive_config(
			"[prompt]\nvi_mode = true\n\n[prompt.interactive]\ntoggle_enabled = true\n",
		)
		code := wayu.generate_interactive_prompt("", icfg)
		defer delete(code)
		vi := strings.index(code, "bindkey -v")
		bind := strings.index(code, "bindkey -M viins '^P' _wayu_toggle_prompt")
		testing.expect(t, vi >= 0 && bind > vi, "toggle bound in viins after bindkey -v")
		testing.expect(
			t,
			strings.contains(code, "bindkey -M vicmd '^P' _wayu_toggle_prompt"),
			"and in vicmd",
		)
		testing.expect(
			t,
			!strings.contains(code, "bindkey '^P'"),
			"never into the current main keymap",
		)
	}
	{
		icfg := wayu.parse_interactive_config(
			"[prompt.interactive]\ntoggle_enabled = true\nvi_mode_indicator = false\n",
		)
		code := wayu.generate_interactive_prompt("", icfg)
		defer delete(code)
		testing.expect(
			t,
			strings.contains(code, "bindkey -M emacs '^P' _wayu_toggle_prompt"),
			"emacs keymap without vi mode",
		)
		testing.expect(t, !strings.contains(code, "bindkey -v"), "no vi keymap forced")
	}
}

// GEN-26: default modules carry separators; the user name only shows over
// SSH / as root unless [prompt.username] show_always = true.
@(test)
test_prompt_default_separators_and_username :: proc(t: ^testing.T) {
	{
		cfg := wayu.parse_full_prompt_config("[prompt]\nenabled = true\n")
		defer wayu.destroy_full_prompt_config(&cfg)
		out := wayu.generate_full_prompt(cfg)
		defer delete(out)
		testing.expect(t, strings.contains(out, `%~%f "`), "dir followed by a space")
		testing.expect(t, strings.contains(out, `result+="on %`), "git branch prefixed with 'on '")
		testing.expect(
			t,
			strings.contains(
				out,
				`if [[ -n "${SSH_CONNECTION-}${SSH_CLIENT-}${SSH_TTY-}" ]] || (( EUID == 0 )); then`,
			),
			"username gated on ssh/root",
		)
	}
	{
		cfg := wayu.parse_full_prompt_config(
			"[prompt]\nenabled = true\n\n[prompt.username]\nshow_always = true\n",
		)
		defer wayu.destroy_full_prompt_config(&cfg)
		out := wayu.generate_full_prompt(cfg)
		defer delete(out)
		testing.expect(
			t,
			!strings.contains(out, "SSH_CONNECTION"),
			"show_always shows the user name unconditionally",
		)
		testing.expect(t, strings.contains(out, "%n"), "user name still rendered")
	}
}

// OKAMI-279: generated prompt code never calls git/awk/sed/... bare, so a
// user alias or function of that name can't change or break it.
@(test)
test_prompt_external_commands_use_command :: proc(t: ^testing.T) {
	cfg := wayu.parse_full_prompt_config(
		"[prompt]\nenabled = true\nformat = \"{localip}{git_branch}\"\n",
	)
	defer wayu.destroy_full_prompt_config(&cfg)
	base := wayu.generate_full_prompt(cfg)
	defer delete(base)
	icfg := wayu.parse_interactive_config("")
	code := wayu.generate_interactive_prompt(base, icfg)
	defer delete(code)

	for bad in ([]string {
			"(git ",
			"| awk ",
			"| sed ",
			"| head ",
			"| wc ",
			"| tr ",
			"$(mktemp ",
			"    rm -",
			"&& rm ",
			"|| ip ",
			"$(ipconfig ",
		}) {
		testing.expectf(
			t,
			!strings.contains(code, bad),
			"bare external command %q in prompt code",
			bad,
		)
	}
	testing.expect(
		t,
		!strings.contains(code, "git rev-parse"),
		"branch read without forking git (OKAMI-285)",
	)
	testing.expect(
		t,
		strings.contains(
			code,
			"command go version 2>/dev/null | command awk '{print $3}' | command sed 's/go//'",
		),
		"version pipeline via command",
	)
}

// Field-by-field coverage of parse_full_prompt_config (OKAMI-277 split).
@(test)
test_prompt_parse_full_config_fields :: proc(t: ^testing.T) {
	toml := `[prompt]
enabled = true
format = "{dir}{character}"

[prompt.character]
success_symbol = "[> ](green)"
error_symbol = "[x](red)"
vimcmd_symbol = "[N](blue)"
vimcmd_visual_symbol = "[V](blue)"
vimcmd_replace_symbol = "[R](blue)"

[prompt.username]
show_always = true
format = "[$user](red) @ "

[prompt.hostname]
format = "<$hostname>"

[prompt.localip]
format = '($localip)'

[prompt.dir]
format = "[$dir](blue) "

[prompt.git_branch]
format = "br:$branch "

[prompt.contexts]
go = { format = "go $version", detect = ["go.mod", "*.go"] }
rust = { format = "rs", detect = ["Cargo.toml"] }
go = { format = "go2", detect = ["go.work"] }

[other]
format = "ignored"
`
	cfg := wayu.parse_full_prompt_config(toml)
	defer wayu.destroy_full_prompt_config(&cfg)

	testing.expect_value(t, cfg.format, "{dir}{character}")
	testing.expect_value(t, cfg.character_success, ">")
	testing.expect_value(t, cfg.character_error, "x")
	testing.expect_value(t, cfg.vimcmd_symbol, "N")
	testing.expect_value(t, cfg.vimcmd_visual_symbol, "V")
	testing.expect_value(t, cfg.vimcmd_replace_symbol, "R")
	testing.expect_value(t, cfg.username_show_always, true)
	testing.expect_value(t, cfg.username_format, "[$user](red) @ ")
	testing.expect_value(t, cfg.hostname_format, "<$hostname>")
	testing.expect_value(t, cfg.localip_format, "($localip)")
	testing.expect_value(t, cfg.dir_format, "[$dir](blue) ")
	testing.expect_value(t, cfg.git_branch_format, "br:$branch ")

	testing.expect_value(t, len(cfg.context_order), 2)
	if len(cfg.context_order) == 2 {
		testing.expect_value(t, cfg.context_order[0], "go")
		testing.expect_value(t, cfg.context_order[1], "rust")
	}
	testing.expect_value(t, cfg.context_formats["go"], "go2")
	testing.expect_value(t, cfg.context_formats["rust"], "rs")
	go_detect := cfg.context_detects["go"]
	testing.expect_value(t, len(go_detect), 1)
	if len(go_detect) == 1 {
		testing.expect_value(t, go_detect[0], "go.work")
	}
	testing.expect_value(t, len(cfg.context_detects["rust"]), 1)
}

// OKAMI-285: vi mode is opt-in ([prompt] vi_mode = true); without it the
// prompt never touches the keymap or KEYTIMEOUT. With it, zle-line-init and
// zle-keymap-select are chained to existing widgets, not replaced.
@(test)
test_prompt_vi_mode_opt_in_and_chained :: proc(t: ^testing.T) {
	{
		icfg := wayu.parse_interactive_config("[prompt]\nenabled = true\n")
		code := wayu.generate_interactive_prompt("", icfg)
		defer delete(code)
		testing.expect(t, !icfg.vi_mode, "vi_mode defaults to false")
		testing.expect(t, !strings.contains(code, "bindkey -v"), "keymap untouched by default")
		testing.expect(t, !strings.contains(code, "KEYTIMEOUT"), "KEYTIMEOUT untouched by default")
		testing.expect(
			t,
			!strings.contains(code, "zle-keymap-select"),
			"no keymap widget by default",
		)
		testing.expect(
			t,
			strings.contains(code, `typeset -g _WAYU_VI_MODE=""`),
			"character module follows exit status",
		)
	}
	{
		icfg := wayu.parse_interactive_config("[prompt]\nenabled = true\nvi_mode = true # vi\n")
		code := wayu.generate_interactive_prompt("", icfg)
		defer delete(code)
		testing.expect(t, icfg.vi_mode, "vi_mode = true parsed (inline comment ok)")
		testing.expect(t, strings.contains(code, "bindkey -v"), "vi keymap")
		testing.expect(
			t,
			strings.contains(code, "KEYTIMEOUT=1") && !strings.contains(code, "export KEYTIMEOUT"),
			"KEYTIMEOUT set, not exported",
		)
		testing.expect(
			t,
			strings.contains(code, `zle -A "$1" "_wayu_prev_$1"`),
			"existing widget kept",
		)
		testing.expect(
			t,
			strings.contains(code, "_wayu_zle_chain zle-keymap-select _wayu_zle_keymap_select"),
			"keymap-select chained",
		)
		testing.expect(
			t,
			strings.contains(code, "_wayu_zle_chain zle-line-init _wayu_zle_line_init"),
			"line-init chained",
		)
		testing.expect(
			t,
			!strings.contains(code, "zle -N zle-line-init zle-keymap-select"),
			"no plain replacement",
		)
	}
	{
		icfg := wayu.parse_interactive_config(
			"[prompt]\nvi_mode = true\n\n[prompt.interactive]\nvi_mode_indicator = false\n",
		)
		code := wayu.generate_interactive_prompt("", icfg)
		defer delete(code)
		testing.expect(t, strings.contains(code, "bindkey -v"), "vi keymap without the indicator")
		testing.expect(t, !strings.contains(code, "_wayu_zle_chain"), "no indicator widgets")
	}
	{
		// sub-table keys don't count as [prompt] keys
		v, found := wayu.prompt_table_bool("[prompt.interactive]\nvi_mode = true\n", "vi_mode")
		testing.expect(t, !v && !found, "only keys directly under [prompt]")
	}
}
