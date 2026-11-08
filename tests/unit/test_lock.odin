package test_wayu

import "core:os"
import "core:testing"
import wayu "../../src"

// OKAMI-274: an [[entries]] block without `name` used to leak its strings
// and metadata map and pass its fields on to the next entry.
@(test)
test_lock_read_drops_nameless_entry :: proc(t: ^testing.T) {
	path := test_tmp("wayu-test-lock-nameless.lock")
	defer os.remove(path)
	content := `version = "1.0.0"

[[entries]]
type = "alias"
value = "stray"
hash = "h0"
[metadata]
k = "v"

[[entries]]
name = "ll"
type = "alias"

[[entries]]
value = "trailing"
`
	_ = os.write_entire_file(path, transmute([]byte)content)

	lock, ok := wayu.lock_read(path)
	defer wayu.lock_cleanup(&lock)
	testing.expect(t, ok)
	testing.expect_value(t, len(lock.entries), 1)
	if len(lock.entries) == 1 {
		e := lock.entries[0]
		testing.expect_value(t, e.name, "ll")
		testing.expect_value(t, e.value, "") // not "stray"
		testing.expect_value(t, e.hash, "")
		testing.expect_value(t, len(e.metadata), 0)
	}
}
