package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_plugin_json_depth_ignores_comment_brackets :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		wayu.json5_max_depth(transmute([]byte)string(`{"k":["[[", /* [[ */ {}]}`)),
		3,
	)
}
