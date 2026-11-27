package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_recorded_commit_wins_over_branch :: proc(t: ^testing.T) {
	plugin := wayu.PluginMetadata {
		git = {branch = "stable", commit = "abcdef0"},
	}
	rev, err := wayu.plugin_restore_revision(&plugin)
	testing.expect_value(t, err, "")
	testing.expect_value(t, rev, "abcdef0")
	plugin.git.commit = ""
	rev, err = wayu.plugin_restore_revision(&plugin)
	testing.expect_value(t, err, "")
	testing.expect_value(t, rev, "refs/remotes/origin/stable")
}
