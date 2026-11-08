package test_wayu

import "core:testing"
import wayu "../../src"

@(test)
test_doctor_rc_loads_wayu :: proc(t: ^testing.T) {
	testing.expect(t, wayu.rc_loads_wayu(`source "$HOME/.config/wayu/init.zsh"`))
	testing.expect(t, wayu.rc_loads_wayu(`. "$WAYU/init.bash"`))
	testing.expect(t, wayu.rc_loads_wayu(`eval "$(wayu build eval)"`))
	testing.expect(t, wayu.rc_loads_wayu("export X=1\nsource ~/.config/wayu/turbo.zsh  # fast\n"))
	testing.expect(t, !wayu.rc_loads_wayu(`# source "$HOME/.config/wayu/init.zsh"`))
	testing.expect(t, !wayu.rc_loads_wayu(`alias w=wayu`))
	testing.expect(t, !wayu.rc_loads_wayu(`source ~/.oh-my-zsh/init.zsh`))
	// turbo_only ignores plain init lines.
	testing.expect(t, !wayu.rc_loads_wayu(`source ~/.config/wayu/init.zsh`, turbo_only = true))
	testing.expect(t, wayu.rc_loads_wayu(`source ~/.config/wayu/turbo.zsh`, turbo_only = true))
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
}
