package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_split_paste_terminator_remains_buffered :: proc(t: ^testing.T) {
	body, consumed, done := wayu.scan_paste_chunk(transmute([]u8)string("abc\x1b[20"))
	testing.expect(t, !done)
	testing.expect_value(t, string(body), "abc")
	testing.expect_value(t, consumed, 3)
}
