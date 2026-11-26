package wayu

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

// Element zero is unstyled. The remaining indices follow HIGHLIGHT_STYLES.
Native_Highlight_Styles :: [HIGHLIGHT_STYLE_COUNT + 1]string
Native_Highlight :: struct {
	styles:      ^Native_Highlight_Styles,
	line:        string,
	colors:      [dynamic]u8,
	path:        []string,
	commands:    map[string]string,
	paths:       map[string]bool,
	brackets:    [dynamic]int,
	pairs:       map[int]int,
	match_style: string,
}

native_highlight_styles :: proc() -> ^Native_Highlight_Styles {
	if CURRENT_COLOR_PROFILE == .ASCII {
		return nil
	}
	settings := read_startup_settings()
	if !settings.highlight {
		return nil
	}
	styles := new(Native_Highlight_Styles)
	for spec, i in settings.highlight_styles {
		styles[i + 1] = native_region_style(spec)
	}
	return styles
}

native_region_style :: proc(spec: string) -> string {
	codes := make([dynamic]string, context.temp_allocator)
	for field in strings.split(spec, ",", context.temp_allocator) {
		switch field {
		case "bold":
			append(&codes, "1")
		case "dim", "faint":
			append(&codes, "2")
		case "italic":
			append(&codes, "3")
		case "underline":
			append(&codes, "4")
		case "blink":
			append(&codes, "5")
		case "standout", "reverse":
			append(&codes, "7")
		case:
			kind, eq, value := strings.partition(field, "=")
			if eq == "" || (kind != "fg" && kind != "bg") {
				continue
			}
			n := color_name_to_num(value)
			if len(value) == 7 && value[0] == '#' {
				if rgb, ok := strconv.parse_int(value[1:], 16); ok && rgb >= 0 && rgb <= 0xffffff {
					base := 38 if kind == "fg" else 48
					append(
						&codes,
						fmt.tprintf(
							"%d;2;%d;%d;%d",
							base,
							(rgb >> 16) & 255,
							(rgb >> 8) & 255,
							rgb & 255,
						),
					)
				}
				continue
			}
			if n < 0 {
				number, ok := strconv.parse_int(value)
				if !ok || number < 0 || number > 255 {
					continue
				}
				n = number
			}
			base := 30 if kind == "fg" else 40
			if n < 8 {
				append(&codes, fmt.tprintf("%d", base + n))
			} else {
				append(&codes, fmt.tprintf("%d;5;%d", base + 8, n))
			}
		}
	}
	if len(codes) > 0 {
		return fmt.tprintf("\x1b[%sm", strings.join(codes[:], ";", context.temp_allocator))
	}
	return ""
}

native_highlight_init :: proc(s: ^Native_Session) -> (h: Native_Highlight) {
	h.styles = s.highlight
	if h.styles != nil {
		h.colors = make([dynamic]u8, context.temp_allocator)
		h.brackets = make([dynamic]int, context.temp_allocator)
		h.pairs = make(map[int]int, context.temp_allocator)
		h.match_style = h.styles[highlight_style_index("cursor-matchingbracket") + 1]
		h.path = strings.split(
			os.get_env("PATH", context.temp_allocator),
			":",
			context.temp_allocator,
		)
		h.commands = make(map[string]string, context.temp_allocator)
		h.paths = make(map[string]bool, context.temp_allocator)
	}
	return
}

native_highlight_lookup_word :: proc(raw: string, status: int) -> string {
	if !strings.contains_any(raw, "'\"\\$~") {
		return raw
	}
	parts := shell_parse_statements(raw, .POSIX, true)
	defer shell_statements_destroy(&parts)
	if len(parts) != 1 ||
	   parts[0].error != "" ||
	   len(parts[0].tokens) != 1 ||
	   parts[0].tokens[0].kind != .Word {
		return ""
	}
	word, ok := native_expand(parts[0].tokens[0].word, status)
	return word if ok && !strings.contains(word, "\x00") else ""
}

native_highlight_exec :: proc(path: string) -> bool {
	return(
		posix.access(strings.clone_to_cstring(path, context.temp_allocator), {.X_OK}) == .OK &&
		!os.is_dir(path) \
	)
}

native_highlight_command :: proc(h: ^Native_Highlight, s: ^Native_Session, raw: string) -> string {
	if style, ok := h.commands[raw]; ok {
		return style
	}
	style := "unknown-token"
	name := native_highlight_lookup_word(raw, s.status)
	if name == "" {
		return style
	}
	if raw == name && name in s.aliases {
		style = "alias"
	} else if native_is_builtin(s, name) {
		style = "builtin"
	} else if name in s.functions {
		style = "function"
	} else if raw == name && native_reserved_word({text = name}) {
		style = "reserved-word"
	} else if strings.contains(name, "/") {
		if native_highlight_exec(name) {
			style = "command"
		}
	} else {
		for dir in h.path {
			file := fmt.tprintf("%s/%s", "." if dir == "" else dir, name)
			if native_highlight_exec(file) {
				style = "command"; break
			}
		}
	}
	h.commands[raw] = style
	return style
}

native_highlight_paint :: proc(h: ^Native_Highlight, start, end: int, style: string) {
	id := u8(highlight_style_index(style) + 1)
	for &c in h.colors[start:end] {c = id}
}

native_highlight_bracket :: proc(h: ^Native_Highlight, line: string, at: int) {
	ch := line[at]
	if ch == '(' || ch == '[' || ch == '{' {
		append(&h.brackets, at)
	} else if len(h.brackets) > 0 {
		open := h.brackets[len(h.brackets) - 1]
		if (ch == ')' && line[open] == '(') ||
		   (ch == ']' && line[open] == '[') ||
		   (ch == '}' && line[open] == '{') {
			levels := [3]string{"bracket-level-1", "bracket-level-2", "bracket-level-3"}
			style := levels[(len(h.brackets) - 1) % 3]
			native_highlight_paint(h, open, open + 1, style)
			native_highlight_paint(h, at, at + 1, style)
			h.pairs[open] = at
			h.pairs[at] = open
			pop(&h.brackets)
			return
		}
	}
	native_highlight_paint(h, at, at + 1, "bracket-error")
}

// Scan original byte offsets even while a quote or expansion is unfinished.
// Escapes, quotes and variables take precedence over the surrounding word.
native_highlight_word :: proc(h: ^Native_Highlight, line: string, start: int) -> (end: int) {
	end = start
	quote: u8
	quoted_style := ""
	for end < len(line) {
		c := line[end]
		if quote == 0 && (shell_is_blank(c) || c == '\n' || shell_is_op_byte(c)) {
			break
		}
		at := end
		end += 1
		if c == '\\' && (quote != '\'' || quoted_style == "dollar-quoted-argument") {
			if end < len(line) {
				end += 1
			}
			if quote != 0 {
				style :=
					"back-dollar-quoted-argument" if \
						quote == '\'' else \
						"back-double-quoted-argument"
				native_highlight_paint(h, at, end, style)
			}
			continue
		}
		if quote != 0 && c == quote {
			native_highlight_paint(h, at, end, quoted_style)
			quote = 0
			continue
		}
		if quote == 0 &&
		   (c == '\'' || c == '"' || (c == '$' && end < len(line) && line[end] == '\'')) {
			quote = c
			quoted_style = "single-quoted-argument" if c == '\'' else "double-quoted-argument"
			if c == '$' {
				quote = '\''; end += 1; quoted_style = "dollar-quoted-argument"
			}
			native_highlight_paint(h, at, end, quoted_style)
			continue
		}
		if c == '$' && quote != '\'' && end < len(line) {
			braces := line[end] == '{'
			if braces {
				end += 1
			}
			if end < len(line) && line[end] == '?' {
				end += 1
			} else {
				for end < len(line) && is_env_var_char(line[end]) {end += 1}
			}
			if braces && end < len(line) && line[end] == '}' {
				end += 1
			}
			if end > at + 1 {
				native_highlight_paint(
					h,
					at,
					end,
					"expansion" if quote == 0 else "dollar-double-quoted-argument",
				)
				continue
			}
		}
		if quote != 0 {
			for end < len(line) &&
			    line[end] != quote &&
			    line[end] != '\\' &&
			    line[end] != '$' {end += 1}
			native_highlight_paint(h, at, end, quoted_style)
		} else if c == '[' || c == ']' || c == '{' || c == '}' {
			native_highlight_bracket(h, line, at)
		} else if c == '*' || c == '?' {
			native_highlight_paint(h, at, end, "globbing")
		}
	}
	return
}

native_highlight_line :: proc(h: ^Native_Highlight, s: ^Native_Session, line: string) {
	if h.styles == nil || h.line == line {
		return
	}
	h.line = line
	clear(&h.brackets)
	clear(&h.pairs)
	resize(&h.colors, len(line))
	for &color in h.colors {color = 0}
	head := true
	redirect := false
	for i := 0; i < len(line); {
		c := line[i]
		if shell_is_blank(c) {
			i += 1; continue
		}
		if c == '#' {
			end := i
			for end < len(line) && line[end] != '\n' {end += 1}
			native_highlight_paint(h, i, end, "comment")
			i = end
			continue
		}
		op := i
		for op < len(line) && line[op] >= '0' && line[op] <= '9' {op += 1}
		if op < len(line) && (line[op] == '>' || line[op] == '<') {
			end := op + 1
			if end < len(line) && (line[end] == line[op] || line[end] == '&') {
				end += 1
			}
			native_highlight_paint(h, i, end, "redirection")
			redirect = true
			i = end
			continue
		}
		if shell_is_op_byte(c) || c == '\n' {
			if c == '(' || c == ')' {
				native_highlight_bracket(h, line, i)
			} else {
				native_highlight_paint(h, i, i + 1, "commandseparator")
			}
			head = true
			redirect = false
			i += 1
			continue
		}
		end := native_highlight_word(h, line, i)
		word := line[i:end]
		style := ""
		if head && !redirect {
			style = native_highlight_command(h, s, word)
			head = false
		} else if !redirect && strings.has_prefix(word, "--") {
			style = "double-hyphen-option"
		} else if !redirect && strings.has_prefix(word, "-") {
			style = "single-hyphen-option"
		} else {
			exists, known := h.paths[word]
			if !known {
				path := native_highlight_lookup_word(word, s.status)
				exists = path != "" && os.exists(path)
				h.paths[word] = exists
			}
			if exists {
				style = "path"
			}
		}
		if style != "" {
			id := u8(highlight_style_index(style) + 1)
			for &color in h.colors[i:end] {
				if color == 0 {
					color = id
				}
			}
		}
		redirect = false
		i = end
	}
}
