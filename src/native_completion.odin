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
			native_command_names(s, &choices, word)
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
		if len(prefix) > 0 && len(choices) == 0 && !native_is_builtin(s, prefix[0]) {
			native_complete_arguments(s, &choices, line[head:start], word)
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
			end     = native_completion_end(e.line, e.cursor, quote),
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

// When Tab is pressed inside a word, replace the remaining characters of
// that word too, leaving subsequent arguments and operators intact.
native_completion_end :: proc(line: string, cursor: int, open_quote: u8) -> int {
	quote := open_quote
	i := cursor
	for i < len(line) {
		ch := line[i]
		if ch == '\\' && quote != '\'' {
			i = min(i + 2, len(line))
			continue
		}

		if quote != 0 {
			if ch == quote {
				quote = 0
			}
		} else if ch == '\'' || ch == '"' {
			quote = ch
		} else if shell_is_blank(ch) || ch == '\n' || shell_is_op_byte(ch) {
			break
		}

		i += 1
	}

	return i
}

// Fish autoloads completion definitions on demand, including Wayu-managed
// ones. Pass decoded words as argv and let Fish escape them for complete -C.
native_complete_arguments :: proc(
	s: ^Native_Session,
	choices: ^map[string]bool,
	before, word: string,
) {
	fish := script_find_on_path("fish")
	if fish == "" {
		return
	}

	parts := shell_parse_statements(before, .POSIX, true)
	defer shell_statements_destroy(&parts)

	if len(parts) != 1 || parts[0].error != "" || len(parts[0].tokens) == 0 {
		return
	}

	query :: `set -p fish_complete_path $argv[1]
set -e argv[1]
set -l input
for w in $argv
    set -a input (string escape -- "$w")
end
if test -z "$argv[-1]"
    set input[-1] ""
end
complete -C (string join " " -- $input)`
	args := make([dynamic]string, context.temp_allocator)
	append(&args, fish, "--no-config", "-c", query, "--", fmt.tprintf("%s/completions", wayu.data))
	tokens := make([dynamic]ShellToken, context.temp_allocator)
	active := make(map[string]bool, context.temp_allocator)
	head, target := true, false
	native_alias_tokens(s, parts[0].tokens[:], &tokens, &active, &head, &target)
	for token in tokens {
		if token.kind != .Word {
			return
		}

		value, ok := native_expand(token.word, s.status)
		if !ok || strings.contains_any(value, "\r\n") {
			return
		}

		append(&args, value)
	}

	if strings.contains_any(word, "\r\n") {
		return
	}
	append(&args, word)
	result := run_command_timeout(args[:], 3000)
	defer command_result_destroy(&result)

	if !result.ok {
		return
	}

	output := result.stdout
	for line in strings.split_lines_iterator(&output) {
		name, _, _ := strings.partition(line, "\t")
		if name != "" && strings.has_prefix(name, word) {
			choices^[strings.clone(name, context.temp_allocator)] = true
		}
	}
}

native_command_names :: proc(s: ^Native_Session, choices: ^map[string]bool, prefix: string) {
	if s.jump_cmd != "" && strings.has_prefix(s.jump_cmd, prefix) {
		choices^[s.jump_cmd] = true
	}

	for name in NATIVE_BUILTINS {
		if strings.has_prefix(name, prefix) {
			choices^[name] = true
		}
	}
	for name in s.definitions {
		if strings.has_prefix(name, prefix) {
			choices^[name] = true
		}
	}

	for name in s.functions {
		if strings.has_prefix(name, prefix) {
			choices^[name] = true
		}
	}
	for name in s.aliases {
		if strings.has_prefix(name, prefix) {
			choices^[name] = true
		}
	}
	for dir in strings.split(
		os.get_env("PATH", context.temp_allocator),
		":",
		context.temp_allocator,
	) {
		native_complete_dir(choices, "." if dir == "" else dir, "", prefix, true, false)
	}
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
