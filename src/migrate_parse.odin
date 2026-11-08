// migrate_parse.odin - Legacy shell config analysis for `wayu migrate`
//
// Turns a legacy aliases/constants/path file into the entries wayu.toml can
// hold, using the shell word tokenizer (shell_words.odin) so quoting is
// decoded exactly as the shell would. Every non-blank, non-comment line is
// accounted for: it either becomes an entry or is reported as an issue with
// a reason. Lines that are wayu's own scaffolding (the shipped templates)
// are recognised and skipped. migrate refuses to change anything while a
// file has issues, so nothing a user wrote is silently dropped.

package wayu

import "core:fmt"
import "core:strings"

LegacyKind :: enum { Path, Alias, Constant }

// One migratable definition. name/value are heap-allocated. For .Path the
// directory is in `value` and `name` is empty.
LegacyEntry :: struct {
	kind:  LegacyKind,
	name:  string,
	value: string,
	line:  int,
}

// A statement that could not be migrated. Lines are 1-based, inclusive.
// `reason` is heap-allocated.
LegacyIssue :: struct {
	first_line: int,
	last_line:  int,
	reason:     string,
}

LegacyAnalysis :: struct {
	entries: [dynamic]LegacyEntry,
	issues:  [dynamic]LegacyIssue,
}

legacy_analysis_destroy :: proc(a: ^LegacyAnalysis) {
	for e in a.entries { delete(e.name); delete(e.value) }
	delete(a.entries)
	for is in a.issues { delete(is.reason) }
	delete(a.issues)
}

// Trimmed non-blank lines of every legacy template for `dialect`: content
// wayu itself wrote, which is not user data.
@(private = "file")
legacy_template_lines :: proc(dialect: ShellDialect) -> map[string]bool {
	set := make(map[string]bool)
	templates: []string
	if dialect == .FISH {
		templates = {PATH_TEMPLATE_FISH, ALIASES_TEMPLATE_FISH, CONSTANTS_TEMPLATE_FISH}
	} else {
		templates = {
			PATH_TEMPLATE_ZSH, ALIASES_TEMPLATE_ZSH, CONSTANTS_TEMPLATE_ZSH,
			PATH_TEMPLATE_BASH, ALIASES_TEMPLATE_BASH, CONSTANTS_TEMPLATE_BASH,
		}
	}
	for t in templates {
		rest := t
		for l in strings.split_lines_iterator(&rest) {
			tl := strings.trim_space(l)
			if len(tl) > 0 { set[tl] = true }
		}
	}
	if dialect == .POSIX {
		for l in LEGACY_TEMPLATE_LINES_V2 { set[l] = true }
	}
	return set
}

// Lines of the add_to_path() helper older path templates shipped (v2.x),
// beyond what the current templates contain.
@(private = "file")
LEGACY_TEMPLATE_LINES_V2 :: []string{
	"add_to_path() {",
	`local dir="$1"`,
	`local position="${2:-prepend}"  # prepend or append, default is prepend`,
	`if [ "$position" = "append" ]; then`,
	`export PATH="$PATH:$dir"`,
	"return 0",
	"return 1",
	`export PATH=$(echo "$PATH" | awk -v RS=':' -v ORS=':' '!seen[$0]++' | sed 's/:$//')`,
}

// Bytes that make a preceding `$` start an expansion in a double-quoted
// string (zsh's `$=`, `$^`, `$~`, `$+` and `$[` included).
@(private = "file")
legacy_expands_after_dollar :: proc(c: u8) -> bool {
	switch c {
	case 'a'..='z', 'A'..='Z', '0'..='9', '_', '{', '[', '@', '*', '#', '?', '$', '!', '-', '=', '^', '~', '+':
		return true
	}
	return false
}

// Can `w` be stored as a wayu.toml env/path value without changing what the
// shell ends up with? wayu emits those values as `"value"` with `$VAR`
// expanding, `$(`, backticks, `\` and `"` neutralised, and a leading `~/`
// rewritten to `$HOME/`. Returns "" when it can, else the reason.
legacy_value_check :: proc(w: ShellWord, dialect: ShellDialect) -> string {
	t := w.text
	if strings.contains_any(t, "\n\r") { return "multi-line value" }
	if strings.contains_rune(t, 0) { return "NUL byte in value" }
	for i in 0..<len(t) {
		c := t[i]
		next: u8 = i + 1 < len(t) ? t[i+1] : 0
		switch c {
		case '$':
			if w.active[i] {
				if next == '(' { return "command substitution $(...)" }
			} else if next != 0 && legacy_expands_after_dollar(next) {
				return "quoted '$' would start an expansion in wayu.toml"
			}
		case '`':
			if w.active[i] && dialect == .POSIX { return "command substitution `...`" }
		case '~':
			at_start := i == 0 && (next == 0 || next == '/')
			if w.active[i] && !at_start { return "tilde expansion not at the start of the value" }
			if !w.active[i] && at_start { return "quoted '~' would expand to $HOME in wayu.toml" }
		case '*', '?', '[', '{', '}':
			if w.active[i] && dialect == .FISH { return "unquoted glob/brace expansion" }
		}
	}
	return ""
}

// Can `body` (an alias definition's value, as a slice of a word) be stored
// as a wayu.toml alias command? The command is emitted single-quoted, i.e.
// verbatim, so expansions simply happen when the alias runs. Only things the
// shell would have expanded while *defining* the alias are refused.
legacy_alias_body_check :: proc(text: string, active: []bool) -> string {
	if strings.contains_any(text, "\n\r") { return "multi-line alias" }
	if len(strings.trim_space(text)) == 0 { return "empty alias command" }
	for i in 0..<len(text) {
		if !active[i] { continue }
		switch text[i] {
		case '*', '?', '[':
			return "unquoted glob in alias definition"
		case '{':
			if i == 0 || text[i-1] != '$' { return "unquoted brace expansion in alias definition" }
		}
	}
	return ""
}

@(private = "file")
legacy_word_is :: proc(tok: ShellToken, s: string) -> bool {
	return tok.kind == .Word && tok.word.text == s
}

// Track if/for/while/case/function nesting so definitions inside a block
// (conditional exports, function bodies) are reported, not hoisted.
@(private = "file")
legacy_depth_delta :: proc(tokens: []ShellToken, dialect: ShellDialect) -> int {
	delta := 0
	cmd_start := true
	for tok in tokens {
		if tok.kind == .Op {
			cmd_start = tok.op != ")"
			continue
		}
		t := tok.word.text
		if dialect == .FISH {
			if cmd_start {
				switch t {
				case "if", "for", "while", "function", "switch", "begin": delta += 1
				case "end":                                               delta -= 1
				}
			}
		} else {
			if cmd_start {
				switch t {
				case "if", "case", "for", "while", "until", "select": delta += 1
				case "fi", "esac", "done":                           delta -= 1
				}
			}
			// `{` / `}` are reserved words only when unquoted.
			if len(tok.word.active) == 1 && tok.word.active[0] {
				if t == "{" { delta += 1 }
				if t == "}" { delta -= 1 }
			}
		}
		cmd_start = false
		if dialect == .POSIX && (t == "then" || t == "do" || t == "else" || t == "elif") { cmd_start = true }
	}
	return delta
}

// Analyze one legacy file. `content` may contain any mix of aliases,
// exports and PATH registry entries.
legacy_analyze :: proc(content: string, dialect: ShellDialect) -> LegacyAnalysis {
	a := LegacyAnalysis{
		entries = make([dynamic]LegacyEntry),
		issues  = make([dynamic]LegacyIssue),
	}

	stmts := shell_parse_statements(content, dialect)
	defer shell_statements_destroy(&stmts)

	template := legacy_template_lines(dialect)
	defer delete(template)

	src_lines := strings.split_lines(content)
	defer delete(src_lines)

	is_template :: proc(st: ShellStatement, src_lines: []string, template: map[string]bool) -> bool {
		for n in st.first_line..=st.last_line {
			if n < 1 || n > len(src_lines) { return false }
			tl := strings.trim_space(src_lines[n-1])
			if len(tl) == 0 || strings.has_prefix(tl, "#") { continue }
			if !(tl in template) { return false }
		}
		return true
	}

	issue :: proc(a: ^LegacyAnalysis, st: ShellStatement, reason: string) {
		append(&a.issues, LegacyIssue{first_line = st.first_line, last_line = st.last_line, reason = strings.clone(reason)})
	}

	// Pending entries of one statement: a statement migrates all-or-nothing.
	pending := make([dynamic]LegacyEntry)
	defer delete(pending)
	drop_pending :: proc(p: ^[dynamic]LegacyEntry) {
		for e in p { delete(e.name); delete(e.value) }
		clear(p)
	}
	add :: proc(p: ^[dynamic]LegacyEntry, kind: LegacyKind, name, value: string, line: int) {
		append(p, LegacyEntry{kind = kind, name = strings.clone(name), value = strings.clone(value), line = line})
	}

	depth := 0
	in_array := false // inside a multi-line WAYU_PATHS=( ... )

	for st in stmts {
		toks := st.tokens[:]
		if len(st.error) > 0 {
			issue(&a, st, st.error)
			continue
		}

		reason := ""

		// WAYU_PATHS=( "dir" ... ) — single- or multi-line.
		array_toks: []ShellToken
		if in_array {
			array_toks = toks
		} else if len(toks) >= 2 && legacy_word_is(toks[0], "WAYU_PATHS=") && toks[1].kind == .Op && toks[1].op == "(" && depth == 0 {
			in_array = true
			array_toks = toks[2:]
		}
		if in_array {
			for tok, k in array_toks {
				if tok.kind == .Op {
					if tok.op == ")" {
						in_array = false
						if k != len(array_toks) - 1 { reason = "code after WAYU_PATHS=( ... )" }
					} else {
						reason = "unexpected operator in WAYU_PATHS"
					}
					continue
				}
				if r := legacy_value_check(tok.word, dialect); len(r) > 0 { reason = r; continue }
				add(&pending, .Path, "", tok.word.text, st.first_line)
			}
			if len(reason) > 0 {
				drop_pending(&pending)
				issue(&a, st, reason)
			} else {
				append(&a.entries, ..pending[:])
				clear(&pending)
			}
			continue
		}

		before := depth
		depth += legacy_depth_delta(toks, dialect)
		unbalanced := depth < 0
		if depth < 0 { depth = 0 }

		if is_template(st, src_lines, template) { continue }

		has_op := false
		for tok in toks { if tok.kind == .Op { has_op = true; break } }

		switch {
		case unbalanced:
			reason = "unbalanced block terminator"
		case before > 0:
			reason = "inside a shell block (if/for/function...)"
		case depth > 0:
			reason = "shell control flow or function definition"
		case has_op:
			reason = "compound command (; && || | redirection or subshell)"
		case:
			reason = legacy_statement_entries(toks, dialect, st.first_line, &pending)
		}

		if len(reason) > 0 {
			drop_pending(&pending)
			issue(&a, st, reason)
		} else {
			append(&a.entries, ..pending[:])
			clear(&pending)
		}
	}

	if in_array && len(stmts) > 0 {
		last := stmts[len(stmts)-1]
		append(&a.issues, LegacyIssue{first_line = last.first_line, last_line = last.last_line, reason = strings.clone("WAYU_PATHS=( is never closed")})
	}
	return a
}

// Extract the entries of one simple command (no operators). Returns "" and
// fills `out`, or the reason the command can't be migrated.
@(private = "file")
legacy_statement_entries :: proc(toks: []ShellToken, dialect: ShellDialect, line: int, out: ^[dynamic]LegacyEntry) -> string {
	add :: proc(p: ^[dynamic]LegacyEntry, kind: LegacyKind, name, value: string, line: int) {
		append(p, LegacyEntry{kind = kind, name = strings.clone(name), value = strings.clone(value), line = line})
	}
	// NAME=value assignment word → constant.
	assign :: proc(w: ShellWord, dialect: ShellDialect, line: int, out: ^[dynamic]LegacyEntry) -> string {
		eq := strings.index_byte(w.text, '=')
		if eq < 0 { return "exports an existing variable without setting a value" }
		if eq == 0 { return "assignment without a name" }
		name := w.text[:eq]
		if name == "PATH" { return "PATH edits belong in [paths] (use `wayu path add`)" }
		val := ShellWord{text = w.text[eq+1:], active = w.active[eq+1:]}
		if r := legacy_value_check(val, dialect); len(r) > 0 { return r }
		add(out, .Constant, name, val.text, line)
		return ""
	}

	cmd := toks[0].word.text
	args := toks[1:]

	if dialect == .FISH {
		switch cmd {
		case "alias":
			if len(args) > 0 && strings.has_prefix(args[0].word.text, "-") { return "alias options are not supported" }
			name, body: string
			body_active: []bool
			switch len(args) {
			case 1:
				w := args[0].word
				eq := strings.index_byte(w.text, '=')
				if eq <= 0 { return "not an alias definition" }
				name, body, body_active = w.text[:eq], w.text[eq+1:], w.active[eq+1:]
			case 2:
				name, body, body_active = args[0].word.text, args[1].word.text, args[1].word.active
			case:
				return "not an alias definition"
			}
			if r := legacy_alias_body_check(body, body_active); len(r) > 0 { return r }
			add(out, .Alias, name, body, line)
			return ""
		case "set":
			exported := false
			k := 0
			for ; k < len(args) && strings.has_prefix(args[k].word.text, "-"); k += 1 {
				f := args[k].word.text
				switch f {
				case "--global", "--universal": continue
				case "--export":                exported = true; continue
				}
				if strings.has_prefix(f, "--") { return "unsupported set option" }
				for ch in f[1:] {
					switch ch {
					case 'g', 'U': // scope only
					case 'x':      exported = true
					case 'a', 'p':
						// `set -a WAYU_PATHS dir` (path registry) is handled below.
						if !(k + 1 < len(args) && args[k+1].word.text == "WAYU_PATHS") { return "unsupported set option" }
					case:          return "unsupported set option"
					}
				}
			}
			if k >= len(args) { return "set without a variable" }
			name := args[k].word.text
			values := args[k+1:]
			if name == "WAYU_PATHS" {
				for v in values {
					if r := legacy_value_check(v.word, dialect); len(r) > 0 { return r }
					add(out, .Path, "", v.word.text, line)
				}
				return ""
			}
			if name == "PATH" || name == "fish_user_paths" { return "PATH edits belong in [paths] (use `wayu path add`)" }
			if !exported { return "variable is not exported (needs -x)" }
			if len(values) != 1 { return "fish list variable (needs exactly one value)" }
			if r := legacy_value_check(values[0].word, dialect); len(r) > 0 { return r }
			add(out, .Constant, name, values[0].word.text, line)
			return ""
		case "fish_add_path":
			k := 0
			for k < len(args) && strings.has_prefix(args[k].word.text, "-") { k += 1 }
			if k >= len(args) { return "fish_add_path without a directory" }
			for v in args[k:] {
				if r := legacy_value_check(v.word, dialect); len(r) > 0 { return r }
				add(out, .Path, "", v.word.text, line)
			}
			return ""
		}
		return "not an alias, exported variable or PATH entry"
	}

	switch cmd {
	case "alias":
		if len(args) == 0 { return "alias without a definition" }
		for a in args {
			w := a.word
			if strings.has_prefix(w.text, "-") { return "alias options (-g/-s) are not supported" }
			eq := strings.index_byte(w.text, '=')
			if eq <= 0 { return "prints an alias instead of defining one" }
			if r := legacy_alias_body_check(w.text[eq+1:], w.active[eq+1:]); len(r) > 0 { return r }
			add(out, .Alias, w.text[:eq], w.text[eq+1:], line)
		}
		return ""
	case "export", "typeset", "declare":
		k := 0
		exported := cmd == "export"
		for ; k < len(args) && strings.has_prefix(args[k].word.text, "-"); k += 1 {
			f := args[k].word.text
			if cmd == "export" { return "export options are not supported" }
			for ch in f[1:] {
				switch ch {
				case 'x': exported = true
				case 'g': // global scope: same as top level
				case:     return "unsupported typeset/declare option"
				}
			}
		}
		if !exported { return "variable is not exported" }
		if k >= len(args) { return "export without a variable" }
		for a in args[k:] {
			if r := assign(a.word, dialect, line, out); len(r) > 0 { return r }
		}
		return ""
	case "add_to_path":
		// wayu v2.x registry helper.
		if len(args) != 1 { return "add_to_path takes exactly one directory" }
		if r := legacy_value_check(args[0].word, dialect); len(r) > 0 { return r }
		add(out, .Path, "", args[0].word.text, line)
		return ""
	}
	if strings.contains_rune(cmd, '=') { return "shell variable is not exported (use export)" }
	return "not an alias, export or PATH entry"
}

// Render the source lines of an issue as "file:line: text" for the user.
legacy_print_issue :: proc(file_label: string, content: string, is: LegacyIssue) {
	lines := strings.split_lines(content)
	defer delete(lines)
	last := min(is.last_line, len(lines))
	// Long blocks (an unterminated quote swallows the rest of the file)
	// are summarised instead of dumped.
	shown := 0
	for n in is.first_line..=last {
		if n < 1 { continue }
		if shown == 6 {
			fmt.eprintfln("  %s:%d-%d: ... (%d more lines)", file_label, n, last, last - n + 1)
			break
		}
		fmt.eprintfln("  %s:%d: %s", file_label, n, lines[n-1])
		shown += 1
	}
	eprintfln_color("      %s↳ %s%s", get_muted(), is.reason, RESET)
}
