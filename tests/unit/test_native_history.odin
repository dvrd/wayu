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
