package wayu

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:unicode/utf8"

Native_History :: struct {
	path:           string,
	commands:       [dynamic]string,
	shell_commands: []string,
	offset:         i64,
	inode:          u64,
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

// Shell history is a read-only suggestion source. Recall and recording retain
// their native session semantics and never rewrite the launching shell's file.
native_read_shell_history :: proc() -> []string {
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

	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return nil
	}

	lines := strings.split(string(data), "\n", context.temp_allocator)
	commands := make([dynamic]string)
	for i := 0; i < len(lines); i += 1 {
		cmd := lines[i]
		switch wayu.shell_ext {
		case "zsh":
			if strings.has_prefix(cmd, ": ") {
				meta, sep, body := strings.partition(cmd[2:], ";")
				start, colon, duration := strings.partition(meta, ":")
				if sep != "" && colon != "" && all_digits(start) && all_digits(duration) {
					cmd = body
				}
			}

			if strings.has_suffix(cmd, "\\") {
				b := strings.builder_make(context.temp_allocator)
				for strings.has_suffix(cmd, "\\") && i + 1 < len(lines) {
					strings.write_string(&b, cmd[:len(cmd) - 1])
					strings.write_byte(&b, '\n')
					i += 1
					cmd = lines[i]
				}

				strings.write_string(&b, cmd)
				cmd = strings.to_string(b)
			}
			if !utf8.valid_string(cmd) && strings.index_byte(cmd, 0x83) >= 0 {
				b := strings.builder_make(context.temp_allocator)
				for j := 0; j < len(cmd); j += 1 {
					ch := cmd[j]
					if ch == 0x83 && j + 1 < len(cmd) {
						j += 1
						ch = cmd[j] ~ 0x20
					}

					strings.write_byte(&b, ch)
				}

				cmd = strings.to_string(b)
			}

		case "bash":
			if len(cmd) > 1 && cmd[0] == '#' && all_digits(cmd[1:]) {
				first := i + 1
				for i + 1 < len(lines) {
					next := lines[i + 1]
					if len(next) > 1 && next[0] == '#' && all_digits(next[1:]) {
						break
					}

					i += 1
				}

				end := i + 1
				if end == len(lines) && end > first && lines[end - 1] == "" {
					end -= 1
				}

				cmd = strings.join(lines[first:end], "\n", context.temp_allocator)
			}
		case "fish":
			if !strings.has_prefix(cmd, "- cmd: ") {
				continue
			}

			cmd = cmd[7:]
			b := strings.builder_make(context.temp_allocator)
			for j := 0; j < len(cmd); j += 1 {
				if cmd[j] == '\\' &&
				   j + 1 < len(cmd) &&
				   (cmd[j + 1] == 'n' || cmd[j + 1] == '\\') {
					j += 1
					strings.write_byte(&b, '\n' if cmd[j] == 'n' else '\\')
				} else {
					strings.write_byte(&b, cmd[j])
				}
			}

			cmd = strings.to_string(b)
		}

		if cmd != "" && cmd[0] != ' ' && !strings.contains(cmd, "\x00") {
			append(&commands, strings.clone(cmd))
		}
	}

	return commands[:]
}
