package wayu

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:unicode/utf8"

Native_History :: struct {
	path:                              string,
	commands:                          [dynamic]string,
	shell_commands:                    []string,
	offset:                            i64,
	inode:                             u64,
	byte_limit, entry_limit, retained: int,
}

native_history_retain :: proc(h: ^Native_History, cmd: string) {
	if cmd == "" || (h.byte_limit > 0 && len(cmd) > h.byte_limit) {
		return
	}

	for len(h.commands) > 0 &&
	    ((h.entry_limit > 0 && len(h.commands) >= h.entry_limit) ||
			    (h.byte_limit > 0 && h.retained > h.byte_limit - len(cmd))) {
		h.retained -= len(h.commands[0])
		delete(h.commands[0])
		ordered_remove(&h.commands, 0)
	}

	append(&h.commands, strings.clone(cmd))
	h.retained += len(cmd)
}

native_history_encoded_limit :: proc(bytes: int) -> int {
	// JSON permits six ASCII bytes per escaped source byte, plus the two quotes.
	if bytes <= 0 || bytes > (max(int) - 2) / 6 {
		return max(int)
	}

	return 6 * bytes + 2
}

// A lock covers the entire offset check and the subsequent reads or append.
native_history_open :: proc(path: string) -> posix.FD {
	fd := posix.open(
		strings.clone_to_cstring(path, context.temp_allocator),
		{.RDWR, .CREAT, .NOFOLLOW, .CLOEXEC, .NONBLOCK},
		transmute(posix.mode_t)posix._mode_t(0o600),
	)
	if fd < 0 {
		return -1
	}

	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) || st.st_uid != posix.geteuid() {
		posix.close(fd)
		return -1
	}

	for posix.lockf(fd, .LOCK, 0) != .OK {
		if posix.errno() != .EINTR {
			posix.close(fd)
			return -1
		}
	}

	return fd
}

// Keep each command, including embedded newlines, on one physical record.
// Writers and readers take the same whole-file lock before appending or
// consuming new records from concurrent sessions.
native_history_sync :: proc(h: ^Native_History, record: string = "") -> bool {
	if h.path == "" {
		if make_wayu_dir(wayu.data) != nil {
			return false
		}
		h.path = fmt.aprintf("%s/history.jsonl", wayu.data)
	}
	fd := native_history_open(h.path)
	if fd < 0 {
		return false
	}
	defer posix.close(fd)

	return native_history_sync_fd(h, fd, record)
}

native_history_sync_fd :: proc(h: ^Native_History, fd: posix.FD, record: string) -> bool {
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK {
		return false
	}
	if h.inode != u64(st.st_ino) || h.offset > i64(st.st_size) {
		for cmd in h.commands {delete(cmd)}
		clear(&h.commands)
		h.retained = 0
		h.offset = 0
		h.inode = u64(st.st_ino)
	}
	if posix.lseek(fd, auto_cast h.offset, .SET) < 0 {
		return false
	}
	partial := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&partial)

	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil {
		return false
	}
	defer virtual.arena_destroy(&scratch)

	context.temp_allocator = virtual.arena_allocator(&scratch)

	raw_length: i64
	encoded_limit := native_history_encoded_limit(h.byte_limit)
	block: [8192]u8
	for {
		n := posix.read(fd, &block[0], len(block))
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		if n < 0 {
			return false
		}
		if n == 0 {
			break
		}
		for ch in block[:n] {
			if ch != '\n' {
				raw_length += 1
				if raw_length <= i64(encoded_limit) {
					strings.write_byte(&partial, ch)
				}

				continue
			}
			data := strings.to_string(partial)
			name: string
			if raw_length <= i64(encoded_limit) &&
			   json.unmarshal(
				   transmute([]u8)data,
				   &name,
				   allocator = virtual.arena_allocator(&scratch),
			   ) ==
				   nil &&
			   name != "" {
				native_history_retain(h, name)
			}
			h.offset += raw_length + 1
			raw_length = 0
			virtual.arena_free_all(&scratch)
			strings.builder_reset(&partial)
		}
	}
	if len(record) == 0 || record[0] == ' ' {
		return true
	}
	encoded, err := json.marshal(record, allocator = context.temp_allocator)
	if err != nil {
		return false
	}
	// Replace an incomplete trailing record left by an interrupted writer.
	if posix.lseek(fd, auto_cast h.offset, .SET) < 0 ||
	   posix.ftruncate(fd, auto_cast h.offset) != .OK {
		return false
	}
	line := fmt.tprintf("%s\n", string(encoded))
	for remaining := transmute([]u8)line; len(remaining) > 0; {
		n := posix.write(fd, raw_data(remaining), c.size_t(len(remaining)))
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		if n <= 0 {
			return false
		}
		remaining = remaining[n:]
	}
	h.offset += i64(len(line))
	native_history_retain(h, record)
	return true
}

// Offsets identify physical JSONL records. Walking an old page reads one block at a time
// and materializes only the candidate currently being decoded. The current editable line
// has a distinct lifetime from the history window.
native_history_page :: proc(
	h: ^Native_History,
	from: i64,
	backwards: bool,
	query := "",
) -> (
	cmd: string,
	start, end: i64,
	found: bool,
) {
	fd := native_history_open(h.path)
	if fd < 0 {
		return
	}
	defer posix.close(fd)

	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK {
		return
	}

	pos := from
	if h.inode != u64(st.st_ino) || h.offset != i64(st.st_size) {
		restart :=
			h.inode != u64(st.st_ino) ||
			h.offset > i64(st.st_size) ||
			from == h.offset && backwards
		if !native_history_sync_fd(h, fd, "") {
			return
		}

		if restart {
			pos = h.offset if backwards else 0
		}
	}

	pos = clamp(pos, i64(0), h.offset)
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil {
		return
	}
	defer virtual.arena_destroy(&scratch)

	result_allocator := context.temp_allocator
	context.temp_allocator = virtual.arena_allocator(&scratch)
	block: [8192]u8
	for (backwards && pos > 0) || (!backwards && pos < h.offset) {
		start, end = pos, pos
		if backwards {
			end = pos
			seek := pos - 1
			scan: for seek > 0 {
				base := max(i64(0), seek - len(block))
				n := int(seek - base)
				if posix.pread(fd, &block[0], auto_cast n, auto_cast base) != n {
					return
				}

				#reverse for ch, j in block[:n] {
					if ch == '\n' {
						start = base + i64(j) + 1
						break scan
					}
				}

				seek = base
				start = seek
			}

			if pos == 1 {
				start = 0
			}

			pos = start
		} else {
			seek := pos
			forward_scan: for seek < h.offset {
				n := int(min(i64(len(block)), h.offset - seek))
				if posix.pread(fd, &block[0], auto_cast n, auto_cast seek) != n {
					return
				}

				for ch, j in block[:n] {
					if ch == '\n' {
						end = seek + i64(j) + 1
						break forward_scan
					}
				}

				seek += i64(n)
			}

			if end <= start {
				return
			}

			pos = end
		}

		n := int(end - start - 1)
		if n <= 0 {
			continue
		}

		virtual.arena_free_all(&scratch)
		alloc := virtual.arena_allocator(&scratch)
		data := make([]u8, n, alloc)
		count := 0
		for count < n {
			got := posix.pread(
				fd,
				&data[count],
				auto_cast (n - count),
				auto_cast (start + i64(count)),
			)
			if got < 0 && posix.errno() == .EINTR {
				continue
			}

			if got <= 0 {
				return
			}

			count += int(got)
		}

		parsed: string
		if json.unmarshal(data, &parsed, allocator = alloc) == nil &&
		   parsed != "" &&
		   strings.contains(parsed, query) {
			return strings.clone(parsed, result_allocator), start, end, true
		}
	}

	return
}

// Shell history is a read-only suggestion source. Recall and recording retain
// their native session semantics and never rewrite the launching shell's file.
native_read_shell_history :: proc(byte_limit, entry_limit: int) -> []string {
	path := os.get_env("HISTFILE", context.temp_allocator)
	switch wayu.shell_ext {
	case "zsh", "bash":
		if path == "" {
			path = fmt.tprintf("%s/.%s_history", wayu.home, wayu.shell_ext)
		}
	case "fish":
		root := os.get_env("XDG_DATA_HOME", context.temp_allocator)
		if root == "" {
			root = fmt.tprintf("%s/.local/share", wayu.home)
		}

		name := os.get_env("fish_history", context.temp_allocator)
		if name == "" {
			name = "fish"
		}

		path = fmt.tprintf("%s/fish/%s_history", root, name)
	case:
		return nil
	}

	if !os.is_file(path) {
		return nil
	}

	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.NONBLOCK, .CLOEXEC})
	if fd < 0 {
		return nil
	}
	defer posix.close(fd)

	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) {
		return nil
	}

	reader := Foreign_History_Reader {
		history = {byte_limit = byte_limit, entry_limit = entry_limit},
		record = strings.builder_make(context.allocator),
	}
	defer strings.builder_destroy(&reader.record)

	line := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&line)

	block: [8192]u8
	limit := native_history_encoded_limit(byte_limit)
	long := false
	for {
		n := posix.read(fd, &block[0], len(block))
		if n < 0 && posix.errno() == .EINTR {
			continue
		}

		if n <= 0 {
			break
		}

		for ch in block[:n] {
			if ch == '\n' {
				foreign_history_line(&reader, strings.to_string(line), long)
				strings.builder_reset(&line)
				long = false
			} else if len(line.buf) < limit {
				strings.write_byte(&line, ch)
			} else {
				long = true
				// Keep the last byte for zsh's physical-line continuation.
				line.buf[len(line.buf) - 1] = ch
			}
		}
	}
	if len(line.buf) > 0 || long {
		foreign_history_line(&reader, strings.to_string(line), long)
	}

	foreign_history_flush(&reader)
	return reader.history.commands[:]
}

Foreign_History_Reader :: struct {
	history:                                     Native_History,
	record:                                      strings.Builder,
	discarded, continued, timestamped, has_line: bool,
}

foreign_history_append :: proc(r: ^Foreign_History_Reader, value: string) {
	if r.history.byte_limit > 0 && len(value) > r.history.byte_limit - len(r.record.buf) {
		r.discarded = true
	}

	if !r.discarded {
		strings.write_string(&r.record, value)
	}
}

foreign_history_flush :: proc(r: ^Foreign_History_Reader) {
	cmd := strings.to_string(r.record)
	if !r.discarded && cmd != "" && cmd[0] != ' ' && !strings.contains(cmd, "\x00") {
		native_history_retain(&r.history, cmd)
	}

	strings.builder_reset(&r.record)
	r.discarded, r.has_line, r.continued = false, false, false
}

foreign_history_line :: proc(r: ^Foreign_History_Reader, line: string, long: bool) {
	cmd := line
	switch wayu.shell_ext {
	case "bash":
		if len(cmd) > 1 && cmd[0] == '#' && all_digits(cmd[1:]) && !long {
			foreign_history_flush(r)
			r.timestamped = true
			return
		}

		if r.has_line {
			foreign_history_append(r, "\n")
		}

		r.discarded = r.discarded || long
		foreign_history_append(r, cmd)
		r.has_line = true
		if !r.timestamped {
			foreign_history_flush(r)
		}
	case "fish":
		if !strings.has_prefix(cmd, "- cmd: ") {
			return
		}

		r.discarded = long
		for j := 7; j < len(cmd); j += 1 {
			if cmd[j] == '\\' && j + 1 < len(cmd) && (cmd[j + 1] == 'n' || cmd[j + 1] == '\\') {
				j += 1
				foreign_history_append(r, "\n" if cmd[j] == 'n' else "\\")
			} else {
				foreign_history_append(r, cmd[j:j + 1])
			}
		}

		foreign_history_flush(r)
	case "zsh":
		if !r.continued && strings.has_prefix(cmd, ": ") {
			meta, sep, body := strings.partition(cmd[2:], ";")
			start, colon, duration := strings.partition(meta, ":")
			if sep != "" && colon != "" && all_digits(start) && all_digits(duration) {
				cmd = body
			}
		}

		r.discarded = r.discarded || long
		r.continued = strings.has_suffix(cmd, "\\")
		if r.continued {
			cmd = cmd[:len(cmd) - 1]
		}

		if !utf8.valid_string(cmd) && strings.index_byte(cmd, 0x83) >= 0 {
			for j := 0; j < len(cmd); j += 1 {
				ch := cmd[j]
				if ch == 0x83 && j + 1 < len(cmd) {
					j += 1; ch = cmd[j] ~ 0x20
				}

				foreign_history_append(r, string([]u8{ch}))
			}
		} else {
			foreign_history_append(r, cmd)
		}

		if r.continued {
			foreign_history_append(r, "\n")
		} else {
			foreign_history_flush(r)
		}
	}
}
