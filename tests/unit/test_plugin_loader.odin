package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_plugin_glob_extension_boundary :: proc(t: ^testing.T) {
	testing.expect(t, wayu.match_simple_glob("plugin.zsh", "*.zsh"))
	testing.expect(t, !wayu.match_simple_glob("plugin.zsh.old", "*.zsh"))
}
