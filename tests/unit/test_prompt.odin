package test_wayu

// Tests for the native zsh prompt generator (prompt.odin): escaping of [prompt] config text, and the async temp-file handling.

import "core:testing"
import "core:strings"
import wayu "../../src"

@(test)
test_prompt_dq_escape :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.prompt_dq_escape(`a"b\c$(id)` + "`x`"), `a\"b\\c\$(id)` + "\\`x\\`")
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

	testing.expect(t, strings.contains(out, `result+="it\"s \$(id -un) "`), "format literal escaped")
	testing.expect(t, strings.contains(out, `%~ \"q\" \$(id)`), "module text escaped, $dir still substituted")
	testing.expect(t, strings.contains(out, `char_symbol="\$(touch x)"`), "character symbol escaped")
	testing.expect(t, !strings.contains(out, `"it"s`), "no raw quote splice")
	testing.expect(t, !strings.contains(out, `echo "$result"`), "print -r, not echo (no backslash escapes)")
}

@(test)
test_prompt_interactive_values_quoted :: proc(t: ^testing.T) {
	toml := `[prompt.interactive]
toggle_key = "^X'; touch pwn; '"
rprompt_format = '[{git_pending} $(id)](242)'
`
	icfg := wayu.parse_interactive_config(toml)
	code := wayu.generate_interactive_prompt("", icfg)
	defer delete(code)

	testing.expect(t, strings.contains(code, `bindkey '^X'\''; touch pwn; '\''' _wayu_toggle_prompt`), "toggle key single-quoted")
	testing.expect(t, strings.contains(code, `git_pending="%F{242}${git_pending} \$(id)%f"`), "rprompt text escaped, token kept")
}

@(test)
test_prompt_async_private_tempdir :: proc(t: ^testing.T) {
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	wayu.generate_async_feature(&sb, 2, "[{git_pending}](242)")
	code := strings.to_string(sb)

	testing.expect(t, !strings.contains(code, ".wayu_async_$$"), "no predictable shared temp file")
	testing.expect(t, strings.contains(code, `mktemp -d "${TMPDIR:-/tmp}/wayu-async.XXXXXX"`), "private 0700 dir via mktemp -d")
	testing.expect(t, strings.contains(code, `mktemp "$dir/.w.XXXXXX"`), "worker writes a fresh (O_EXCL) file")
	testing.expect(t, strings.contains(code, `mv -f "$tmpf" "$dir/data"`), "atomic rename into place")
	testing.expect(t, strings.contains(code, "add-zsh-hook zshexit _wayu_async_cleanup"), "dir removed on shell exit")
}
