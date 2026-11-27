package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_turbo_file_tracks_active_shell :: proc(t: ^testing.T) {
	saved := wayu.wayu.shell
	defer wayu.wayu.shell = saved

	wayu.wayu.shell = .FISH
	testing.expect_value(t, wayu.turbo_export_file_name(), "turbo.fish")
	wayu.wayu.shell = .BASH
	testing.expect_value(t, wayu.turbo_export_file_name(), "turbo.bash")
}
