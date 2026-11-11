// Package markdown renders the Markdown in docs/*.md to the HTML the docs
// viewer (docs/docs/) styles, at build time (`./build_it docs`).
//
// It covers what the docs use, GFM-style: ATX headings with GitHub slug ids,
// paragraphs, nested and loose lists, fenced and indented code, tables,
// blockquotes, thematic breaks, and inline code, emphasis, links, autolinks,
// backslash escapes and hard breaks. Raw HTML is not passed through: `<ext>`
// in prose is shown as typed. Setext headings, link reference definitions,
// images and footnotes are not supported (the docs use none).
//
// The output carries the viewer's decorations: a "#" anchor in every h2-h4,
// a bold-only paragraph turned into an anchored sub-heading (class
// "pseudo-h"), tables wrapped in div.table-wrap, code blocks in div.code with
// a copy button, short inline code marked class "nw" (never wraps).
package markdown

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Inline code up to this many characters never breaks at its hyphens.
NOWRAP_CODE_MAX :: 28

// A heading (h1-h4) or bold-only paragraph (level 0), in document order.
Heading :: struct {
	level: int,
	id:    string,
	text:  string,
}

// Rewrites a relative link target (not http(s):, mailto: or #fragment).
Link_Rewrite :: #type proc(href: string, data: rawptr) -> string

Options :: struct {
	rewrite_link: Link_Rewrite,
	data:         rawptr,
}

Document :: struct {
	html:     string,
	title:    string, // text of the first h1
	headings: []Heading,
}

// Render src. Everything returned is allocated from allocator.
render :: proc(src: string, opts := Options{}, allocator := context.allocator) -> Document {
	context.allocator = allocator
	lines := split_lines(src)
	blocks := parse_blocks(lines[:])
	r := Renderer {
		out  = strings.builder_make(),
		opts = opts,
		seen = make(map[string]int),
	}
	render_blocks(&r, blocks[:], false)
	return Document{html = strings.to_string(r.out), title = r.title, headings = r.headings[:]}
}

// GitHub's heading slug, as the docs viewer computes it: lowercase, keep
// letters, numbers, marks, spaces, '_' and '-', each space becomes '-'.
slug_base :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for r in strings.trim_space(text) {
		switch {
		case unicode.is_space(r):
			strings.write_byte(&b, '-')
		case r == '_' || r == '-' || unicode.is_letter(r) || unicode.is_number(r) || is_mark(r):
			strings.write_rune(&b, unicode.to_lower(r))
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

Kind :: enum u8 {
	Paragraph,
	Heading,
	Code,
	Quote,
	List,
	Item,
	Table,
	Rule,
}

Align :: enum u8 {
	None,
	Left,
	Center,
	Right,
}

Block :: struct {
	kind:         Kind,
	level:        int, // heading level
	text:         string, // paragraph / heading inline source, code body
	lang:         string,
	children:     [dynamic]^Block, // quote, list (its items), item
	ordered:      bool,
	start:        int,
	loose:        bool,
	blank_before: bool, // a blank line separates it from the previous sibling
	rows:         [dynamic][]string, // table, row 0 is the header
	align:        []Align,
}

@(private)
split_lines :: proc(src: string) -> [dynamic]string {
	lines: [dynamic]string
	rest := src
	for len(rest) > 0 {
		nl := strings.index_byte(rest, '\n')
		line := rest if nl == -1 else rest[:nl]
		line = strings.trim_suffix(line, "\r")
		append(&lines, line)
		rest = "" if nl == -1 else rest[nl + 1:]
	}
	return lines
}

@(private)
indent_of :: proc(line: string) -> int {
	n := 0
	for n < len(line) && line[n] == ' ' {
		n += 1
	}
	return n
}

@(private)
is_blank :: proc(line: string) -> bool {
	return len(strings.trim_space(line)) == 0
}

@(private)
strip_indent :: proc(line: string, n: int) -> string {
	i := 0
	for i < n && i < len(line) && line[i] == ' ' {
		i += 1
	}
	return line[i:]
}

@(private)
atx_heading :: proc(line: string) -> (level: int, text: string, ok: bool) {
	ind := indent_of(line)
	if ind > 3 {
		return
	}
	s := line[ind:]
	n := 0
	for n < len(s) && s[n] == '#' {
		n += 1
	}
	if n == 0 || n > 6 || (n < len(s) && s[n] != ' ') {
		return
	}
	t := strings.trim_space(s[n:])
	// Optional closing sequence: " ##".
	end := len(t)
	for end > 0 && t[end - 1] == '#' {
		end -= 1
	}
	if end == 0 {
		t = ""
	} else if end < len(t) && t[end - 1] == ' ' {
		t = strings.trim_right_space(t[:end])
	}
	return n, t, true
}

@(private)
Fence :: struct {
	char:   byte,
	length: int,
	indent: int,
	info:   string,
}

@(private)
fence_open :: proc(line: string) -> (f: Fence, ok: bool) {
	ind := indent_of(line)
	if ind > 3 {
		return
	}
	s := line[ind:]
	if len(s) < 3 || (s[0] != '`' && s[0] != '~') {
		return
	}
	n := 0
	for n < len(s) && s[n] == s[0] {
		n += 1
	}
	if n < 3 {
		return
	}
	info := strings.trim_space(s[n:])
	if s[0] == '`' && strings.contains_rune(info, '`') {
		return
	}
	return Fence{char = s[0], length = n, indent = ind, info = info}, true
}

@(private)
fence_closes :: proc(line: string, f: Fence) -> bool {
	ind := indent_of(line)
	if ind > 3 {
		return false
	}
	s := strings.trim_right_space(line[ind:])
	if len(s) < f.length {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] != f.char {
			return false
		}
	}
	return true
}

@(private)
is_rule :: proc(line: string) -> bool {
	ind := indent_of(line)
	if ind > 3 || ind >= len(line) {
		return false
	}
	c := line[ind]
	if c != '-' && c != '*' && c != '_' {
		return false
	}
	n := 0
	for i in ind ..< len(line) {
		switch line[i] {
		case c:
			n += 1
		case ' ', '\t':
		case:
			return false
		}
	}
	return n >= 3
}

@(private)
is_quote :: proc(line: string) -> bool {
	ind := indent_of(line)
	return ind <= 3 && ind < len(line) && line[ind] == '>'
}

@(private)
Marker :: struct {
	ordered: bool,
	char:    byte, // bullet, or the ordered delimiter ('.' / ')')
	start:   int,
	content: int, // column where the item's content starts
	empty:   bool,
}

@(private)
list_marker :: proc(line: string) -> (m: Marker, ok: bool) {
	ind := indent_of(line)
	if ind > 3 || is_rule(line) {
		return
	}
	s := line[ind:]
	w := 0
	if len(s) > 0 && (s[0] == '-' || s[0] == '*' || s[0] == '+') {
		m.char = s[0]
		w = 1
	} else {
		d, num := 0, 0
		for d < len(s) && d < 9 && s[d] >= '0' && s[d] <= '9' {
			num = num * 10 + int(s[d] - '0')
			d += 1
		}
		if d == 0 || d >= len(s) || (s[d] != '.' && s[d] != ')') {
			return
		}
		m.ordered, m.char, m.start = true, s[d], num
		w = d + 1
	}
	rest := s[w:]
	if len(rest) > 0 && rest[0] != ' ' {
		return
	}
	sp := indent_of(rest)
	if sp == len(rest) {
		m.empty = true
		sp = 1
	} else if sp > 4 {
		sp = 1 // content starts with an indented code block
	}
	m.content = ind + w + sp
	return m, true
}

// A line that ends a paragraph (or a table, or a lazy list continuation).
@(private)
starts_block :: proc(line: string) -> bool {
	if _, _, ok := atx_heading(line); ok {
		return true
	}
	if _, ok := fence_open(line); ok {
		return true
	}
	if is_quote(line) || is_rule(line) {
		return true
	}
	// Only a bullet or "1." with content interrupts a paragraph.
	if m, ok := list_marker(line); ok {
		return !m.empty && (!m.ordered || m.start == 1)
	}
	return false
}

// Table row cells: outer pipes dropped, split at unescaped '|', `\|` → '|'.
@(private)
split_row :: proc(line: string) -> []string {
	s := strings.trim_space(line)
	if strings.has_prefix(s, "|") {
		s = s[1:]
	}
	if strings.has_suffix(s, "|") && !strings.has_suffix(s, "\\|") {
		s = s[:len(s) - 1]
	}
	cells: [dynamic]string
	start := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' {
			i += 1
		} else if s[i] == '|' {
			append(&cells, cell_text(s[start:i]))
			start = i + 1
		}
	}
	append(&cells, cell_text(s[start:]))
	return cells[:]
}

@(private)
cell_text :: proc(s: string) -> string {
	out, _ := strings.replace_all(strings.trim_space(s), "\\|", "|")
	return out
}

@(private)
delimiter_row :: proc(line: string) -> (align: []Align, ok: bool) {
	if !strings.contains_rune(line, '-') {
		return
	}
	cells := split_row(line)
	al := make([]Align, len(cells))
	for c, i in cells {
		left, right := strings.has_prefix(c, ":"), strings.has_suffix(c, ":")
		dashes := strings.trim(c, ":")
		if len(dashes) == 0 || strings.trim_left(dashes, "-") != "" {
			return
		}
		switch {
		case left && right:
			al[i] = .Center
		case left:
			al[i] = .Left
		case right:
			al[i] = .Right
		}
	}
	return al, true
}

@(private)
parse_blocks :: proc(lines: []string) -> [dynamic]^Block {
	blocks: [dynamic]^Block
	blank := false
	i := 0
	for i < len(lines) {
		line := lines[i]
		if is_blank(line) {
			blank = true
			i += 1
			continue
		}
		b := new(Block)
		b.blank_before = blank && len(blocks) > 0
		blank = false
		append(&blocks, b)

		if indent_of(line) >= 4 {
			// Indented code: runs to the last line indented 4+ before a dedent.
			last, j := i, i
			for j < len(lines) && (is_blank(lines[j]) || indent_of(lines[j]) >= 4) {
				if !is_blank(lines[j]) {
					last = j
				}
				j += 1
			}
			body := strings.builder_make()
			for k in i ..= last {
				if k > i {
					strings.write_byte(&body, '\n')
				}
				strings.write_string(&body, strip_indent(lines[k], 4))
			}
			b.kind, b.text = .Code, strings.to_string(body)
			i = last + 1
			continue
		}
		if level, text, ok := atx_heading(line); ok {
			b.kind, b.level, b.text = .Heading, level, text
			i += 1
			continue
		}
		if f, ok := fence_open(line); ok {
			b.kind = .Code
			if sp := strings.index_any(f.info, " \t"); sp != -1 {
				b.lang = f.info[:sp]
			} else {
				b.lang = f.info
			}
			body := strings.builder_make()
			j := i + 1
			for ; j < len(lines) && !fence_closes(lines[j], f); j += 1 {
				if j > i + 1 {
					strings.write_byte(&body, '\n')
				}
				strings.write_string(&body, strip_indent(lines[j], f.indent))
			}
			b.text = strings.to_string(body)
			i = j + 1
			continue
		}
		if is_rule(line) {
			b.kind = .Rule
			i += 1
			continue
		}
		if is_quote(line) {
			b.kind = .Quote
			inner: [dynamic]string
			for i < len(lines) {
				l := lines[i]
				if is_quote(l) {
					s := l[indent_of(l) + 1:]
					append(&inner, s[1:] if strings.has_prefix(s, " ") else s)
				} else if !is_blank(l) &&
				   len(inner) > 0 &&
				   !is_blank(inner[len(inner) - 1]) &&
				   !starts_block(l) {
					append(&inner, l) // lazy continuation
				} else {
					break
				}
				i += 1
			}
			b.children = parse_blocks(inner[:])
			continue
		}
		if first, ok := list_marker(line); ok {
			i = parse_list(b, lines, i, first)
			continue
		}
		if strings.contains_rune(line, '|') && i + 1 < len(lines) {
			header := split_row(line)
			if align, ok := delimiter_row(lines[i + 1]); ok && len(align) == len(header) {
				b.kind, b.align = .Table, align
				append(&b.rows, header)
				i += 2
				for i < len(lines) && !is_blank(lines[i]) && !starts_block(lines[i]) {
					cells := split_row(lines[i])
					row := make([]string, len(header))
					copy(row, cells)
					append(&b.rows, row)
					i += 1
				}
				continue
			}
		}

		b.kind = .Paragraph
		text := strings.builder_make()
		strings.write_string(&text, strings.trim_left_space(line))
		i += 1
		for i < len(lines) && !is_blank(lines[i]) && !starts_block(lines[i]) {
			strings.write_byte(&text, '\n')
			strings.write_string(&text, strings.trim_left_space(lines[i]))
			i += 1
		}
		b.text = strings.trim_right_space(strings.to_string(text))
	}
	return blocks
}

// Parse the list starting at lines[i] into b; returns the next line index.
@(private)
parse_list :: proc(b: ^Block, lines: []string, start: int, first: Marker) -> int {
	b.kind, b.ordered, b.start = .List, first.ordered, first.start
	i := start
	for {
		m, _ := list_marker(lines[i])
		item := new(Block)
		item.kind = .Item
		append(&b.children, item)

		body: [dynamic]string
		append(&body, "" if m.empty else lines[i][m.content:])
		fence: Fence
		in_fence := false
		track := proc(l: string, fence: ^Fence, in_fence: ^bool) {
			if in_fence^ {
				in_fence^ = !fence_closes(l, fence^)
			} else if f, ok := fence_open(l); ok {
				fence^, in_fence^ = f, true
			}
		}
		track(body[0], &fence, &in_fence)
		j := i + 1
		for j < len(lines) {
			l := lines[j]
			if is_blank(l) {
				append(&body, "")
			} else if indent_of(l) >= m.content {
				append(&body, l[m.content:])
				track(l[m.content:], &fence, &in_fence)
			} else if !in_fence &&
			   !is_blank(body[len(body) - 1]) &&
			   !starts_block(l) &&
			   !is_fence_line(body[len(body) - 1]) {
				if _, is_marker := list_marker(l); is_marker {
					break
				}
				append(&body, strings.trim_left_space(l)) // lazy continuation
			} else {
				break
			}
			j += 1
		}
		// Trailing blank lines separate this item from what follows.
		keep := len(body)
		for keep > 1 && body[keep - 1] == "" {
			keep -= 1
		}
		trailing := len(body) - keep
		item.children = parse_blocks(body[:keep])
		for c, k in item.children {
			if k > 0 && c.blank_before {
				b.loose = true
			}
		}

		if j < len(lines) {
			if next, ok := list_marker(lines[j]);
			   ok && next.ordered == first.ordered && next.char == first.char {
				if trailing > 0 {
					b.loose = true
				}
				i = j
				continue
			}
		}
		return j - trailing
	}
}

@(private)
is_fence_line :: proc(l: string) -> bool {
	_, ok := fence_open(l)
	return ok
}

// ---------------------------------------------------------------------------
// HTML
// ---------------------------------------------------------------------------

@(private)
Renderer :: struct {
	out:      strings.Builder,
	opts:     Options,
	seen:     map[string]int,
	headings: [dynamic]Heading,
	title:    string,
}

@(private)
COPY_SVG :: `<svg class="cp" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" aria-hidden="true"><rect x="8.5" y="8.5" width="11" height="11" rx="2.2"/><path d="M15.5 8.5V6.7a2.2 2.2 0 0 0-2.2-2.2H6.7a2.2 2.2 0 0 0-2.2 2.2v6.6a2.2 2.2 0 0 0 2.2 2.2h1.8"/></svg><svg class="ok" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg>`

@(private)
render_blocks :: proc(r: ^Renderer, blocks: []^Block, tight: bool) {
	w := &r.out
	for b in blocks {
		switch b.kind {
		case .Paragraph:
			if tight {
				inline(r, b.text, w, nil)
				strings.write_byte(w, '\n')
			} else {
				render_paragraph(r, b.text)
			}
		case .Heading:
			render_heading(r, b.level, b.text)
		case .Code:
			strings.write_string(w, `<div class="code"><pre><code`)
			if b.lang != "" {
				strings.write_string(w, ` class="language-`)
				escape(w, b.lang)
				strings.write_string(w, `"`)
			}
			strings.write_byte(w, '>')
			escape(w, b.text)
			strings.write_string(w, "\n</code></pre>")
			strings.write_string(
				w,
				`<button type="button" class="icon-btn copy-btn" aria-label="Copy `,
			)
			if b.lang != "" {
				escape(w, b.lang)
				strings.write_byte(w, ' ')
			}
			strings.write_string(w, `code">`)
			strings.write_string(w, COPY_SVG)
			strings.write_string(w, "</button></div>\n")
		case .Quote:
			strings.write_string(w, "<blockquote>\n")
			render_blocks(r, b.children[:], false)
			strings.write_string(w, "</blockquote>\n")
		case .List:
			tag := "ol" if b.ordered else "ul"
			strings.write_byte(w, '<')
			strings.write_string(w, tag)
			if b.ordered && b.start != 1 {
				strings.write_string(w, ` start="`)
				strings.write_int(w, b.start)
				strings.write_byte(w, '"')
			}
			strings.write_string(w, ">\n")
			for item in b.children {
				strings.write_string(w, "<li>")
				render_blocks(r, item.children[:], !b.loose)
				strings.write_string(w, "</li>\n")
			}
			strings.write_string(w, "</")
			strings.write_string(w, tag)
			strings.write_string(w, ">\n")
		case .Item:
			render_blocks(r, b.children[:], tight)
		case .Table:
			render_table(r, b)
		case .Rule:
			strings.write_string(w, "<hr>\n")
		}
	}
}

@(private)
render_table :: proc(r: ^Renderer, b: ^Block) {
	w := &r.out
	strings.write_string(w, "<div class=\"table-wrap\"><table>\n<thead>\n")
	for row, ri in b.rows {
		if ri == 1 {
			strings.write_string(w, "<tbody>\n")
		}
		tag := "th" if ri == 0 else "td"
		strings.write_string(w, "<tr>\n")
		for cell, ci in row {
			strings.write_byte(w, '<')
			strings.write_string(w, tag)
			switch b.align[ci] {
			case .None:
			case .Left:
				strings.write_string(w, ` align="left"`)
			case .Center:
				strings.write_string(w, ` align="center"`)
			case .Right:
				strings.write_string(w, ` align="right"`)
			}
			strings.write_byte(w, '>')
			inline(r, cell, w, nil)
			strings.write_string(w, "</")
			strings.write_string(w, tag)
			strings.write_string(w, ">\n")
		}
		strings.write_string(w, "</tr>\n")
		if ri == 0 {
			strings.write_string(w, "</thead>\n")
		}
	}
	if len(b.rows) > 1 {
		strings.write_string(w, "</tbody>\n")
	}
	strings.write_string(w, "</table></div>\n")
}

@(private)
ANCHOR_OPEN :: `<a class="anchor" href="#`
@(private)
ANCHOR_CLOSE :: `" aria-label="Link to this section">#</a>`

@(private)
render_heading :: proc(r: ^Renderer, level: int, src: string) {
	w := &r.out
	tags := [7]string{"", "h1", "h2", "h3", "h4", "h5", "h6"}
	tag := tags[level]
	html, text := strings.builder_make(), strings.builder_make()
	inline(r, src, &html, &text)
	strings.write_byte(w, '<')
	strings.write_string(w, tag)
	if level <= 4 {
		plain := collapse_space(strings.to_string(text))
		id := next_slug(r, plain)
		append(&r.headings, Heading{level = level, id = id, text = plain})
		if level == 1 && r.title == "" {
			r.title = plain
		}
		strings.write_string(w, ` id="`)
		escape(w, id)
		strings.write_byte(w, '"')
		strings.write_byte(w, '>')
		strings.write_string(w, strings.to_string(html))
		if level > 1 {
			write_anchor(w, id)
		}
	} else {
		strings.write_byte(w, '>')
		strings.write_string(w, strings.to_string(html))
	}
	strings.write_string(w, "</")
	strings.write_string(w, tag)
	strings.write_string(w, ">\n")
}

// A paragraph that is only bold text is a sub-heading (UPGRADING.md uses
// them): it gets an id and an anchor like a heading.
@(private)
render_paragraph :: proc(r: ^Renderer, src: string) {
	w := &r.out
	if inner, ok := bold_only(src); ok {
		html, text := strings.builder_make(), strings.builder_make()
		inline(r, inner, &html, &text)
		plain := collapse_space(strings.to_string(text))
		id := next_slug(r, plain)
		append(&r.headings, Heading{level = 0, id = id, text = plain})
		strings.write_string(w, `<p class="pseudo-h" id="`)
		escape(w, id)
		strings.write_string(w, `"><strong>`)
		strings.write_string(w, strings.to_string(html))
		write_anchor(w, id)
		strings.write_string(w, "</strong></p>\n")
		return
	}
	strings.write_string(w, "<p>")
	inline(r, src, w, nil)
	strings.write_string(w, "</p>\n")
}

@(private)
bold_only :: proc(src: string) -> (inner: string, ok: bool) {
	for d in ([2]string{"**", "__"}) {
		if len(src) > 4 && strings.has_prefix(src, d) && strings.has_suffix(src, d) {
			inner = src[2:len(src) - 2]
			if !strings.contains(inner, d) &&
			   !unicode.is_space(rune(inner[0])) &&
			   !unicode.is_space(rune(inner[len(inner) - 1])) {
				return inner, true
			}
		}
	}
	return
}

@(private)
write_anchor :: proc(w: ^strings.Builder, id: string) {
	strings.write_string(w, ANCHOR_OPEN)
	escape(w, id)
	strings.write_string(w, ANCHOR_CLOSE)
}

@(private)
next_slug :: proc(r: ^Renderer, text: string) -> string {
	base := slug_base(text)
	n := r.seen[base]
	r.seen[base] = n + 1
	if n == 0 {
		return base
	}
	b := strings.builder_make()
	strings.write_string(&b, base)
	strings.write_byte(&b, '-')
	strings.write_int(&b, n)
	return strings.to_string(b)
}

@(private)
collapse_space :: proc(s: string) -> string {
	b := strings.builder_make()
	space := false
	for r in strings.trim_space(s) {
		if unicode.is_space(r) {
			space = true
			continue
		}
		if space {
			strings.write_byte(&b, ' ')
			space = false
		}
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}

@(private)
is_mark :: proc(r: rune) -> bool {
	return(
		unicode.is_nonspacing_mark(r) ||
		unicode.is_spacing_mark(r) ||
		unicode.is_enclosing_mark(r) \
	)
}

// HTML-escape s into w (text and attribute values).
escape :: proc(w: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		escape_byte(w, s[i])
	}
}

@(private)
escape_byte :: proc(w: ^strings.Builder, c: byte) {
	switch c {
	case '&':
		strings.write_string(w, "&amp;")
	case '<':
		strings.write_string(w, "&lt;")
	case '>':
		strings.write_string(w, "&gt;")
	case '"':
		strings.write_string(w, "&quot;")
	case '\'':
		strings.write_string(w, "&#39;")
	case:
		strings.write_byte(w, c)
	}
}

// ---------------------------------------------------------------------------
// Inline
// ---------------------------------------------------------------------------

@(private)
is_ascii_punct :: proc(c: byte) -> bool {
	switch c {
	case '!' ..= '/', ':' ..= '@', '[' ..= '`', '{' ..= '~':
		return true
	}
	return false
}

@(private)
rune_before :: proc(s: string, i: int) -> rune {
	if i <= 0 {
		return ' '
	}
	r, _ := utf8.decode_last_rune_in_string(s[:i])
	return r
}

@(private)
rune_at :: proc(s: string, i: int) -> rune {
	if i >= len(s) {
		return ' '
	}
	r, _ := utf8.decode_rune_in_string(s[i:])
	return r
}

@(private)
is_punct_rune :: proc(r: rune) -> bool {
	return r < 0x80 ? is_ascii_punct(byte(r)) : unicode.is_punct(r) || unicode.is_symbol(r)
}

// Delimiter run flanking (CommonMark): can the run s[i:j] open / close?
@(private)
flanking :: proc(s: string, i, j: int) -> (left, right: bool) {
	before, after := rune_before(s, i), rune_at(s, j)
	left =
		!unicode.is_space(after) &&
		(!is_punct_rune(after) || unicode.is_space(before) || is_punct_rune(before))
	right =
		!unicode.is_space(before) &&
		(!is_punct_rune(before) || unicode.is_space(after) || is_punct_rune(after))
	if s[i] == '_' {
		l, r := left, right
		left = l && (!r || is_punct_rune(before))
		right = r && (!l || is_punct_rune(after))
	}
	return
}

// End of the code span opening at s[i] (a backtick run), or -1.
@(private)
code_span_end :: proc(s: string, i: int) -> (content_end, end: int) {
	n := 0
	for i + n < len(s) && s[i + n] == '`' {
		n += 1
	}
	j := i + n
	for j < len(s) {
		if s[j] != '`' {
			j += 1
			continue
		}
		k := j
		for k < len(s) && s[k] == '`' {
			k += 1
		}
		if k - j == n {
			return j, k
		}
		j = k
	}
	return -1, -1
}

// Matching ']' for the '[' at s[i], skipping code spans and escapes.
@(private)
bracket_end :: proc(s: string, i: int) -> int {
	depth := 0
	for j := i; j < len(s); j += 1 {
		switch s[j] {
		case '\\':
			j += 1
		case '`':
			if _, end := code_span_end(s, j); end != -1 {
				j = end - 1
			} else {
				for j + 1 < len(s) && s[j + 1] == '`' {
					j += 1
				}
			}
		case '[':
			depth += 1
		case ']':
			depth -= 1
			if depth == 0 {
				return j
			}
		}
	}
	return -1
}

// "(dest "title")" at s[i]; returns the index after ')'.
@(private)
link_target :: proc(s: string, i: int) -> (dest, title: string, end: int, ok: bool) {
	if i >= len(s) || s[i] != '(' {
		return
	}
	j := i + 1
	for j < len(s) && (s[j] == ' ' || s[j] == '\n') {
		j += 1
	}
	if j < len(s) && s[j] == '<' {
		k := strings.index_byte(s[j:], '>')
		if k == -1 {
			return
		}
		dest = s[j + 1:j + k]
		j += k + 1
	} else {
		start, depth := j, 0
		for j < len(s) && s[j] != ' ' && s[j] != '\n' {
			if s[j] == '\\' {
				j += 2
				continue
			}
			if s[j] == '(' {
				depth += 1
			} else if s[j] == ')' {
				if depth == 0 {
					break
				}
				depth -= 1
			}
			j += 1
		}
		dest = s[start:min(j, len(s))]
	}
	for j < len(s) && (s[j] == ' ' || s[j] == '\n') {
		j += 1
	}
	if j < len(s) && (s[j] == '"' || s[j] == '\'') {
		q := s[j]
		k := strings.index_byte(s[j + 1:], q)
		if k == -1 {
			return
		}
		title = s[j + 1:j + 1 + k]
		j += k + 2
		for j < len(s) && (s[j] == ' ' || s[j] == '\n') {
			j += 1
		}
	}
	if j >= len(s) || s[j] != ')' {
		return
	}
	return dest, title, j + 1, true
}

// Unescape backslash escapes in a link destination or title.
@(private)
unescape :: proc(s: string) -> string {
	if !strings.contains_rune(s, '\\') {
		return s
	}
	b := strings.builder_make()
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) && is_ascii_punct(s[i + 1]) {
			i += 1
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

@(private)
is_external :: proc(href: string) -> bool {
	lower := strings.to_lower(href, context.temp_allocator)
	return(
		strings.has_prefix(lower, "http:") ||
		strings.has_prefix(lower, "https:") ||
		strings.has_prefix(lower, "mailto:") \
	)
}

@(private)
write_link_open :: proc(r: ^Renderer, w: ^strings.Builder, raw_href, title: string) {
	href := unescape(raw_href)
	external := is_external(href)
	if !external && !strings.has_prefix(href, "#") && r.opts.rewrite_link != nil {
		href = r.opts.rewrite_link(href, r.opts.data)
	}
	strings.write_string(w, `<a href="`)
	escape(w, href)
	strings.write_byte(w, '"')
	if title != "" {
		strings.write_string(w, ` title="`)
		escape(w, unescape(title))
		strings.write_byte(w, '"')
	}
	if external {
		strings.write_string(w, ` rel="noopener"`)
	}
	strings.write_byte(w, '>')
}

// GFM autolink literal at s[i] ("https://…", "http://…", "www.…"); length or 0.
@(private)
autolink_len :: proc(s: string, i: int) -> int {
	rest := s[i:]
	scheme := 0
	switch {
	case strings.has_prefix(rest, "https://"):
		scheme = 8
	case strings.has_prefix(rest, "http://"):
		scheme = 7
	case strings.has_prefix(rest, "www."):
		scheme = 4
	case:
		return 0
	}
	prev := rune_before(s, i)
	if !(unicode.is_space(prev) || strings.contains_rune("*_~(", prev)) {
		return 0
	}
	n := scheme
	domain := n
	for n < len(rest) {
		c := rest[n]
		if (c >= 'a' && c <= 'z') ||
		   (c >= 'A' && c <= 'Z') ||
		   (c >= '0' && c <= '9') ||
		   c == '-' ||
		   c == '_' ||
		   c == '.' {
			n += 1
		} else {
			break
		}
	}
	if n == domain || !strings.contains_rune(rest[domain:n], '.') && scheme == 4 {
		return 0
	}
	for n < len(rest) && rest[n] != ' ' && rest[n] != '\n' && rest[n] != '<' {
		n += 1
	}
	// Trailing punctuation and an unbalanced ')' are not part of the link.
	for n > domain {
		c := rest[n - 1]
		if strings.contains_rune("?!.,:*_~'\"", rune(c)) {
			n -= 1
		} else if c == ')' && strings.count(rest[:n], "(") < strings.count(rest[:n], ")") {
			n -= 1
		} else {
			break
		}
	}
	return n
}

// Render inline Markdown s as HTML into w and, when text != nil, its plain
// text (what the browser's textContent would be) into text.
@(private)
inline :: proc(
	r: ^Renderer,
	s: string,
	w: ^strings.Builder,
	text: ^strings.Builder,
	in_link := false,
) {
	put_text :: proc(text: ^strings.Builder, s: string) {
		if text != nil {
			strings.write_string(text, s)
		}
	}
	i := 0
	for i < len(s) {
		c := s[i]
		switch c {
		case '\\':
			if i + 1 < len(s) && is_ascii_punct(s[i + 1]) {
				escape_byte(w, s[i + 1])
				put_text(text, s[i + 1:i + 2])
				i += 2
				continue
			}
			if i + 1 < len(s) && s[i + 1] == '\n' {
				strings.write_string(w, "<br>\n")
				put_text(text, "\n")
				i += 2
				continue
			}
		case '`':
			content_end, end := code_span_end(s, i)
			if end == -1 {
				for i < len(s) && s[i] == '`' {
					strings.write_byte(w, '`')
					put_text(text, "`")
					i += 1
				}
				continue
			}
			open := end - content_end
			code, _ := strings.replace_all(s[i + open:content_end], "\n", " ")
			if len(code) >= 2 &&
			   code[0] == ' ' &&
			   code[len(code) - 1] == ' ' &&
			   strings.trim_space(code) != "" {
				code = code[1:len(code) - 1]
			}
			if utf8.rune_count_in_string(code) <= NOWRAP_CODE_MAX {
				strings.write_string(w, `<code class="nw">`)
			} else {
				strings.write_string(w, "<code>")
			}
			escape(w, code)
			strings.write_string(w, "</code>")
			put_text(text, code)
			i = end
			continue
		case '[':
			if in_link {
				break
			}
			close := bracket_end(s, i)
			if close == -1 {
				break
			}
			dest, title, end, ok := link_target(s, close + 1)
			if !ok {
				break
			}
			write_link_open(r, w, dest, title)
			inline(r, s[i + 1:close], w, text, true)
			strings.write_string(w, "</a>")
			i = end
			continue
		case '<':
			// Autolink: <https://…> or <mailto:…>.
			if k := strings.index_byte(s[i:], '>'); k > 1 {
				target := s[i + 1:i + k]
				if is_external(target) && !strings.contains_any(target, " \n<") {
					write_link_open(r, w, target, "")
					escape(w, target)
					strings.write_string(w, "</a>")
					put_text(text, target)
					i += k + 1
					continue
				}
			}
		case '*', '_':
			if end, ok := emphasis(r, s, i, w, text, in_link); ok {
				i = end
				continue
			}
			for j := i; j < len(s) && s[j] == c; j += 1 {
				strings.write_byte(w, c)
				put_text(text, s[j:j + 1])
				i += 1
			}
			continue
		case ' ':
			j := i
			for j < len(s) && s[j] == ' ' {
				j += 1
			}
			if j < len(s) && s[j] == '\n' {
				if j - i >= 2 {
					strings.write_string(w, "<br>")
				}
				i = j
				continue
			}
		case 'h', 'w':
			if !in_link {
				if n := autolink_len(s, i); n > 0 {
					url := s[i:i + n]
					href := url
					if c == 'w' {
						href = strings.concatenate({"http://", url})
					}
					write_link_open(r, w, href, "")
					escape(w, url)
					strings.write_string(w, "</a>")
					put_text(text, url)
					i += n
					continue
				}
			}
		}
		escape_byte(w, c)
		if text != nil {
			strings.write_byte(text, c)
		}
		i += 1
	}
}

// Emphasis opening at s[i]: <strong> for a run of 2+, <em> for 1.
@(private)
emphasis :: proc(
	r: ^Renderer,
	s: string,
	i: int,
	w: ^strings.Builder,
	text: ^strings.Builder,
	in_link: bool,
) -> (
	end: int,
	ok: bool,
) {
	c := s[i]
	run := 0
	for i + run < len(s) && s[i + run] == c {
		run += 1
	}
	if left, _ := flanking(s, i, i + run); !left {
		return
	}
	want := 2 if run >= 2 else 1
	// Find a closing run that can close and has the same length class.
	j := i + run
	for j < len(s) {
		switch s[j] {
		case '\\':
			j += 2
			continue
		case '`':
			if _, e := code_span_end(s, j); e != -1 {
				j = e
				continue
			}
		case c:
			k := j
			for k < len(s) && s[k] == c {
				k += 1
			}
			_, right := flanking(s, j, k)
			if right && (k - j == want || (want == 2 && k - j > 2)) {
				open := i + run - want // extra opener chars stay literal
				for p in i ..< open {
					escape_byte(w, s[p])
					if text != nil {
						strings.write_byte(text, s[p])
					}
				}
				tag := "strong" if want == 2 else "em"
				strings.write_byte(w, '<')
				strings.write_string(w, tag)
				strings.write_byte(w, '>')
				inline(r, s[i + run:j], w, text, in_link)
				strings.write_string(w, "</")
				strings.write_string(w, tag)
				strings.write_byte(w, '>')
				return j + want, true
			}
			j = k
			continue
		}
		j += 1
	}
	return
}
