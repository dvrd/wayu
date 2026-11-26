package wayu

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"

Native_Completion :: struct {
	start:   int,
	end:     int,
	index:   int,
	choices: []string,
}

native_complete :: proc(s: ^Native_Session, e: ^Native_Editor, c: ^Native_Completion) {
	if len(c.choices) == 0 {
		line := e.line[:e.cursor]
		start, head := 0, 0
		quote: u8
		for i := 0; i < len(line); i += 1 {
			ch := line[i]
			if ch == '\\' && quote != '\'' {
				i += 1
				continue
			}
			if quote != 0 {
				if ch == quote {
					quote = 0
				}
				continue
			}
			switch ch {
			case '\'', '"':
				quote = ch
			case ' ', '\t':
				start = i + 1
			case '|', '&', ';', '\n':
				start = i + 1
				head = start
			}
		}
		raw := line[start:]
		word := ""
		if raw != "" {
			closed := raw if quote == 0 else fmt.tprintf("%s%c", raw, quote)
			parts := shell_parse_statements(closed, .POSIX, true)
			defer shell_statements_destroy(&parts)
			if len(parts) != 1 ||
			   parts[0].error != "" ||
			   len(parts[0].tokens) != 1 ||
			   parts[0].tokens[0].kind != .Word {
				return
			}
			expanded, ok := native_expand(parts[0].tokens[0].word, s.status)
			if !ok {
				return
			}
			word = expanded
		}
		choices := make(map[string]bool, context.temp_allocator)
		prefix := strings.fields(line[head:start], context.temp_allocator)
		if len(prefix) == 0 && !strings.contains(word, "/") {
			for name in ([]string{"cd", "exit", "export", "unset", "jobs", "fg", "bg", "source"}) {
				if strings.has_prefix(name, word) {
					choices[name] = true
				}
			}
			for name in s.functions {
				if strings.has_prefix(name, word) {
					choices[name] = true
				}
			}
			for name in s.aliases {
				if strings.has_prefix(name, word) {
					choices[name] = true
				}
			}
			for dir in strings.split(
				os.get_env("PATH", context.temp_allocator),
				":",
				context.temp_allocator,
			) {
				native_complete_dir(&choices, "." if dir == "" else dir, "", word, true, false)
			}
		} else if len(prefix) == 1 && prefix[0] == "wayu" {
			for spec in WAYU_COMMAND_SPECS {
				for name in spec.names {
					if strings.has_prefix(name, word) {
						choices[name] = true
					}
				}
			}
		} else if len(prefix) == 2 &&
		   prefix[0] == "wayu" &&
		   find_command_spec_by_name(prefix[1]) != nil {
			spec := find_command_spec_by_name(prefix[1])
			for a in spec.actions {
				if strings.has_prefix(a.word, word) {
					choices[a.word] = true
				}
			}
		}
		if len(choices) == 0 {
			cut := strings.last_index_byte(word, '/') + 1
			display := word[:cut]
			tail := word[cut:]
			dir := "." if display == "" else display
			native_complete_dir(
				&choices,
				dir,
				display,
				tail,
				false,
				len(prefix) > 0 && prefix[0] == "cd",
			)
		}
		names := make([dynamic]string, context.temp_allocator)
		for name in choices {append(&names, name)}
		if len(names) == 0 {
			return
		}
		slice.sort(names[:])
		c^ = {
			start   = start,
			end     = e.cursor,
			choices = names[:],
		}
	}
	name := c.choices[c.index]
	c.index = (c.index + 1) % len(c.choices)
	value := name
	for ch in transmute([]u8)name {
		if !is_env_var_char(ch) && strings.index_byte("./-+:~", ch) < 0 {
			value = shell_quote(name, .ZSH)
			break
		}
	}
	native_edit_replace(e, c.start, c.end, value)
	c.end = e.cursor
}

native_complete_dir :: proc(
	choices: ^map[string]bool,
	dir, display, prefix: string,
	commands, dirs_only: bool,
) {
	handle, err := os.open(dir)
	if err != nil {
		return
	}
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil {
		return
	}
	for entry in entries {
		if !strings.has_prefix(entry.name, prefix) ||
		   (strings.has_prefix(entry.name, ".") && !strings.has_prefix(prefix, ".")) {
			continue
		}
		path := fmt.tprintf("%s/%s", dir, entry.name)
		directory := entry.type == .Directory || (entry.type == .Symlink && os.is_dir(path))
		if commands &&
		   (directory ||
				   posix.access(strings.clone_to_cstring(path, context.temp_allocator), {.X_OK}) !=
					   .OK) {
			continue
		}
		if dirs_only && !directory {
			continue
		}
		choices^[fmt.tprintf("%s%s%s", display, entry.name, "/" if directory else "")] = true
	}
}
