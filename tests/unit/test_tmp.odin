package test_wayu

import "base:runtime"
import "core:fmt"
import "core:os"

// test_tmp returns <root>/<name> for a test's scratch files and dirs.
//
// The root is per process, so concurrent unit-test runs (other worktrees,
// CI matrix jobs on one host) never share a path: ./build_it test sets
// WAYU_TEST_TMPDIR inside its HOME sandbox and removes it afterwards;
// otherwise it is /tmp/wayu-unit-<pid>. Never use a fixed /tmp path.
//
// The string lives until the process exits (heap, outside the per-test
// tracking allocator), so it is safe to store in wayu.wayu.config/data even
// if code under test frees the temp allocator.
test_tmp :: proc(name: string) -> string {
	heap := runtime.heap_allocator()
	if len(test_tmp_root) == 0 {
		root, ok := os.lookup_env("WAYU_TEST_TMPDIR", heap)
		if !ok || len(root) == 0 {
			root = fmt.aprintf("/tmp/wayu-unit-%d", os.get_pid(), allocator = heap)
		}
		test_tmp_root = root
	}
	os.make_directory_all(test_tmp_root)
	return fmt.aprintf("%s/%s", test_tmp_root, name, allocator = heap)
}

@(private = "file")
test_tmp_root: string
