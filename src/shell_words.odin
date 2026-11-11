// shell_words.odin - Shell word tokenizer (POSIX sh/bash/zsh and fish)
//
// Splits shell source into newline-terminated statements of words and
// operators, performing quote removal the way the shell does: single
// quotes, double quotes, $'...' (ANSI-C), backslash escapes and line
// continuations. Expansions ($VAR, ${...}, $(...), backticks) are NOT
// performed; they stay verbatim in the decoded text, and `ShellWord.active`
// records which bytes the shell could still expand (i.e. were not protected
// by quoting). Consumers use that mask to decide whether a value can be
// carried over to another representation without changing its meaning.
//
// The tokenizer never guesses: anything it cannot decode exactly
// (unterminated quotes, here-documents, unsupported escapes) is reported as
// a statement error, and the rest of the input is folded into that
// statement so no later line is misread.

package wayu

import "core:strings"

ShellDialect :: enum {
	POSIX,
	FISH,
}

// One decoded word. `active[i]` is true when text[i] was not quoted, so the
// shell may still expand it (unquoted bytes, and `$`/backtick inside double
// quotes). Both fields are heap-allocated.
ShellWord :: struct {
	text:   string,
	active: []bool,
}

ShellTokenKind :: enum {
	Word,
	Op,
}

ShellToken :: struct {
	kind: ShellTokenKind,
	op:   string, // Op only: operator text (slice of the source)
	word: ShellWord, // Word only
}

// Tokens between two unquoted newlines. Line numbers are 1-based and
// inclusive (a statement spans several lines when a quote or a `\`
// continuation crosses a newline). `error` is a static description when the
// statement could not be tokenized exactly.
ShellStatement :: struct {
	tokens:     [dynamic]ShellToken,
	first_line: int,
	last_line:  int,
	error:      string,
}

shell_statements_destroy :: proc(stmts: ^[dynamic]ShellStatement) {
	for &st in stmts {
		for &tok in st.tokens {
			if tok.kind == .Word {
				delete(tok.word.text)
				delete(tok.word.active)
			}
		}
		delete(st.tokens)
	}
	delete(stmts^)
}

@(private = "file")
shell_is_op_byte :: proc(c: u8) -> bool {
	switch c {
	case ';', '&', '|', '<', '>', '(', ')':
		return true
	}
	return false
}

@(private = "file")
shell_is_blank :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\r'
}

// Word builder: decoded bytes plus the parallel "active" mask.
@(private = "file")
WordBuf :: struct {
	text:   strings.Builder,
	active: [dynamic]bool,
}

@(private = "file")
wb_put :: proc(w: ^WordBuf, c: u8, active: bool) {
	strings.write_byte(&w.text, c)
	append(&w.active, active)
}

@(private = "file")
wb_destroy :: proc(w: ^WordBuf) {
	strings.builder_destroy(&w.text)
	delete(w.active)
}

// Tokenize `content` into statements. Caller frees with
// shell_statements_destroy. Blank and comment-only lines produce no
// statement.
shell_parse_statements :: proc(content: string, dialect: ShellDialect) -> [dynamic]ShellStatement {
	out := make([dynamic]ShellStatement)
	s := content
	i := 0
	line := 1
	cur := ShellStatement {
		first_line = 1,
		last_line  = 1,
	}

	flush :: proc(out: ^[dynamic]ShellStatement, cur: ^ShellStatement, line: int) {
		if len(cur.tokens) > 0 || len(cur.error) > 0 {
			cur.last_line = line
			append(out, cur^)
		} else {
			delete(cur.tokens)
		}
		cur^ = {}
	}

	// On error the remainder of the input belongs to the failing statement:
	// the quoting state is unknown, so nothing after it can be trusted.
	fail :: proc(
		out: ^[dynamic]ShellStatement,
		cur: ^ShellStatement,
		s: string,
		line: int,
		msg: string,
	) {
		cur.error = msg
		last := line + strings.count(s, "\n")
		if strings.has_suffix(s, "\n") {
			last -= 1
		}
		cur.last_line = max(last, cur.first_line)
		append(out, cur^)
		cur^ = {}
	}

	for i < len(s) {
		c := s[i]
		switch {
		case c == '\n':
			flush(&out, &cur, line)
			line += 1
			i += 1
			cur.first_line = line
		case shell_is_blank(c):
			i += 1
		case c == '#':
			// Comment (only reached at a word boundary).
			for i < len(s) && s[i] != '\n' {i += 1}
		case c == '\\' && i + 1 < len(s) && s[i + 1] == '\n':
			line += 1
			i += 2
		case shell_is_op_byte(c):
			start := i
			if c == '(' || c == ')' {
				i += 1
			} else {
				for i < len(s) &&
				    (s[i] == ';' ||
						    s[i] == '&' ||
						    s[i] == '|' ||
						    s[i] == '<' ||
						    s[i] == '>') {i += 1}
			}
			op := s[start:i]
			append(&cur.tokens, ShellToken{kind = .Op, op = op})
			if strings.has_prefix(op, "<<") && op != "<<<" {
				fail(&out, &cur, s[i:], line, "here-document")
				return out
			}
		case:
			w, err := shell_read_word(s, &i, &line, dialect)
			if len(err) > 0 {
				fail(&out, &cur, s[i:], line, err)
				return out
			}
			append(&cur.tokens, ShellToken{kind = .Word, word = w})
		}
	}
	flush(&out, &cur, line)
	return out
}

// Copy a `$(...)` or `${...}` region verbatim as active bytes. `i` points
// at the opening `(` / `{`. Quoting inside the region is honored (single,
// double, backtick, backslash, nested `$(` / `${`), so a quoted `)` or `}`
// does not end it. `in_dq`: the expansion sits inside double quotes. Returns
// "" or an error: unterminated, or a construct whose end only a full shell
// parser could find (a comment, `case` or a here-document inside `$(...)`, a
// single quote inside a double-quoted `${...}`), so the caller treats the
// rest as unreadable instead of guessing.
@(private = "file")
shell_copy_expansion :: proc(
	s: string,
	i: ^int,
	line: ^int,
	w: ^WordBuf,
	dialect: ShellDialect,
	in_dq: bool,
	nesting := 0,
) -> string {
	if nesting >= SHELL_MAX_NESTING {
		return "expansion nested too deeply"
	}
	brace := s[i^] == '{'
	wb_put(w, s[i^], true)
	i^ += 1
	depth := 1
	word_start := true
	for i^ < len(s) {
		c := s[i^]
		if !brace && word_start {
			if c == '#' {
				return "comment inside $(...)"
			}
			if strings.has_prefix(s[i^:], "case") &&
			   (i^ + 4 == len(s) || shell_is_blank(s[i^ + 4]) || s[i^ + 4] == '\n') {
				return "case inside $(...)"
			}
		}
		word_start = c == '\n' || shell_is_blank(c) || shell_is_op_byte(c)
		switch c {
		case '\n':
			line^ += 1
		case '\\':
			wb_put(w, c, true)
			i^ += 1
			if i^ < len(s) {
				if s[i^] == '\n' {
					line^ += 1
				}
				wb_put(w, s[i^], true)
				i^ += 1
			}
			continue
		case '\'':
			if brace && in_dq {
				return "single quote inside a double-quoted ${...}"
			}
			wb_put(w, c, true)
			i^ += 1
			if !shell_copy_until(s, i, line, w, '\'', dialect == .FISH) {
				return "unterminated expansion"
			}
			continue
		case '"':
			wb_put(w, c, true)
			i^ += 1
			if e := shell_copy_dq_raw(s, i, line, w, dialect, nesting + 1); len(e) > 0 {
				return e
			}
			continue
		case '`':
			if dialect == .POSIX {
				wb_put(w, c, true)
				i^ += 1
				if !shell_copy_until(s, i, line, w, '`', true) {
					return "unterminated backtick"
				}
				continue
			}
		case '$':
			wb_put(w, c, true)
			i^ += 1
			if i^ < len(s) && (s[i^] == '(' || (dialect == .POSIX && s[i^] == '{')) {
				// Quoting starts afresh inside $(...); a ${...} nested in a
				// ${...} keeps its context.
				if e := shell_copy_expansion(s, i, line, w, dialect, brace && in_dq, nesting + 1);
				   len(e) > 0 {
					return e
				}
			}
			continue
		case '<':
			if !brace && strings.has_prefix(s[i^:], "<<") {
				if !strings.has_prefix(s[i^:], "<<<") {
					return "here-document inside $(...)"
				}
				for _ in 0 ..< 3 {wb_put(w, '<', true)}
				i^ += 3
				continue
			}
		case '(':
			if !brace {
				depth += 1
			}
		case ')':
			if !brace {
				depth -= 1
			}
		case '{':
			if brace {
				depth += 1
			}
		case '}':
			if brace {
				depth -= 1
			}
		}
		wb_put(w, c, true)
		i^ += 1
		if depth == 0 {
			return ""
		}
	}
	return "unterminated expansion"
}

// Nesting cap for expansions inside expansions: deeper input is reported as
// unreadable instead of recursing without bound.
SHELL_MAX_NESTING :: 64

// Copy bytes verbatim (active) up to and including `close`; `i` points just
// past the opening byte. `escapes`: a backslash protects the next byte.
@(private = "file")
shell_copy_until :: proc(
	s: string,
	i: ^int,
	line: ^int,
	w: ^WordBuf,
	close: u8,
	escapes: bool,
) -> bool {
	for i^ < len(s) {
		d := s[i^]
		wb_put(w, d, true)
		i^ += 1
		if d == '\n' {
			line^ += 1
		}
		if escapes && d == '\\' && i^ < len(s) {
			if s[i^] == '\n' {
				line^ += 1
			}
			wb_put(w, s[i^], true)
			i^ += 1
			continue
		}
		if d == close {
			return true
		}
	}
	return false
}

// Copy a double-quoted string inside an expansion verbatim (active); `i`
// points just past the opening quote.
@(private = "file")
shell_copy_dq_raw :: proc(
	s: string,
	i: ^int,
	line: ^int,
	w: ^WordBuf,
	dialect: ShellDialect,
	nesting: int,
) -> string {
	for i^ < len(s) {
		d := s[i^]
		wb_put(w, d, true)
		i^ += 1
		switch d {
		case '"':
			return ""
		case '\n':
			line^ += 1
		case '\\':
			if i^ < len(s) {
				if s[i^] == '\n' {
					line^ += 1
				}
				wb_put(w, s[i^], true)
				i^ += 1
			}
		case '`':
			if dialect == .POSIX && !shell_copy_until(s, i, line, w, '`', true) {
				return "unterminated backtick"
			}
		case '$':
			if i^ < len(s) && (s[i^] == '(' || (dialect == .POSIX && s[i^] == '{')) {
				if e := shell_copy_expansion(s, i, line, w, dialect, true, nesting); len(e) > 0 {
					return e
				}
			}
		}
	}
	return "unterminated double quote"
}

// Read one word starting at s[i^]. Advances i past it.
@(private = "file")
shell_read_word :: proc(
	s: string,
	i: ^int,
	line: ^int,
	dialect: ShellDialect,
) -> (
	word: ShellWord,
	err: string,
) {
	w: WordBuf
	strings.builder_init(&w.text)
	w.active = make([dynamic]bool)

	ok := true
	loop: for i^ < len(s) {
		c := s[i^]
		if c == '\n' || shell_is_blank(c) || shell_is_op_byte(c) {
			break loop
		}

		switch c {
		case '\'':
			i^ += 1
			closed := false
			for i^ < len(s) {
				d := s[i^]
				if d == '\'' {
					closed = true; i^ += 1; break
				}
				if dialect == .FISH &&
				   d == '\\' &&
				   i^ + 1 < len(s) &&
				   (s[i^ + 1] == '\'' || s[i^ + 1] == '\\') {
					wb_put(&w, s[i^ + 1], false)
					i^ += 2
					continue
				}
				if d == '\n' {
					line^ += 1
				}
				wb_put(&w, d, false)
				i^ += 1
			}
			if !closed {
				err = "unterminated single quote"; ok = false; break loop
			}

		case '"':
			i^ += 1
			if e := shell_read_dq(s, i, line, &w, dialect); len(e) > 0 {
				err = e; ok = false; break loop
			}

		case '\\':
			if i^ + 1 >= len(s) {
				err = "trailing backslash"; ok = false; break loop
			}
			n := s[i^ + 1]
			if n == '\n' {
				line^ += 1
				i^ += 2
				continue
			}
			if dialect == .FISH &&
			   ((n >= 'a' && n <= 'z') || (n >= 'A' && n <= 'Z') || (n >= '0' && n <= '9')) {
				// fish turns \n, \t, \xHH, ... into control characters.
				err = "fish escape sequence"; ok = false; break loop
			}
			wb_put(&w, n, false)
			i^ += 2

		case '$':
			if i^ + 1 < len(s) {
				n := s[i^ + 1]
				if dialect == .POSIX && n == '\'' {
					i^ += 2
					if e := shell_read_ansi_c(s, i, line, &w); len(e) > 0 {
						err = e; ok = false; break loop
					}
					continue
				}
				if dialect == .POSIX && n == '"' {
					// $"..." (locale translation) is a double-quoted string.
					i^ += 2
					if e := shell_read_dq(s, i, line, &w, dialect); len(e) > 0 {
						err = e; ok = false; break loop
					}
					continue
				}
				if n == '(' || (dialect == .POSIX && n == '{') {
					wb_put(&w, '$', true)
					i^ += 1
					if e := shell_copy_expansion(s, i, line, &w, dialect, false); len(e) > 0 {
						err = e; ok = false; break loop
					}
					continue
				}
			}
			wb_put(&w, '$', true)
			i^ += 1

		case '`':
			if dialect == .FISH {
				wb_put(&w, c, true)
				i^ += 1
				continue
			}
			wb_put(&w, c, true)
			i^ += 1
			closed := false
			for i^ < len(s) {
				d := s[i^]
				wb_put(&w, d, true)
				i^ += 1
				if d == '\n' {
					line^ += 1
				}
				if d == '\\' && i^ < len(s) {
					wb_put(&w, s[i^], true); i^ += 1; continue
				}
				if d == '`' {
					closed = true; break
				}
			}
			if !closed {
				err = "unterminated backtick"; ok = false; break loop
			}

		case:
			wb_put(&w, c, true)
			i^ += 1
		}
	}

	if !ok {
		wb_destroy(&w)
		return {}, err
	}
	text := strings.clone(strings.to_string(w.text))
	active := make([]bool, len(w.active))
	copy(active, w.active[:])
	wb_destroy(&w)
	return ShellWord{text = text, active = active}, ""
}

// Body of a double-quoted string; i points just past the opening quote.
@(private = "file")
shell_read_dq :: proc(
	s: string,
	i: ^int,
	line: ^int,
	w: ^WordBuf,
	dialect: ShellDialect,
) -> string {
	for i^ < len(s) {
		d := s[i^]
		switch d {
		case '"':
			i^ += 1
			return ""
		case '\\':
			if i^ + 1 < len(s) {
				n := s[i^ + 1]
				if n == '\n' {
					line^ += 1; i^ += 2; continue
				}
				escapable := n == '"' || n == '\\' || n == '$' || (dialect == .POSIX && n == '`')
				if escapable {
					wb_put(w, n, false)
					i^ += 2
					continue
				}
			}
			wb_put(w, d, false)
			i^ += 1
		case '$':
			if i^ + 1 < len(s) && (s[i^ + 1] == '(' || (dialect == .POSIX && s[i^ + 1] == '{')) {
				wb_put(w, '$', true)
				i^ += 1
				if e := shell_copy_expansion(s, i, line, w, dialect, true); len(e) > 0 {
					return e
				}
				continue
			}
			wb_put(w, d, true)
			i^ += 1
		case '`':
			wb_put(w, d, dialect == .POSIX)
			i^ += 1
		case:
			if d == '\n' {
				line^ += 1
			}
			wb_put(w, d, false)
			i^ += 1
		}
	}
	return "unterminated double quote"
}

// Body of $'...'; i points just past the opening quote. Only the escapes
// with a single-byte result are supported; anything else is an error
// rather than a guess.
@(private = "file")
shell_read_ansi_c :: proc(s: string, i: ^int, line: ^int, w: ^WordBuf) -> string {
	for i^ < len(s) {
		d := s[i^]
		if d == '\'' {
			i^ += 1; return ""
		}
		if d == '\\' {
			if i^ + 1 >= len(s) {
				break
			}
			out: u8
			switch s[i^ + 1] {
			case '\\':
				out = '\\'
			case '\'':
				out = '\''
			case '"':
				out = '"'
			case '?':
				out = '?'
			case 'n':
				out = '\n'
			case 't':
				out = '\t'
			case 'r':
				out = '\r'
			case 'a':
				out = 0x07
			case 'b':
				out = 0x08
			case 'e', 'E':
				out = 0x1b
			case 'f':
				out = 0x0c
			case 'v':
				out = 0x0b
			case:
				return "unsupported $'...' escape"
			}
			wb_put(w, out, false)
			i^ += 2
			continue
		}
		if d == '\n' {
			line^ += 1
		}
		wb_put(w, d, false)
		i^ += 1
	}
	return "unterminated $'...' string"
}
