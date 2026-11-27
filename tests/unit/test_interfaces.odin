package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_line_iterator_empty_and_unterminated_lines :: proc(t: ^testing.T) {
	it := wayu.make_line_iter("\na")
	for expected in ([]string{"", "a"}) {
		line, ok := wayu.line_iter_next(&it)
		testing.expect(t, ok)
		testing.expect_value(t, line, expected)
	}

	_, more := wayu.line_iter_next(&it)
	testing.expect(t, !more)
}
