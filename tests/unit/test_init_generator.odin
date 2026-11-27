package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_custom_init_template_preserved :: proc(t: ^testing.T) {
	testing.expect(t, !wayu.is_known_init_template("# user startup\nsource ./custom.zsh\n"))
}
