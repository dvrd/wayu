package test_wayu

import wayu "../../src"
import "core:os"
import "core:testing"

@(test)
test_history_hides_space_prefixed_records :: proc(t: ^testing.T) {
	path := test_tmp("native-history-private.jsonl")
	defer os.remove(path)

	h := wayu.Native_History {
		path = path,
	}
	defer {
		for cmd in h.commands {
			delete(cmd)
		}

		delete(h.commands)
	}

	testing.expect(t, wayu.native_history_sync(&h, " hidden"))
	testing.expect(t, wayu.native_history_sync(&h, "line one\nline two"))
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(data), "\"line one\\nline two\"\n")
}

@(test)
test_history_window_limits :: proc(t: ^testing.T) {
	path := test_tmp("window.jsonl")
	defer os.remove(path)

	h := wayu.Native_History {
		path        = path,
		entry_limit = 2,
		byte_limit  = 7,
	}
	defer {
		for cmd in h.commands {delete(cmd)}

		delete(h.commands)
	}

	for cmd in ([]string{"large old record", "one", "two", "four"}) {
		testing.expect(t, wayu.native_history_sync(&h, cmd))
	}

	testing.expect_value(t, h.retained, 7)
	testing.expect_value(t, len(h.commands), 2)
	testing.expect_value(t, h.commands[0], "two")
	cmd, _, _, found := wayu.native_history_page(&h, h.offset, true, "old")
	testing.expect(t, found)
	testing.expect_value(t, cmd, "large old record")

	// Replace the file between two recall keystrokes.
	replacement := test_tmp("replacement.jsonl")
	testing.expect(t, os.write_entire_file(replacement, string("\"rotated\"\n")) == nil)
	testing.expect(t, os.rename(replacement, path) == nil)
	latest, _, _, rotated := wayu.native_history_page(&h, h.offset, true)
	testing.expect(t, rotated)
	testing.expect_value(t, latest, "rotated")
	// A second writer can finish a partial JSONL record before the next recall.
	base :: string("\"rotated\"\n")
	testing.expect(t, os.write_entire_file(path, base + "\"pen") == nil)
	testing.expect(t, wayu.native_history_sync(&h))
	testing.expect_value(t, h.offset, i64(len(base)))
	testing.expect(t, os.write_entire_file(path, base + "\"pending\"\n") == nil)
	concurrent, _, _, seen := wayu.native_history_page(&h, h.offset, true)
	testing.expect(t, seen)
	testing.expect_value(t, concurrent, "pending")
	// Truncation in place also invalidates the old offsets.
	testing.expect(t, os.write_entire_file(path, string("\"new\"\n")) == nil)
	newest, _, _, truncated := wayu.native_history_page(&h, h.offset, true)
	testing.expect(t, truncated)
	testing.expect_value(t, newest, "new")
}
