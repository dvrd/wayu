package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_local_binding_overwrite_and_forget :: proc(t: ^testing.T) {
	s: wayu.Native_Session
	defer delete(s.locals)

	wayu.native_store(&s.locals, "answer", "old")
	wayu.native_store(&s.locals, "answer", "new")
	testing.expect_value(t, wayu.native_value(&s, "answer"), "new")
	wayu.native_forget(&s.locals, "answer")
	testing.expect(t, "answer" not_in s.locals)
}

@(test)
test_capture_accounting :: proc(t: ^testing.T) {
	testing.expect(t, wayu.native_capture_fits(8192, 8191, 1))
	testing.expect(t, !wayu.native_capture_fits(8192, 8191, 2))
	testing.expect(t, !wayu.native_capture_fits(max(int), max(int) - 1, 2))
	testing.expect(t, wayu.native_capture_fits(0, 8192, 8192))
}
