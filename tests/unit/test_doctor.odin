package test_wayu

import "core:os"
import "core:testing"
import wayu "../../src"

@(test)
test_doctor_rc_loads_wayu :: proc(t: ^testing.T) {
	testing.expect(t, wayu.rc_loads_wayu(`source "$HOME/.config/wayu/init.zsh"`))
	testing.expect(t, wayu.rc_loads_wayu(`. "$WAYU/init.bash"`))
	testing.expect(t, wayu.rc_loads_wayu(`eval "$(wayu export --eval)"`))
	testing.expect(t, wayu.rc_loads_wayu(`source "${WAYU_DATA_DIR:-$HOME/.config/wayu}/init.zsh"`))
	testing.expect(t, wayu.rc_loads_wayu("export X=1\nsource ~/.config/wayu/turbo.zsh  # fast\n"))
	testing.expect(t, !wayu.rc_loads_wayu(`# source "$HOME/.config/wayu/init.zsh"`))
	testing.expect(t, !wayu.rc_loads_wayu(`alias w=wayu`))
	testing.expect(t, !wayu.rc_loads_wayu(`source ~/.oh-my-zsh/init.zsh`))
	// OKAMI-272: a line that only mentions the file doesn't load it.
	testing.expect(t, !wayu.rc_loads_wayu(`alias e='vim ~/.config/wayu/init.zsh'`))
	testing.expect(t, !wayu.rc_loads_wayu(`alias s='source ~/.config/wayu/init.zsh'`))
	testing.expect(t, !wayu.rc_loads_wayu(`export WAYU_INIT=~/.config/wayu/init.zsh`))
	testing.expect(t, wayu.rc_loads_wayu(`[ -f ~/.config/wayu/init.zsh ] && source ~/.config/wayu/init.zsh`))
	testing.expect(t, wayu.rc_loads_wayu(`if [ -r "$W/wayu/init.bash" ]; then . "$W/wayu/init.bash"; fi`))
	// turbo_only ignores plain init lines.
	testing.expect(t, !wayu.rc_loads_wayu(`source ~/.config/wayu/init.zsh`, turbo_only = true))
	testing.expect(t, wayu.rc_loads_wayu(`source ~/.config/wayu/turbo.zsh`, turbo_only = true))
}

// OKAMI-176: a later rc line replacing PROMPT_COMMAND drops _wayu_paths_sync.
@(test)
test_doctor_rc_prompt_command_overwrites :: proc(t: ^testing.T) {
	rc := `PROMPT_COMMAND="before"
source "$HOME/.config/wayu/init.bash"
PROMPT_COMMAND="history -a"
export PROMPT_COMMAND='x'
PROMPT_COMMAND="x;$PROMPT_COMMAND"
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}y"
PROMPT_COMMAND+=";z"
# PROMPT_COMMAND=commented
MY_PROMPT_COMMAND=other
echo "$PROMPT_COMMAND=shown"
unset PROMPT_COMMAND
declare -a PROMPT_COMMAND=(a b)
`
	got := wayu.rc_prompt_command_overwrites(rc, context.temp_allocator)
	want := []int{3, 4, 11, 12}
	testing.expectf(t, len(got) == len(want), "got %v, want %v", got, want)
	for n, i in want {
		if i < len(got) { testing.expect_value(t, got[i], n) }
	}
	// No wayu line: nothing to drop.
	testing.expect_value(t, len(wayu.rc_prompt_command_overwrites("PROMPT_COMMAND=x\n", context.temp_allocator)), 0)
}

@(test)
test_doctor_expand_path_uses_toml_env :: proc(t: ^testing.T) {
	consts := []wayu.ConfigEntry{{type = .CONSTANT, name = "WAYU_DOC_TOOLS", value = "/opt/tools"}}
	expect_expand :: proc(t: ^testing.T, path: string, consts: []wayu.ConfigEntry, want: string, loc := #caller_location) {
		got := wayu.doctor_expand_path(path, consts)
		defer if len(got) > 0 do delete(got)
		testing.expect_value(t, got, want, loc)
	}
	expect_expand(t, "$WAYU_DOC_TOOLS/bin", consts, "/opt/tools/bin")
	expect_expand(t, "${WAYU_DOC_TOOLS}/bin", consts, "/opt/tools/bin")
	expect_expand(t, "/usr/bin", consts, "/usr/bin")
	// An unresolved variable yields "" (existence unknown, never "missing").
	expect_expand(t, "$WAYU_DOC_SURELY_UNSET_VAR/bin", consts, "")
}

// A relative entry resolves against the shell's cwd, so doctor (whose cwd is
// arbitrary) must not call it missing — --fix used to delete it.
@(test)
test_doctor_expand_path_relative_is_unresolved :: proc(t: ^testing.T) {
	consts := []wayu.ConfigEntry{{type = .CONSTANT, name = "WAYU_DOC_REL", value = "rel/dir"}}
	testing.expect_value(t, wayu.doctor_expand_path("./node_modules/.bin", consts), "")
	testing.expect_value(t, wayu.doctor_expand_path("bin", consts), "")
	testing.expect_value(t, wayu.doctor_expand_path(".", consts), "")
	// A wayu.toml constant that expands to a relative path is relative too.
	testing.expect_value(t, wayu.doctor_expand_path("$WAYU_DOC_REL/bin", consts), "")
	// ...and so is a process environment variable with a relative value.
	os.set_env("WAYU_DOC_ENV_REL", "rel/env")
	defer os.unset_env("WAYU_DOC_ENV_REL")
	testing.expect_value(t, wayu.doctor_expand_path("$WAYU_DOC_ENV_REL/bin", consts), "")
}
