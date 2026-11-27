package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_node_extensions_share_compiler_configuration :: proc(t: ^testing.T) {
	js := wayu.script_lang_by_ext("js")
	testing.expect(t, js != nil)
	testing.expect(t, wayu.script_lang_by_ext("cjs") == js)
	testing.expect(t, wayu.script_lang_by_ext("mjs") == js)
}
