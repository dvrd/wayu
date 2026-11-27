package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_detached_checkout_is_pinned :: proc(t: ^testing.T) {
	plugin := wayu.PluginMetadata {
		git = {branch = "HEAD"},
	}
	pinned, reason := wayu.plugin_pinned_ref(&plugin)
	testing.expect(t, pinned)
	testing.expect_value(t, reason, "detached HEAD")
}
