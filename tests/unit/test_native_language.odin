package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_quoted_keyword_is_an_ordinary_word :: proc(t: ^testing.T) {
	source := `'if' true`
	parts := wayu.shell_parse_statements(source, .POSIX, true)
	defer wayu.shell_statements_destroy(&parts)

	parser := wayu.native_parser(nil, source, parts[:])
	testing.expect_value(t, wayu.native_keyword(&parser), "")
	testing.expect_value(t, wayu.native_keyword(&parser, 1), "true")
}
