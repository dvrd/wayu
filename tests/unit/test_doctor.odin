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
	testing.expect_value(t, wayu.doctor_expand_path("$WAYU_DOC_TOOLS/bin", consts), "/opt/tools/bin")
	testing.expect_value(t, wayu.doctor_expand_path("${WAYU_DOC_TOOLS}/bin", consts), "/opt/tools/bin")
	testing.expect_value(t, wayu.doctor_expand_path("/usr/bin", consts), "/usr/bin")
	// An unresolved variable yields "" (existence unknown, never "missing").
	testing.expect_value(t, wayu.doctor_expand_path("$WAYU_DOC_SURELY_UNSET_VAR/bin", consts), "")
}
