package test_wayu

import wayu "../../src"
import "core:fmt"
import "core:os"
import "core:strings"
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

@(private = "file")
history_destroy :: proc(h: ^wayu.Native_History) {
	for cmd in h.commands {delete(cmd)}

	delete(h.commands)
}

// An append after an interrupted writer leaves only complete records on disk.
@(test)
test_history_append_replaces_partial_tail :: proc(t: ^testing.T) {
	path := test_tmp("partial-tail.jsonl")
	defer os.remove(path)

	testing.expect(t, os.write_entire_file(path, string("\"one\"\n\"tw")) == nil)
	h := wayu.Native_History {
		path = path,
	}
	defer history_destroy(&h)

	testing.expect(t, wayu.native_history_sync(&h, "three"))
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(data), "\"one\"\n\"three\"\n")
	testing.expect_value(t, h.offset, i64(len(data)))
	testing.expect_value(t, strings.join(h.commands[:], "|", context.temp_allocator), "one|three")
}

// A record far beyond the byte limit is not kept in memory, stays on disk and
// can still be recalled.
@(test)
test_history_oversized_record_stays_on_disk :: proc(t: ^testing.T) {
	path := test_tmp("oversized.jsonl")
	defer os.remove(path)

	big := strings.repeat("x", 4096, context.temp_allocator)
	content := fmt.tprintf("\"%s\"\n\"ok\"\n", big)
	testing.expect(t, os.write_entire_file(path, content) == nil)
	h := wayu.Native_History {
		path       = path,
		byte_limit = 4,
	}
	defer history_destroy(&h)

	testing.expect(t, wayu.native_history_sync(&h))
	testing.expect_value(t, strings.join(h.commands[:], "|", context.temp_allocator), "ok")
	testing.expect_value(t, h.offset, i64(len(content)))

	testing.expect(t, wayu.native_history_sync(&h, "next"))
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(data), fmt.tprintf("%s\"next\"\n", content))

	cmd, start, end, found := wayu.native_history_page(&h, h.offset, true, "xxxx")
	testing.expect(t, found)
	testing.expect_value(t, cmd, big)
	testing.expect_value(t, start, 0)
	testing.expect_value(t, end, 4099)
}

// Two sessions append to one file. Each reads the other's records before it
// writes, so the file holds every record once and in order.
@(test)
test_history_two_sessions_share_one_file :: proc(t: ^testing.T) {
	path := test_tmp("sessions.jsonl")
	defer os.remove(path)

	a := wayu.Native_History {
		path        = path,
		entry_limit = 3,
	}
	defer history_destroy(&a)

	b := wayu.Native_History {
		path        = path,
		entry_limit = 3,
	}
	defer history_destroy(&b)

	testing.expect(t, wayu.native_history_sync(&a, "a1"))
	testing.expect(t, wayu.native_history_sync(&b, "b1"))
	testing.expect(t, wayu.native_history_sync(&a, "a2"))
	testing.expect(t, wayu.native_history_sync(&b, "b2"))
	testing.expect(t, wayu.native_history_sync(&a))

	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(data), "\"a1\"\n\"b1\"\n\"a2\"\n\"b2\"\n")
	for h in ([]^wayu.Native_History{&a, &b}) {
		testing.expect_value(t, h.offset, i64(len(data)))
		testing.expect_value(
			t,
			strings.join(h.commands[:], "|", context.temp_allocator),
			"b1|a2|b2",
		)
	}

	// Recall walks the whole file newest first, past the resident window.
	pos := a.offset
	for want in ([]string{"b2", "a2", "b1", "a1"}) {
		cmd, start, _, found := wayu.native_history_page(&a, pos, true)
		testing.expect(t, found)
		testing.expect_value(t, cmd, want)
		pos = start
	}

	_, _, _, more := wayu.native_history_page(&a, pos, true)
	testing.expect(t, !more)
}

@(private = "file")
Saved_Env :: struct {
	key, value: string,
	set:        bool,
}

@(private = "file")
set_test_env :: proc(key, value: string) -> Saved_Env {
	old, set := os.lookup_env(key, context.temp_allocator)
	os.set_env(key, value)
	return {key, old, set}
}

@(private = "file")
restore_test_env :: proc(saved: Saved_Env) {
	if saved.set {
		os.set_env(saved.key, saved.value)
	} else {
		os.unset_env(saved.key)
	}
}

// The launching shell's history, decoded as that shell stores it. Returns the
// commands joined by "|".
@(private = "file")
foreign_history :: proc(ext, content: string, byte_limit := 0, entry_limit := 0) -> string {
	root := test_tmp("foreign-history")
	os.make_directory_all(fmt.tprintf("%s/fish", root))
	path := fmt.tprintf("%s/history", root)
	if ext == "fish" {
		path = fmt.tprintf("%s/fish/fish_history", root)
	}

	if os.write_entire_file(path, content) != nil {
		return "<fixture not written>"
	}
	defer os.remove(path)

	saved_ext := wayu.wayu.shell_ext
	wayu.wayu.shell_ext = ext
	defer wayu.wayu.shell_ext = saved_ext

	saved := [?]Saved_Env {
		set_test_env("HISTFILE", path),
		set_test_env("XDG_DATA_HOME", root),
		set_test_env("fish_history", "fish"),
	}
	defer for entry in saved {restore_test_env(entry)}

	commands := wayu.native_read_shell_history(byte_limit, entry_limit)
	defer {
		for cmd in commands {delete(cmd)}

		delete(commands)
	}

	return strings.join(commands, "|", context.temp_allocator)
}

@(test)
test_foreign_history_decodes_each_shell_format :: proc(t: ^testing.T) {
	metafied := []u8{0xc4, 0x83, 0xa3}
	zsh := strings.concatenate(
		{
			": 1700000000:0;echo extended\n",
			"echo plain\n",
			": 1700000001:5;echo first \\\n",
			"second line\n",
			" echo private\n",
			"echo ",
			string(metafied),
			"\n",
			": not a timestamp;kept as typed\n",
		},
		context.temp_allocator,
	)
	testing.expect_value(
		t,
		foreign_history("zsh", zsh),
		"echo extended|echo plain|echo first \nsecond line|echo ă|: not a timestamp;kept as typed",
	)

	bash := "echo plain\n#1700000000\necho multi\nsecond\n\nthird\n#1700000001\n#1700000002\necho last\n"
	testing.expect_value(
		t,
		foreign_history("bash", bash),
		"echo plain|echo multi\nsecond\n\nthird|echo last",
	)

	fish := "- cmd: echo one\n  when: 1700000000\n- cmd: echo two\\nsecond \\\\ slash\n  when: 1700000001\n  paths:\n    - foo\n"
	testing.expect_value(t, foreign_history("fish", fish), "echo one|echo two\nsecond \\ slash")
}

// The same windows apply to the launching shell's history. A physical line
// far beyond the byte limit is dropped with its continuation lines.
@(test)
test_foreign_history_window_limits :: proc(t: ^testing.T) {
	long := strings.repeat("y", 200, context.temp_allocator)
	zsh := strings.concatenate(
		{"echo ok\n", long, "\\\n", "tail\n", "ls\n", "pwd\n"},
		context.temp_allocator,
	)
	testing.expect_value(t, foreign_history("zsh", zsh, byte_limit = 8), "ls|pwd")
	testing.expect_value(t, foreign_history("zsh", zsh, entry_limit = 1), "pwd")

	bash := "echo plain\n#1700000000\necho multi\nsecond\n#1700000001\necho last\n"
	testing.expect_value(
		t,
		foreign_history("bash", bash, entry_limit = 2),
		"echo multi\nsecond|echo last",
	)
	testing.expect_value(t, foreign_history("bash", bash, byte_limit = 10), "echo last")
}
