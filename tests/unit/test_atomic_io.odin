package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_atomic_write_missing_parent :: proc(t: ^testing.T) {
	path := test_tmp("absent-parent/entry")
	testing.expect(t, wayu.write_file_atomic(path, {1, 2}) != nil)
}
