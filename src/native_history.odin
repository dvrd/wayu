package wayu

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

Native_History :: struct {
	path:     string,
	commands: [dynamic]string,
	offset:   i64,
	inode:    u64,
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
	fd := posix.open(
		strings.clone_to_cstring(h.path, context.temp_allocator),
		{.RDWR, .CREAT, .NOFOLLOW, .CLOEXEC, .NONBLOCK},
		transmute(posix.mode_t)posix._mode_t(0o600),
	)
	if fd < 0 {
		return false
	}
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) || st.st_uid != posix.geteuid() {
		return false
	}
	for posix.lockf(fd, .LOCK, 0) != .OK {
		if posix.errno() != .EINTR {
			return false
		}
	}
	if posix.fstat(fd, &st) != .OK {
		return false
	}
	if h.inode != u64(st.st_ino) || h.offset > i64(st.st_size) {
		for cmd in h.commands {delete(cmd)}
		clear(&h.commands)
		h.offset = 0
		h.inode = u64(st.st_ino)
	}
	if posix.lseek(fd, auto_cast h.offset, .SET) < 0 {
		return false
	}
	partial := strings.builder_make(context.temp_allocator)
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
				strings.write_byte(&partial, ch)
				continue
			}
			data := strings.to_string(partial)
			name: string
			if json.unmarshal(transmute([]u8)data, &name, allocator = context.temp_allocator) ==
				   nil &&
			   name != "" {
				append(&h.commands, strings.clone(name))
			}
			h.offset += i64(len(data) + 1)
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
	append(&h.commands, strings.clone(record))
	return true
}
