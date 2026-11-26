package wayu

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:unicode/utf8"

Native_Edit :: struct {
	line:   string,
	cursor: int,
}
Native_Editor :: struct {
	using edit:   Native_Edit,
	undo, redo:   [dynamic]Native_Edit,
	matches:      [dynamic]string,
	match:        int,
	has_matches:  bool,
	all_matches:  bool,
	vi:           bool,
	pending_byte: int,
	operator:     string,
	row:          int,
}

native_edit_replace :: proc(e: ^Native_Editor, start, end: int, text: string) {
	append(&e.undo, e.edit)
	clear(&e.redo)
	e.line = strings.concatenate({e.line[:start], text, e.line[end:]}, context.temp_allocator)
	e.cursor = start + len(text)
	e.has_matches = false
}

native_back :: proc(e: Native_Edit) -> int {
	if e.cursor == 0 {
		return 0
	}
	_, width := utf8.decode_last_rune(transmute([]u8)e.line[:e.cursor])
	return e.cursor - max(width, 1)
}
native_forward :: proc(e: Native_Edit) -> int {
	if e.cursor >= len(e.line) {
		return len(e.line)
	}
	_, width := utf8.decode_rune_in_string(e.line[e.cursor:])
	return e.cursor + max(width, 1)
}

native_suggestions :: proc(e: ^Native_Editor, h: ^Native_History, all: bool = false) {
	if e.has_matches && (!all || e.all_matches) {
		return
	}
	clear(&e.matches)
	e.match = 0
	if len(e.line) == 0 && !all {
		return
	}
	e.has_matches = true
	e.all_matches = all
	seen := make(map[string]bool, context.temp_allocator)
	for i := len(h.commands) - 1; i >= 0; i -= 1 {
		v := h.commands[i]
		if len(v) > len(e.line) && strings.has_prefix(v, e.line) && !seen[v] {
			append(&e.matches, v)
			if !all {
				break
			}
			seen[v] = true
		}
	}
}

native_display :: proc(e: ^Native_Editor, prompt, hint: string) {
	size: winsize
	width := 80
	if ioctl(2, TIOCGWINSZ, &size) == 0 && size.ws_col >= 2 {
		width = int(size.ws_col)
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\r")
	if e.row > 0 {
		fmt.sbprintf(&b, "\x1b[%dA", e.row)
	}
	strings.write_string(&b, "\x1b[J")
	row, col, at_row, at_col := 0, 0, 0, 0
	for part, i in ([4]string{prompt, e.line[:e.cursor], e.line[e.cursor:], hint}) {
		if i == 2 {
			at_row, at_col = row, col
		}
		if i == 3 {
			strings.write_string(&b, "\x1b[2m")
		}
		for r in part {
			if r == '\n' {
				strings.write_string(&b, "\r\n")
				row += 1
				col = 0
				continue
			}
			visible := r
			if r < ' ' || (r >= 0x7f && r < 0xa0) {
				visible = '�'
			}
			w := get_rune_width(visible)
			if col + w > width {
				strings.write_string(&b, "\r\n")
				row += 1
				col = 0
			}
			strings.write_rune(&b, visible)
			col += w
			if col >= width {
				strings.write_string(&b, "\r\n")
				row += 1
				col = 0
			}
		}
	}
	strings.write_string(&b, "\x1b[0m\r")
	if row > at_row {
		fmt.sbprintf(&b, "\x1b[%dA", row - at_row)
	}
	if at_col > 0 {
		fmt.sbprintf(&b, "\x1b[%dC", at_col)
	}
	fmt.eprint(strings.to_string(b))
	e.row = at_row
}

native_key_byte :: proc() -> (u8, bool) {
	ch: u8
	for {
		n := posix.read(0, &ch, 1)
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		return ch, n == 1
	}
}

native_key :: proc(e: ^Native_Editor) -> string {
	ch: u8
	ok := true
	if e.pending_byte >= 0 {
		ch = u8(e.pending_byte)
		e.pending_byte = -1
	} else {
		ch, ok = native_key_byte()
	}
	if !ok {
		return ""
	}
	bytes: [32]u8
	bytes[0] = ch
	n := 1
	if ch == 0x1b {
		fd := posix.pollfd {
			fd     = 0,
			events = {.IN},
		}
		if posix.poll(&fd, 1, 35) > 0 {
			bytes[n], ok = native_key_byte()
			if ok {
				n += 1
			}
			if n == 2 && bytes[1] != '[' {
				e.pending_byte = int(bytes[1])
				n = 1
			} else if n == 2 {
				for n < len(bytes) && posix.poll(&fd, 1, 35) > 0 {
					bytes[n], ok = native_key_byte()
					if !ok {
						break
					}
					n += 1
					if bytes[n - 1] >= 0x40 && bytes[n - 1] <= 0x7e {
						break
					}
				}
			}
		}
	} else if ch >= 0xc2 && ch <= 0xf4 {
		count := 2 if ch < 0xe0 else (3 if ch < 0xf0 else 4)
		for n < count {
			bytes[n], ok = native_key_byte()
			if !ok {
				break
			}
			n += 1
		}
	}
	return strings.clone(string(bytes[:n]), context.temp_allocator)
}

@(private = "file")
native_saved_modes: posix.termios

@(private = "file")
native_editor_signal :: proc "c" (sig: posix.Signal) {
	posix.tcsetattr(0, .TCSANOW, &native_saved_modes)
	write_all_fd(2, "\x1b[?2004l")
	posix.signal(sig, auto_cast posix.SIG_DFL)
	posix.raise(sig)
}

native_edit_line :: proc(s: ^Native_Session, h: ^Native_History) -> (string, bool) {
	native_saved_modes = s.modes
	signals := [?]posix.Signal {
		.SIGTERM,
		.SIGHUP,
		.SIGABRT,
		.SIGSEGV,
		.SIGBUS,
		.SIGILL,
		.SIGTRAP,
		.SIGFPE,
	}
	previous: [len(signals)]proc "c" (_: posix.Signal)
	for sig, i in signals {previous[i] = posix.signal(sig, native_editor_signal)}
	defer {for sig, i in signals {posix.signal(sig, previous[i])}}
	raw := s.modes
	raw.c_lflag -= {.ECHO, .ICANON, .ISIG, .IEXTEN}
	raw.c_iflag -= {.IXON, .ICRNL}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0
	if posix.tcsetattr(0, .TCSANOW, &raw) != .OK {
		return "", false
	}
	fmt.eprint("\x1b[?2004h")
	defer {
		fmt.eprint("\x1b[?2004l")
		posix.tcsetattr(0, .TCSANOW, &s.modes)
	}
	e := Native_Editor {
		pending_byte = -1,
		undo         = make([dynamic]Native_Edit, context.temp_allocator),
		redo         = make([dynamic]Native_Edit, context.temp_allocator),
		matches      = make([dynamic]string, context.temp_allocator),
	}
	prompt := "wayu> "
	if s.prompt_success != "" {
		prompt = fmt.tprintf("%s ", s.prompt_success if s.status == 0 else s.prompt_error)
	}
	history_pos := len(h.commands)
	draft := ""
	completion: Native_Completion
	for {
		native_suggestions(&e, h)
		hint := ""
		if !e.vi && e.cursor == len(e.line) && len(e.matches) > 0 {
			hint = e.matches[e.match][len(e.line):]
		}
		shown := prompt
		if e.vi && s.prompt_normal != "" {
			shown = fmt.tprintf("%s ", s.prompt_normal)
		}
		native_display(&e, shown, hint)
		key := native_key(&e)
		if e.vi && e.operator != "" {
			operator := e.operator
			e.operator = ""
			start, end := e.cursor, e.cursor
			switch key {
			case operator:
				start, end = 0, len(e.line)
			case "w", "b", "e":
				end = native_word_motion(e.line, e.cursor, key)
				if key == "e" {
					end = native_forward({e.line, end})
				}
			case "$":
				end = len(e.line)
			case "0":
				end = 0
			case:
				continue
			}
			if end < start {
				start, end = end, start
			}
			delete(s.vi_register)
			s.vi_register = strings.clone(e.line[start:end])
			if operator != "y" {
				native_edit_replace(&e, start, end, "")
				e.vi = operator != "c"
			}
			continue
		}
		if key != "\t" {
			completion = {}
		}
		switch key {
		case "\t":
			native_complete(s, &e, &completion)
		case "", "\x04":
			if key == "" || len(e.line) == 0 {
				fmt.eprint("\r\n")
				return "", false
			}
			if e.cursor < len(e.line) {
				native_edit_replace(&e, e.cursor, native_forward(e.edit), "")
			}
		case "\x03":
			fmt.eprint("^C\r\n")
			s.status = 130
			return "", true
		case "\r", "\n":
			if native_incomplete(e.line) {
				native_edit_replace(&e, e.cursor, e.cursor, "\n")
				continue
			}
			e.cursor = len(e.line)
			native_display(&e, prompt, "")
			fmt.eprint("\r\n")
			return e.line, true
		case "\x0e", "\x10":
			had := e.has_matches && len(e.matches) > 0
			native_suggestions(&e, h, true)
			if had {
				n := len(e.matches)
				e.match = (e.match + (1 if key == "\x0e" else n - 1)) % n
			}
		case "\x1b[A", "\x1b[B":
			if history_pos == len(h.commands) {
				draft = e.line
			}
			history_pos = clamp(history_pos + (-1 if key == "\x1b[A" else 1), 0, len(h.commands))
			v := draft if history_pos == len(h.commands) else h.commands[history_pos]
			native_edit_replace(&e, 0, len(e.line), v)
		case "\x1b[D", "\x02":
			e.cursor = native_back(e.edit)
		case "\x1b[C", "\x06":
			if e.cursor == len(e.line) && hint != "" {
				native_edit_replace(&e, e.cursor, e.cursor, hint)
			} else {
				e.cursor = native_forward(e.edit)
			}
		case "\x01", "\x1b[H":
			e.cursor = 0
		case "\x05", "\x1b[F":
			e.cursor = len(e.line)
		case "\x7f", "\x08":
			if e.cursor > 0 {
				native_edit_replace(&e, native_back(e.edit), e.cursor, "")
			}
		case "\x15":
			native_edit_replace(&e, 0, e.cursor, "")
		case "\x0b":
			native_edit_replace(&e, e.cursor, len(e.line), "")
		case "\x1f":
			if len(e.undo) > 0 {
				append(&e.redo, e.edit)
				e.edit = pop(&e.undo)
				e.has_matches = false
			}
		case "\x12":
			if !e.vi {
				native_history_search(&e, h)
			} else if len(e.redo) > 0 {
				append(&e.undo, e.edit)
				e.edit = pop(&e.redo)
				e.has_matches = false
			}
		case "\x1b[200~":
			b := strings.builder_make(context.temp_allocator)
			for {
				ch, ok := native_key_byte()
				if !ok {
					return "", false
				}
				strings.write_byte(&b, ch)
				if strings.has_suffix(strings.to_string(b), "\x1b[201~") {
					break
				}
			}
			paste := strings.to_string(b)
			native_edit_replace(&e, e.cursor, e.cursor, paste[:len(paste) - 6])
		case "\x1b":
			if s.vi_mode {
				e.vi = true
				if e.cursor > 0 {
					e.cursor = native_back(e.edit)
				}
			}
		case:
			if e.vi {
				switch key {
				case "i":
					e.vi = false
				case "a":
					e.cursor = native_forward(e.edit)
					e.vi = false
				case "A":
					e.cursor = len(e.line)
					e.vi = false
				case "I":
					e.cursor = 0
					e.vi = false
				case "h":
					e.cursor = native_back(e.edit)
				case "l":
					e.cursor = native_forward(e.edit)
				case "w", "b", "e":
					e.cursor = native_word_motion(e.line, e.cursor, key)
				case "0":
					e.cursor = 0
				case "$":
					e.cursor = len(e.line)
				case "d", "c", "y":
					e.operator = key
				case "p", "P":
					if s.vi_register != "" {
						at := native_forward(e.edit) if key == "p" else e.cursor
						native_edit_replace(&e, at, at, s.vi_register)
						e.cursor = native_back(e.edit)
					}
				case "x":
					if e.cursor < len(e.line) {
						end := native_forward(e.edit)
						delete(s.vi_register)
						s.vi_register = strings.clone(e.line[e.cursor:end])
						native_edit_replace(&e, e.cursor, end, "")
					}
				case "u":
					if len(e.undo) > 0 {
						append(&e.redo, e.edit)
						e.edit = pop(&e.undo)
						e.has_matches = false
					}
				}
			} else if key[0] >= 0x20 && key[0] != 0x7f {
				native_edit_replace(&e, e.cursor, e.cursor, key)
			}
		}
	}
}

// Ctrl-R previews literal substring matches. Enter returns the selection to
// the editable line so that accepting a search never executes a command.
native_history_search :: proc(e: ^Native_Editor, h: ^Native_History) {
	query := ""
	index := len(h.commands)
	hit := ""
	for {
		for index -= 1; index >= 0; index -= 1 {
			if strings.contains(h.commands[index], query) {
				hit = h.commands[index]
				break
			}
		}
		if index < 0 {
			hit = ""
		}
		preview := Native_Editor {
			row = e.row,
		}
		preview.line = hit
		preview.cursor = len(hit)
		native_display(&preview, fmt.tprintf("(history %s) ", query), "")
		e.row = preview.row
		key := native_key(e)
		switch key {
		case "\r", "\n":
			if hit != "" {
				native_edit_replace(e, 0, len(e.line), hit)
			}
			return
		case "", "\x1b", "\x03", "\x07":
			return
		case "\x12":
			if index <= 0 {
				index = len(h.commands)
			}
		case "\x7f", "\x08":
			query = query[:native_back({query, len(query)})]
			index = len(h.commands)
		case:
			if key[0] >= 0x20 && key[0] != 0x7f {
				query = fmt.tprintf("%s%s", query, key)
			}
			index = len(h.commands)
		}
	}
}

native_word_motion :: proc(line: string, cursor: int, key: string) -> int {
	at := cursor
	word_class :: proc(s: string, at: int) -> int {
		if at >= len(s) {
			return 0
		}
		b := s[at]
		if b == ' ' || b == '\n' || b == '\t' {
			return 0
		}
		return 1 if is_env_var_char(b) || b >= 128 else 2
	}
	if key == "b" {
		if at > 0 {
			at = native_back({line, at})
		}
		for at > 0 && word_class(line, at) == 0 {at = native_back({line, at})}
		group := word_class(line, at)
		for at > 0 {
			prev := native_back({line, at})
			if word_class(line, prev) != group {
				break
			}
			at = prev
		}
		return at
	}
	if key == "w" {
		group := word_class(line, at)
		for at < len(line) && group == word_class(line, at) {at = native_forward({line, at})}
		for at < len(line) && word_class(line, at) == 0 {at = native_forward({line, at})}
		return at
	}
	at = native_forward({line, at})
	for at < len(line) && word_class(line, at) == 0 {at = native_forward({line, at})}
	group := word_class(line, at)
	for at < len(line) {
		next := native_forward({line, at})
		if next == len(line) || word_class(line, next) != group {
			break
		}
		at = next
	}
	return at
}
