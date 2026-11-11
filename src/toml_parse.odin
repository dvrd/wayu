// toml_parse.odin - the one TOML parser (OKAMI-240)
//
// Every reader of wayu.toml goes through toml_doc_parse_alloc: `toml
// validate`, doctor, backup restore, the settings/[tools]/[prompt] readers
// and the TUI, so a file is never "invalid" for one command and fine for
// another.
//
// The parser is a real TOML 1.0 parser (plus the 1.1 conveniences \e, \xHH
// and newlines/trailing commas in inline tables) with ERROR RECOVERY: a bad
// statement is recorded in doc.errors and parsing resumes on the next line.
//   - Strict consumers (toml validate, doctor, backup restore) treat
//     any error as "invalid" and can print the line and reason.
//   - Lenient consumers use whatever was recovered. A `key = value` line
//     whose value is not valid TOML is recovered with the historical
//     single-line interpretation (toml_parse_kv_line).
//
// Besides the value tree (doc.values, TomlValue) the parse keeps every
// header and every `key = value` statement in FILE ORDER with its physical
// line span (doc.headers / doc.entries).
package wayu

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

TomlParseError :: struct {
	line:      int, // 1-based line where the error was detected
	stmt_line: int, // 0-based first line of the failing statement
	msg:       string,
	multiline: bool, // the failing value opened a multi-line construct
}

// One `[table]` / `[[array]]` header, in file order.
TomlHeader :: struct {
	path:    []string, // decoded key parts (nil when invalid)
	array:   bool,
	invalid: bool, // header could not be parsed or opened
	line:    int, // 0-based physical line
}

// One `key = value` statement, in file order (duplicates included).
TomlEntry :: struct {
	header:    int, // index into doc.headers, -1 = root table
	key:       []string, // decoded key parts (dotted keys have several)
	value:     ^TomlValue,
	first:     int, // 0-based physical lines spanned by the statement
	last:      int,
	vstart:    int, // byte offset of the value text in the content
	recovered: bool, // invalid TOML; value is the lenient interpretation
}

// Table bookkeeping for TOML's "define once" rules.
@(private = "file")
TomlTableKind :: enum u8 {
	NONE, // scalar / plain array
	IMPLICIT, // created as a parent by a header ([a.b] creates a)
	HEADER, // defined by its own [header]
	DOTTED, // created by a dotted key
	INLINE, // inline table: immutable once closed
	AOT, // array of tables ([[x]])
}

@(private = "file")
TomlParser :: struct {
	src:         string,
	pos:         int,
	line:        int, // 0-based line of `pos`
	doc:         ^TomlDoc,
	root:        ^TomlValue,
	cur:         ^TomlValue, // table receiving key/values; nil after a bad header
	cur_header:  int,
	kinds:       map[^TomlValue]TomlTableKind,
	err:         string, // first error of the current statement
	err_line:    int,
	depth:       int, // open arrays / inline tables around the current value
	line_starts: [dynamic]int, // byte offset of each line; built on first error
}

// Arrays and inline tables nest at most this deep; deeper input is a parse
// error instead of unbounded recursion.
TOML_MAX_NESTING :: 128

// Parse `content` with every node, string and list allocated in `alloc`
// (pass an arena and drop it in one go). Always returns the recovered
// document; ok == (len(doc.errors) == 0).
toml_doc_parse_alloc :: proc(content: string, alloc: mem.Allocator) -> (doc: TomlDoc, ok: bool) {
	context.allocator = alloc

	doc.headers = make([dynamic]TomlHeader)
	doc.entries = make([dynamic]TomlEntry)
	doc.errors = make([dynamic]TomlParseError)

	root := new(TomlValue)
	root^ = make_toml_table()

	p := TomlParser {
		src        = content,
		doc        = &doc,
		root       = root,
		cur        = root,
		cur_header = -1,
	}
	p.kinds = make(map[^TomlValue]TomlTableKind)
	if strings.has_prefix(content, "\xEF\xBB\xBF") {
		p.pos = 3
	} // UTF-8 BOM

	for p.pos < len(p.src) {
		tp_skip_ws(&p)
		if p.pos >= len(p.src) {
			break
		}
		switch c := p.src[p.pos]; c {
		case '\n':
			tp_adv(&p)
		case '\r':
			if tp_at(&p, "\r\n") {
				tp_adv(&p); tp_adv(&p)
			} else {
				tp_statement_failed(&p, p.line, "stray carriage return", false)
			}
		case '#':
			tp_skip_comment(&p)
		case '[':
			tp_header_stmt(&p)
		case:
			tp_keyval_stmt(&p)
		}
	}

	doc.values = root.table_val
	return doc, len(doc.errors) == 0
}

// Arena-backed parse that only reports validity. `first` is the first error
// (zero value when the content is valid); its msg is owned by the caller
// (allocated with context.allocator).
toml_check :: proc(content: string) -> (valid: bool, first: TomlParseError) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return false, {}
	}
	defer virtual.arena_destroy(&arena)
	doc, ok := toml_doc_parse_alloc(content, virtual.arena_allocator(&arena))
	if ok {
		return true, {}
	}
	first = doc.errors[0]
	first.msg = strings.clone(first.msg)
	return false, first
}

// True when `content` is valid TOML (strict callers: backup restore).
toml_content_is_sane :: proc(content: string) -> bool {
	ok, err := toml_check(content)
	delete(err.msg)
	return ok
}

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

@(private = "file")
tp_header_stmt :: proc(p: ^TomlParser) {
	sline := p.line
	array := tp_at(p, "[[")
	p.pos += array ? 2 : 1
	tp_skip_ws(p)
	path, ok := tp_key(p)
	if ok {
		tp_skip_ws(p)
		closing := array ? "]]" : "]"
		if tp_at(p, closing) {
			p.pos += len(closing)
		} else {
			ok = tp_fail(
				p,
				array \
					? "expected ']]' to close the array-of-tables header" \
					: "expected ']' to close the table header",
			)
		}
	}
	if ok {
		ok = tp_end_of_line(p)
	}

	idx := len(p.doc.headers)
	p.cur_header = idx
	if !ok {
		append(&p.doc.headers, TomlHeader{invalid = true, line = sline})
		p.cur = nil
		tp_statement_failed(p, sline, "", false)
		return
	}
	append(&p.doc.headers, TomlHeader{path = path, array = array, line = sline})
	p.cur = tp_open_table(p, path, array, sline)
	if p.cur == nil {
		p.doc.headers[idx].invalid = true
	}
}

@(private = "file")
tp_keyval_stmt :: proc(p: ^TomlParser) {
	sline := p.line
	key, ok := tp_key(p)
	vstart := -1
	val: ^TomlValue
	if ok {
		tp_skip_ws(p)
		if tp_peek(p) == '=' {
			p.pos += 1
		} else {
			ok = tp_fail(p, "expected '=' after the key")
		}
	}
	if ok {
		tp_skip_ws(p)
		vstart = p.pos
		if p.pos >= len(p.src) || p.src[p.pos] == '\n' || p.src[p.pos] == '#' || tp_at(p, "\r\n") {
			ok = tp_fail(p, "missing value after '='")
		} else {
			val, ok = tp_value(p)
		}
	}
	last := p.line
	if ok {
		ok = tp_end_of_line(p)
	}

	if !ok {
		multiline := p.line > sline
		if vstart >= 0 {
			for d in ([]string{"[", "{", `"""`, "'''"}) {
				if strings.has_prefix(p.src[vstart:], d) {
					multiline = true
				}
			}
		}
		tp_statement_failed(p, sline, "", multiline)
		tp_recover_keyval(p, sline)
		return
	}

	append(
		&p.doc.entries,
		TomlEntry {
			header = p.cur_header,
			key = key,
			value = val,
			first = sline,
			last = last,
			vstart = vstart,
		},
	)
	if p.cur != nil {
		tp_insert(p, p.cur, key, val, sline)
	}
}

// Lenient fallback for an invalid `key = value` line: the historical
// one-line reading (inline comment stripped, one matching quote pair
// removed, else the raw text). Values opening a multi-line construct are
// not recovered: their continuation lines can't be told apart.
@(private = "file")
tp_recover_keyval :: proc(p: ^TomlParser, sline: int) {
	text := tp_line_text(p, sline)
	_, value, ok := toml_parse_kv_line(text) // value lives in the parse arena
	if !ok {
		return
	}

	eq := strings.index_byte(text, '=')
	raw := strings.trim_space(text[eq + 1:])
	for d in ([]string{"[", "{", `"""`, "'''"}) {
		if strings.has_prefix(raw, d) {
			return
		}
	}

	key_text := strings.trim_space(text[:eq])
	kp := TomlParser {
		src = key_text,
	}
	key, kok := tp_key(&kp)
	if !kok || kp.pos != len(key_text) {
		key = make([]string, 1)
		key[0] = strings.clone(key_text)
	}

	v := new(TomlValue)
	v.type = .STRING
	v.str_val = value
	append(
		&p.doc.entries,
		TomlEntry {
			header = p.cur_header,
			key = key,
			value = v,
			first = sline,
			last = sline,
			vstart = -1,
			recovered = true,
		},
	)
}

// Record the pending error (or `msg`) and resume at the line after `sline`.
@(private = "file")
tp_statement_failed :: proc(p: ^TomlParser, sline: int, msg: string, multiline: bool) {
	m := p.err if len(p.err) > 0 else msg
	l := p.err_line if len(p.err) > 0 else p.line
	append(
		&p.doc.errors,
		TomlParseError{line = l + 1, stmt_line = sline, msg = m, multiline = multiline},
	)
	p.err = ""

	// Rewind to the start of the statement's line, then skip that line.
	pos := tp_line_start(p, sline)
	if nl := strings.index_byte(p.src[pos:], '\n'); nl >= 0 {
		p.pos = pos + nl + 1
	} else {
		p.pos = len(p.src)
	}
	p.line = sline + 1
}

// Byte offset where physical line `n` (0-based) starts (len(src) past the
// end). The line index is built once, so error recovery stays linear.
@(private = "file")
tp_line_start :: proc(p: ^TomlParser, n: int) -> int {
	if p.line_starts == nil {
		p.line_starts = make([dynamic]int)
		append(&p.line_starts, 0)
		for i in 0 ..< len(p.src) {
			if p.src[i] == '\n' {
				append(&p.line_starts, i + 1)
			}
		}
	}
	return p.line_starts[n] if n < len(p.line_starts) else len(p.src)
}

// Physical line `n` (0-based) without its newline / carriage return.
@(private = "file")
tp_line_text :: proc(p: ^TomlParser, n: int) -> string {
	pos := tp_line_start(p, n)
	if n == 0 && strings.has_prefix(p.src, "\xEF\xBB\xBF") {
		pos = 3
	}
	end := strings.index_byte(p.src[pos:], '\n')
	line := p.src[pos:] if end < 0 else p.src[pos:pos + end]
	return strings.trim_right(line, "\r")
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

@(private = "file")
tp_new_table :: proc(p: ^TomlParser, kind: TomlTableKind) -> ^TomlValue {
	t := new(TomlValue)
	t^ = make_toml_table()
	p.kinds[t] = kind
	return t
}

@(private = "file")
tp_error_at :: proc(p: ^TomlParser, line: int, format: string, args: ..any) {
	append(
		&p.doc.errors,
		TomlParseError{line = line + 1, stmt_line = line, msg = fmt.aprintf(format, ..args)},
	)
}

// Resolve a header to the table that receives the following key/values.
// Returns nil (error recorded) when the path collides with a value.
@(private = "file")
tp_open_table :: proc(p: ^TomlParser, path: []string, array: bool, line: int) -> ^TomlValue {
	name := strings.join(path, ".")
	t := p.root
	for part, i in path {
		child, exists := t.table_val[part]
		if i < len(path) - 1 {
			switch {
			case !exists:
				child = tp_new_table(p, .IMPLICIT)
				t.table_val[part] = child
			case child.type == .TABLE && p.kinds[child] == .INLINE:
				tp_error_at(p, line, "[%s]: cannot extend inline table %q", name, part)
				return nil
			case child.type == .TABLE:
			case child.type == .ARRAY && p.kinds[child] == .AOT:
				child = child.arr_val[len(child.arr_val) - 1]
			case:
				tp_error_at(p, line, "[%s]: key %q already holds a value", name, part)
				return nil
			}
			t = child
			continue
		}

		if array {
			if !exists {
				child = new(TomlValue)
				child.type = .ARRAY
				child.arr_val = make([dynamic]^TomlValue)
				p.kinds[child] = .AOT
				t.table_val[part] = child
			} else if child.type != .ARRAY || p.kinds[child] != .AOT {
				tp_error_at(p, line, "[[%s]]: key %q is already defined", name, part)
				return nil
			}
			el := tp_new_table(p, .HEADER)
			append(&child.arr_val, el)
			return el
		}

		if !exists {
			child = tp_new_table(p, .HEADER)
			t.table_val[part] = child
			return child
		}
		if child.type != .TABLE {
			tp_error_at(p, line, "[%s]: key %q already holds a value", name, part)
			return nil
		}
		#partial switch p.kinds[child] {
		case .IMPLICIT:
			p.kinds[child] = .HEADER
		case .HEADER:
			tp_error_at(p, line, "table [%s] is defined twice", name)
		case .DOTTED:
			tp_error_at(p, line, "table [%s] was already defined with dotted keys", name)
		case:
			tp_error_at(p, line, "[%s]: cannot extend inline table", name)
			return nil
		}
		return child // duplicate tables are merged when recovering
	}
	return nil
}

// Insert `key` (dotted parts) = `val` into table `t`.
@(private = "file")
tp_insert :: proc(
	p: ^TomlParser,
	t: ^TomlValue,
	key: []string,
	val: ^TomlValue,
	line: int,
) -> bool {
	t := t
	for part in key[:len(key) - 1] {
		child, exists := t.table_val[part]
		switch {
		case !exists:
			child = tp_new_table(p, .DOTTED)
			t.table_val[part] = child
		case child.type == .TABLE && (p.kinds[child] == .DOTTED || p.kinds[child] == .IMPLICIT):
			p.kinds[child] = .DOTTED
		case:
			tp_error_at(p, line, "key %q: %q is already defined", strings.join(key, "."), part)
			return false
		}
		t = child
	}
	last := key[len(key) - 1]
	if old, exists := t.table_val[last]; exists {
		tp_error_at(p, line, "duplicate key %q", strings.join(key, "."))
		// Recovery: the last scalar wins (like the line readers did).
		if old.type == .TABLE || old.type == .ARRAY {
			return false
		}
	}
	t.table_val[last] = val
	return true
}

@(private = "file")
tp_freeze_inline :: proc(p: ^TomlParser, v: ^TomlValue) {
	switch v.type {
	case .TABLE:
		p.kinds[v] = .INLINE
		for _, child in v.table_val {tp_freeze_inline(p, child)}
	case .ARRAY:
		for child in v.arr_val {tp_freeze_inline(p, child)}
	case .STRING, .INTEGER, .FLOAT, .BOOLEAN, .DATETIME:
	}
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

@(private = "file")
tp_is_bare :: proc(c: byte) -> bool {
	return(
		(c >= 'A' && c <= 'Z') ||
		(c >= 'a' && c <= 'z') ||
		(c >= '0' && c <= '9') ||
		c == '_' ||
		c == '-' \
	)
}

// Dotted key: simple keys separated by '.', whitespace allowed around dots.
@(private = "file")
tp_key :: proc(p: ^TomlParser) -> ([]string, bool) {
	parts := make([dynamic]string)
	for {
		tp_skip_ws(p)
		part, ok := tp_simple_key(p)
		if !ok {
			return nil, false
		}
		append(&parts, part)
		tp_skip_ws(p)
		if tp_peek(p) != '.' {
			break
		}
		p.pos += 1
	}
	return parts[:], true
}

@(private = "file")
tp_simple_key :: proc(p: ^TomlParser) -> (string, bool) {
	switch tp_peek(p) {
	case '"':
		if tp_at(p, `"""`) {
			return "", tp_fail(p, "a key cannot be a multi-line string")
		}
		return tp_basic_string(p)
	case '\'':
		if tp_at(p, "'''") {
			return "", tp_fail(p, "a key cannot be a multi-line string")
		}
		return tp_literal_string(p)
	}
	start := p.pos
	for p.pos < len(p.src) && tp_is_bare(p.src[p.pos]) {p.pos += 1}
	if p.pos == start {
		if p.pos >= len(p.src) || p.src[p.pos] == '=' {
			return "", tp_fail(p, "missing key before '='")
		}
		return "", tp_fail(p, "invalid character %q in key (quote the key)", rune(p.src[p.pos]))
	}
	return strings.clone(p.src[start:p.pos]), true
}

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

@(private = "file")
tp_value :: proc(p: ^TomlParser) -> (^TomlValue, bool) {
	v := new(TomlValue)
	ok: bool
	switch tp_peek(p) {
	case '"':
		v.type = .STRING
		if tp_at(p, `"""`) {
			v.str_val, ok = tp_ml_basic_string(p)
		} else {
			v.str_val, ok = tp_basic_string(p)
		}
	case '\'':
		v.type = .STRING
		if tp_at(p, "'''") {
			v.str_val, ok = tp_ml_literal_string(p)
		} else {
			v.str_val, ok = tp_literal_string(p)
		}
	case '[', '{':
		if p.depth >= TOML_MAX_NESTING {
			return v, tp_fail(p, "arrays/inline tables nested more than %d deep", TOML_MAX_NESTING)
		}
		p.depth += 1
		defer p.depth -= 1
		ok = tp_array(p, v) if tp_peek(p) == '[' else tp_inline_table(p, v)
	case:
		ok = tp_scalar(p, v)
	}
	return v, ok
}

@(private = "file")
tp_array :: proc(p: ^TomlParser, v: ^TomlValue) -> bool {
	v.type = .ARRAY
	v.arr_val = make([dynamic]^TomlValue)
	p.pos += 1 // [
	for {
		tp_skip_ws_nl_comments(p)
		if p.pos >= len(p.src) {
			return tp_fail(p, "unterminated array (missing ']')")
		}
		if p.src[p.pos] == ']' {
			p.pos += 1; return true
		}
		el, ok := tp_value(p)
		if !ok {
			return false
		}
		append(&v.arr_val, el)
		tp_skip_ws_nl_comments(p)
		if p.pos >= len(p.src) {
			return tp_fail(p, "unterminated array (missing ']')")
		}
		switch p.src[p.pos] {
		case ',':
			p.pos += 1
		case ']':
			p.pos += 1; return true
		case:
			return tp_fail(p, "expected ',' or ']' in array")
		}
	}
}

@(private = "file")
tp_inline_table :: proc(p: ^TomlParser, v: ^TomlValue) -> bool {
	v^ = make_toml_table()
	p.kinds[v] = .DOTTED // mutable while it is being built
	p.pos += 1 // {
	for {
		tp_skip_ws_nl_comments(p)
		if p.pos >= len(p.src) {
			return tp_fail(p, "unterminated inline table (missing '}')")
		}
		if p.src[p.pos] == '}' {
			p.pos += 1; break
		}
		line := p.line
		key, ok := tp_key(p)
		if !ok {
			return false
		}
		tp_skip_ws(p)
		if tp_peek(p) != '=' {
			return tp_fail(p, "expected '=' after the key")
		}
		p.pos += 1
		tp_skip_ws(p)
		child: ^TomlValue
		child, ok = tp_value(p)
		if !ok {
			return false
		}
		if !tp_insert(p, v, key, child, line) {
			return false
		}
		tp_skip_ws_nl_comments(p)
		if p.pos >= len(p.src) {
			return tp_fail(p, "unterminated inline table (missing '}')")
		}
		switch p.src[p.pos] {
		case ',':
			p.pos += 1
		case '}':
			p.pos += 1; tp_freeze_inline(p, v); return true
		case:
			return tp_fail(p, "expected ',' or '}' in inline table")
		}
	}
	tp_freeze_inline(p, v)
	return true
}

@(private = "file")
tp_is_digit :: proc(c: byte) -> bool {return c >= '0' && c <= '9'}

// Integers, floats, booleans, date-times.
@(private = "file")
tp_scalar :: proc(p: ^TomlParser, v: ^TomlValue) -> bool {
	start := p.pos
	scan :: proc(p: ^TomlParser) {
		for p.pos < len(p.src) {
			c := p.src[p.pos]
			if !(tp_is_bare(c) || c == '+' || c == '.' || c == ':') {
				break
			}
			p.pos += 1
		}
	}
	scan(p)
	tok := p.src[start:p.pos]
	// `1979-05-27 07:32:00`: a space may separate date and time.
	if tp_is_date(tok) &&
	   len(tok) == 10 &&
	   p.pos + 3 < len(p.src) &&
	   p.src[p.pos] == ' ' &&
	   tp_is_digit(p.src[p.pos + 1]) &&
	   tp_is_digit(p.src[p.pos + 2]) &&
	   p.src[p.pos + 3] == ':' {
		p.pos += 1
		scan(p)
		tok = p.src[start:p.pos]
	}
	if len(tok) == 0 {
		return tp_fail(p, "invalid value (strings must be quoted)")
	}

	switch tok {
	case "true":
		v.type = .BOOLEAN; v.bool_val = true; return true
	case "false":
		v.type = .BOOLEAN; v.bool_val = false; return true
	case "inf", "+inf", "-inf", "nan", "+nan", "-nan":
		v.type = .FLOAT; v.str_val = strings.clone(tok); return true
	}

	if tp_is_date(tok) || tp_is_time(tok) {
		for i in 0 ..< len(tok) {
			c := tok[i]
			if !(tp_is_digit(c) ||
				   c == '-' ||
				   c == ':' ||
				   c == '.' ||
				   c == '+' ||
				   c == 'T' ||
				   c == 't' ||
				   c == 'Z' ||
				   c == 'z' ||
				   c == ' ') {
				return tp_fail(p, "invalid date-time %q", tok)
			}
		}
		v.type = .DATETIME; v.str_val = strings.clone(tok)
		return true
	}

	if n, ok := tp_parse_int(tok); ok {
		v.type = .INTEGER
		v.int_val = n
		v.str_val = fmt.aprintf("%d", n)
		return true
	}
	if tp_is_float(tok) {
		v.type = .FLOAT; v.str_val = strings.clone(tok)
		return true
	}
	return tp_fail(p, "invalid value %q (strings must be quoted)", tok)
}

@(private = "file")
tp_is_date :: proc(s: string) -> bool {
	return(
		len(s) >= 10 &&
		tp_is_digit(s[0]) &&
		tp_is_digit(s[1]) &&
		tp_is_digit(s[2]) &&
		tp_is_digit(s[3]) &&
		s[4] == '-' &&
		tp_is_digit(s[5]) &&
		tp_is_digit(s[6]) &&
		s[7] == '-' &&
		tp_is_digit(s[8]) &&
		tp_is_digit(s[9]) \
	)
}

@(private = "file")
tp_is_time :: proc(s: string) -> bool {
	return(
		len(s) >= 8 &&
		tp_is_digit(s[0]) &&
		tp_is_digit(s[1]) &&
		s[2] == ':' &&
		tp_is_digit(s[3]) &&
		tp_is_digit(s[4]) &&
		s[5] == ':' \
	)
}

// Digits with single underscores between them.
@(private = "file")
tp_digits_ok :: proc(s: string, hex := false) -> bool {
	if len(s) == 0 || s[0] == '_' || s[len(s) - 1] == '_' {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		if c == '_' {
			if s[i - 1] == '_' {
				return false
			}
			continue
		}
		is_hex := (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
		if !tp_is_digit(c) && !(hex && is_hex) {
			return false
		}
	}
	return true
}

@(private = "file")
tp_parse_int :: proc(tok: string) -> (int, bool) {
	s := tok
	base := 10
	if len(s) > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'o' || s[1] == 'b') {
		switch s[1] {case 'x':
			base = 16; case 'o':
			base = 8; case 'b':
			base = 2
		}
		s = s[2:]
		if !tp_digits_ok(s, base == 16) {
			return 0, false
		}
	} else {
		body := s
		if len(body) > 0 && (body[0] == '+' || body[0] == '-') {
			body = body[1:]
		}
		if !tp_digits_ok(body) {
			return 0, false
		}
		if len(body) > 1 && body[0] == '0' {
			return 0, false
		} // no leading zeros
	}
	clean, _ := strings.remove_all(s, "_", context.temp_allocator)
	n, ok := strconv.parse_i64_of_base(clean, base)
	return int(n), ok
}

@(private = "file")
tp_is_float :: proc(tok: string) -> bool {
	s := tok
	if len(s) > 0 && (s[0] == '+' || s[0] == '-') {
		s = s[1:]
	}
	mant := s
	exp := ""
	if e := strings.index_any(s, "eE"); e >= 0 {
		mant = s[:e]
		exp = s[e + 1:]
		if len(exp) > 0 && (exp[0] == '+' || exp[0] == '-') {
			exp = exp[1:]
		}
		if !tp_digits_ok(exp) {
			return false
		}
	}
	int_part := mant
	frac := ""
	has_dot := false
	if d := strings.index_byte(mant, '.'); d >= 0 {
		int_part = mant[:d]
		frac = mant[d + 1:]
		has_dot = true
	}
	if !has_dot && len(exp) == 0 {
		return false
	}
	if !tp_digits_ok(int_part) {
		return false
	}
	if len(int_part) > 1 && int_part[0] == '0' {
		return false
	}
	if has_dot && !tp_digits_ok(frac) {
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Strings
// ---------------------------------------------------------------------------

// "basic" string on one line, escapes decoded.
@(private = "file")
tp_basic_string :: proc(p: ^TomlParser) -> (string, bool) {
	p.pos += 1
	b := strings.builder_make()
	for {
		if p.pos >= len(p.src) || p.src[p.pos] == '\n' {
			return "", tp_fail(p, "unterminated string (missing closing '\"')")
		}
		c := p.src[p.pos]
		switch c {
		case '"':
			p.pos += 1
			return strings.to_string(b), true
		case '\\':
			if !tp_escape(p, &b) {
				return "", false
			}
		case:
			if tp_is_control(c) {
				return "", tp_control_fail(p, c)
			}
			strings.write_byte(&b, c)
			p.pos += 1
		}
	}
}

// '''literal''' content is taken verbatim.
@(private = "file")
tp_literal_string :: proc(p: ^TomlParser) -> (string, bool) {
	p.pos += 1
	start := p.pos
	for p.pos < len(p.src) && p.src[p.pos] != '\'' && p.src[p.pos] != '\n' {
		if tp_is_control(p.src[p.pos]) {
			return "", tp_control_fail(p, p.src[p.pos])
		}
		p.pos += 1
	}
	if p.pos >= len(p.src) || p.src[p.pos] != '\'' {
		return "", tp_fail(p, "unterminated string (missing closing \"'\")")
	}
	s := strings.clone(p.src[start:p.pos])
	p.pos += 1
	return s, true
}

// Skip the newline that directly follows an opening `"""` / `'''`.
@(private = "file")
tp_skip_first_newline :: proc(p: ^TomlParser) {
	if tp_at(p, "\r\n") {
		p.pos += 1
	}
	if tp_peek(p) == '\n' {
		tp_adv(p)
	}
}

// Closing delimiter of a multi-line string: up to two extra quotes before
// it belong to the content. Returns how many content quotes to emit, or -1
// when `pos` is not at a closing delimiter.
@(private = "file")
tp_ml_close :: proc(p: ^TomlParser, q: byte) -> int {
	n := 0
	for p.pos + n < len(p.src) && p.src[p.pos + n] == q {n += 1}
	if n < 3 {
		return -1
	}
	return min(n - 3, 2)
}

@(private = "file")
tp_ml_basic_string :: proc(p: ^TomlParser) -> (string, bool) {
	p.pos += 3
	tp_skip_first_newline(p)
	b := strings.builder_make()
	for {
		if p.pos >= len(p.src) {
			return "", tp_fail(p, `unterminated multi-line string (missing closing """)`)
		}
		c := p.src[p.pos]
		if c == '"' {
			if extra := tp_ml_close(p, '"'); extra >= 0 {
				for _ in 0 ..< extra {strings.write_byte(&b, '"')}
				p.pos += 3 + extra
				return strings.to_string(b), true
			}
			strings.write_byte(&b, c)
			p.pos += 1
			continue
		}
		if c == '\\' {
			// Line-ending backslash: trim it, the newline and following whitespace.
			j := p.pos + 1
			for j < len(p.src) &&
			    (p.src[j] == ' ' || p.src[j] == '\t' || p.src[j] == '\r') {j += 1}
			if j < len(p.src) && p.src[j] == '\n' {
				p.pos = j
				for p.pos < len(p.src) &&
				    (p.src[p.pos] == ' ' ||
						    p.src[p.pos] == '\t' ||
						    p.src[p.pos] == '\n' ||
						    p.src[p.pos] == '\r') {
					tp_adv(p)
				}
				continue
			}
			if !tp_escape(p, &b) {
				return "", false
			}
			continue
		}
		if tp_ml_control(p) {
			return "", tp_control_fail(p, c)
		}
		strings.write_byte(&b, c)
		tp_adv(p)
	}
}

@(private = "file")
tp_ml_literal_string :: proc(p: ^TomlParser) -> (string, bool) {
	p.pos += 3
	tp_skip_first_newline(p)
	b := strings.builder_make()
	for {
		if p.pos >= len(p.src) {
			return "", tp_fail(p, "unterminated multi-line string (missing closing ''')")
		}
		c := p.src[p.pos]
		if c == '\'' {
			if extra := tp_ml_close(p, '\''); extra >= 0 {
				for _ in 0 ..< extra {strings.write_byte(&b, '\'')}
				p.pos += 3 + extra
				return strings.to_string(b), true
			}
		}
		if tp_ml_control(p) {
			return "", tp_control_fail(p, c)
		}
		strings.write_byte(&b, c)
		tp_adv(p)
	}
}

// TOML forbids raw control characters in strings: below 0x20 except tab,
// and DEL (an escape such as \u0007 is the way to write one).
@(private = "file")
tp_is_control :: proc(c: byte) -> bool {
	return (c < 0x20 && c != '\t') || c == 0x7f
}

// Multi-line strings may also span lines (LF or CRLF).
@(private = "file")
tp_ml_control :: proc(p: ^TomlParser) -> bool {
	c := p.src[p.pos]
	if c == '\n' || tp_at(p, "\r\n") {
		return false
	}
	return tp_is_control(c)
}

@(private = "file")
tp_control_fail :: proc(p: ^TomlParser, c: byte) -> bool {
	return tp_fail(
		p,
		"control character 0x%02X in a string (write it as an escape, e.g. \\u%04X)",
		c,
		c,
	)
}

// Decode the escape at p.pos (a backslash) into `b`.
@(private = "file")
tp_escape :: proc(p: ^TomlParser, b: ^strings.Builder) -> bool {
	if p.pos + 1 >= len(p.src) {
		return tp_fail(p, "unterminated escape sequence")
	}
	e := p.src[p.pos + 1]
	p.pos += 2
	switch e {
	case 'b':
		strings.write_byte(b, '\b')
	case 't':
		strings.write_byte(b, '\t')
	case 'n':
		strings.write_byte(b, '\n')
	case 'f':
		strings.write_byte(b, '\f')
	case 'r':
		strings.write_byte(b, '\r')
	case 'e':
		strings.write_byte(b, 0x1b)
	case '"':
		strings.write_byte(b, '"')
	case '\\':
		strings.write_byte(b, '\\')
	case 'x', 'u', 'U':
		width := 2 if e == 'x' else (4 if e == 'u' else 8)
		if p.pos + width > len(p.src) {
			return tp_fail(p, "invalid \\%c escape", rune(e))
		}
		cp, ok := strconv.parse_u64_of_base(p.src[p.pos:p.pos + width], 16)
		hex := p.src[p.pos:p.pos + width]
		for i in 0 ..< len(hex) {
			c := hex[i]
			if !(tp_is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
				ok = false
			}
		}
		if !ok || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) {
			return tp_fail(p, "invalid unicode escape \\%c%s", rune(e), hex)
		}
		p.pos += width
		buf, n := utf8.encode_rune(rune(cp))
		strings.write_bytes(b, buf[:n])
	case:
		return tp_fail(p, "invalid escape sequence \\%c", rune(e))
	}
	return true
}

// ---------------------------------------------------------------------------
// Lexing helpers
// ---------------------------------------------------------------------------

@(private = "file")
tp_peek :: proc(p: ^TomlParser) -> byte {
	return p.src[p.pos] if p.pos < len(p.src) else 0
}

@(private = "file")
tp_at :: proc(p: ^TomlParser, s: string) -> bool {
	return strings.has_prefix(p.src[p.pos:], s)
}

@(private = "file")
tp_adv :: proc(p: ^TomlParser) {
	if p.src[p.pos] == '\n' {
		p.line += 1
	}
	p.pos += 1
}

@(private = "file")
tp_skip_ws :: proc(p: ^TomlParser) {
	for p.pos < len(p.src) && (p.src[p.pos] == ' ' || p.src[p.pos] == '\t') {p.pos += 1}
}

@(private = "file")
tp_skip_comment :: proc(p: ^TomlParser) {
	for p.pos < len(p.src) && p.src[p.pos] != '\n' {p.pos += 1}
}

@(private = "file")
tp_skip_ws_nl_comments :: proc(p: ^TomlParser) {
	for p.pos < len(p.src) {
		switch p.src[p.pos] {
		case ' ', '\t', '\r':
			p.pos += 1
		case '\n':
			tp_adv(p)
		case '#':
			tp_skip_comment(p)
		case:
			return
		}
	}
}

// After a statement: optional whitespace and comment, then newline or EOF.
@(private = "file")
tp_end_of_line :: proc(p: ^TomlParser) -> bool {
	tp_skip_ws(p)
	if tp_peek(p) == '#' {
		tp_skip_comment(p)
	}
	if p.pos >= len(p.src) {
		return true
	}
	if tp_at(p, "\r\n") {
		p.pos += 1
	}
	if p.src[p.pos] == '\n' {
		tp_adv(p); return true
	}
	return tp_fail(p, "unexpected text %q after the value", tp_rest_of_line(p))
}

@(private = "file")
tp_rest_of_line :: proc(p: ^TomlParser) -> string {
	end := strings.index_byte(p.src[p.pos:], '\n')
	s := p.src[p.pos:] if end < 0 else p.src[p.pos:p.pos + end]
	return strings.trim_space(s)
}

// Record the statement's first error; always returns false.
@(private = "file")
tp_fail :: proc(p: ^TomlParser, format: string, args: ..any) -> bool {
	if len(p.err) == 0 {
		p.err = fmt.aprintf(format, ..args)
		p.err_line = p.line
	}
	return false
}
