// test_toml_parser.odin - the single TOML parser (OKAMI-240): value forms,
// rejection of invalid TOML, error recovery, and the write path of init.<ext>.

package test_wayu

import wayu "../../src"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

KV :: struct {
	key, value: string,
}

// Run the readers that use the startup cache against `content` without
// touching disk.
@(private = "file")
use_cached_toml :: proc(content: string) {
	wayu.clear_toml_content_cache()
	wayu.TOML_CONTENT_CACHE.content = content
	wayu.TOML_CONTENT_CACHE.loaded = true
	wayu.TOML_CONTENT_CACHE.owned = false
}

// Scalar `key = value` statements of table [name], in file order, as text
// (recovered lines included). Arrays and inline tables are skipped.
@(private = "file")
section :: proc(content, name: string) -> []KV {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	doc, _ := wayu.toml_doc_parse_alloc(content, virtual.arena_allocator(&arena))
	out := make([dynamic]KV, context.temp_allocator)
	for e in doc.entries {
		if e.header < 0 || len(e.key) != 1 {
			continue
		}
		h := doc.headers[e.header]
		if h.invalid || h.array || len(h.path) != 1 || h.path[0] != name {
			continue
		}
		text: string
		#partial switch e.value.type {
		case .ARRAY, .TABLE:
			continue
		case .BOOLEAN:
			text = e.value.bool_val ? "true" : "false"
		case:
			text = e.value.str_val
		}
		append(
			&out,
			KV {
				strings.clone(e.key[0], context.temp_allocator),
				strings.clone(text, context.temp_allocator),
			},
		)
	}
	return out[:]
}

@(private = "file")
kvs_equal :: proc(t: ^testing.T, got, want: []KV, what: string, loc := #caller_location) -> bool {
	ok := len(got) == len(want)
	if ok {
		for g, i in got {
			if g.key != want[i].key || g.value != want[i].value {
				ok = false; break
			}
		}
	}
	if !ok {
		testing.expectf(t, false, "%s:\n got  %v\n want %v", what, got, want, loc = loc)
	}
	return ok
}

@(private = "file")
first_error :: proc(content: string) -> (line: int, msg: string, valid: bool) {
	ok, e := wayu.toml_check(content)
	defer delete(e.msg)
	return e.line, strings.clone(e.msg, context.temp_allocator), ok
}

// ---------------------------------------------------------------------------
// Conformance: values and structure
// ---------------------------------------------------------------------------

@(test)
test_toml_parser_value_forms :: proc(t: ^testing.T) {
	// Starts with a BOM and a CRLF line ending.
	content :=
		"\xEF\xBB\xBF[t]\r\n" +
		"I = 1_000\n" +
		"H = 0x1F\n" +
		"P = +5\n" +
		"B = true\n" +
		"F = 3.14\n" +
		"E = 1e3\n" +
		"D = 1979-05-27T07:32:00Z\n" +
		"DS = 1979-05-27 07:32:00\n" +
		"ML = \"\"\"\nline1\nline2 \\\n    joined\"\"\"\n" +
		"MQ = \"\"\"a\"\"\"\"\n" +
		"LIT = '''\nC:\\no\\escape'''\n" +
		"ESC = \"\\e[1m \\u00e9 \\U0001F600 \\x41 tab\\tq\\\"\"\n" +
		"EMPTY = \"\"\n" +
		"\"quoted key\" = 'v' # comment\n" +
		"ARR = [\n  \"a\", # first\n  \"b\",\n]\n" +
		"TBL = { x = 1, y = \"z\" }\n"
	line, msg, valid := first_error(content)
	testing.expectf(t, valid, "valid TOML rejected: line %d: %s", line, msg)

	want := []KV {
		{"I", "1000"},
		{"H", "31"},
		{"P", "5"},
		{"B", "true"},
		{"F", "3.14"},
		{"E", "1e3"},
		{"D", "1979-05-27T07:32:00Z"},
		{"DS", "1979-05-27 07:32:00"},
		{"ML", "line1\nline2 joined"},
		{"MQ", "a\""},
		{"LIT", `C:\no\escape`},
		{"ESC", "\x1b[1m é 😀 A tab\tq\""},
		{"EMPTY", ""},
		{"quoted key", "v"},
	}
	kvs_equal(t, section(content, "t"), want, "value forms")
}

@(test)
test_toml_parser_rejects_invalid :: proc(t: ^testing.T) {
	Case :: struct {
		src:  string,
		line: int,
	}
	cases := []Case {
		{"x = 01", 1},
		{"x = 1__0", 1},
		{"x = \"\\q\"", 1},
		{"x = \"\\uD800\"", 1},
		{"[a]\nk = 1\n[a]", 3},
		{"a = 1\na = 2", 2},
		{"x = {a = 1}\n[x]", 2},
		{"a.b = 1\n[a]", 2},
		{"[[a]]\n[a]", 2},
		{"x = \"\"\"\nnever closed\n", 3},
		{"[t]\nll = ls -la", 2},
		{"x = 'a' 'b'", 1},
		{"k = \"v\" junk", 1},
	}
	for c in cases {
		line, _, valid := first_error(c.src)
		testing.expectf(t, !valid, "invalid TOML accepted: %q", c.src)
		testing.expectf(t, line == c.line, "%q: error on line %d, want %d", c.src, line, c.line)
	}
}

// Valid TOML the old strict reader rejected (CFG-14).
@(test)
test_toml_parser_accepts_what_the_cli_used :: proc(t: ^testing.T) {
	content :=
		"\xEF\xBB\xBF[settings]\nautosuggestions_accept_keys = [\n  \"^Y\", # ctrl-y\n  \"^E\",\n]\n\n" +
		"[tools]\n\".\" = \"cd .\"\n"
	config, ok := wayu.toml_parse(content)
	defer wayu.cleanup_toml_config(&config)
	testing.expect(t, ok, "BOM, multi-line array and quoted keys are valid TOML")
	testing.expectf(
		t,
		slice.equal(config.settings.autosuggestions_accept_keys, []string{"^Y", "^E"}),
		"accept keys %v",
		config.settings.autosuggestions_accept_keys,
	)

	use_cached_toml(content)
	defer wayu.clear_toml_content_cache()
	keys := wayu.plugin_accept_keys_from_toml()
	defer {for k in keys {delete(k)}; delete(keys)}
	testing.expectf(
		t,
		slice.equal(keys, []string{"^Y", "^E"}),
		"plugin loader accept keys %v",
		keys,
	)
}

// ---------------------------------------------------------------------------
// Recovery: a bad statement is recorded and parsing resumes
// ---------------------------------------------------------------------------

// OKAMI-365: [tools] entries come back in wayu.toml file order (inline
// entries, [tools.<name>] sub-tables and dotted keys alike), not by name.
@(test)
test_toml_parser_tools_file_order :: proc(t: ^testing.T) {
	use_cached_toml(
		"[tools]\nzz.args = \"a\"\nmm = { args = \"b\" }\naa = { kind = \"nvm\" }\n" +
		"[tools.bb]\nargs = \"c\"\n[other]\nx = 1\n",
	)
	defer wayu.clear_toml_content_cache()
	tools := wayu.read_wayu_toml_tools()
	defer {
		for &tool in tools {wayu.destroy_tool_entry(&tool)}
		delete(tools)
	}
	names := make([dynamic]string, context.temp_allocator)
	for tool in tools {append(&names, tool.name)}
	testing.expectf(t, slice.equal(names[:], []string{"zz", "mm", "aa", "bb"}), "order %v", names)
}

// [settings] startup keys (OKAMI-372/375): defaults, booleans read, other
// types ignored.
@(test)
test_toml_parser_startup_settings :: proc(t: ^testing.T) {
	use_cached_toml("[shell]\ntype = \"zsh\"\n")
	s := wayu.read_startup_settings()
	testing.expect(t, s.compinit_guard && !s.defer_plugins && !s.lazy_compinit, "defaults")

	use_cached_toml(
		"[settings]\ncompinit_guard = false\ndefer_plugins = true # comment\nlazy_compinit = \"yes\"\n",
	)
	defer wayu.clear_toml_content_cache()
	s = wayu.read_startup_settings()
	testing.expect(t, !s.compinit_guard && s.defer_plugins && !s.lazy_compinit, "parsed")
}

// [settings] autosuggest / autosuggest_style (OKAMI-376): off and "fg=8" by
// default; a non-boolean / unusable style keeps the default.
@(test)
test_toml_parser_autosuggest_settings :: proc(t: ^testing.T) {
	defer wayu.clear_toml_content_cache()
	use_cached_toml("[shell]\ntype = \"zsh\"\n")
	s := wayu.read_startup_settings()
	testing.expect(t, !s.autosuggest, "off by default")
	testing.expect_value(t, s.autosuggest_style, "fg=8")

	use_cached_toml("[settings]\nautosuggest = true\nautosuggest_style = \"fg=244,underline\"\n")
	s = wayu.read_startup_settings()
	testing.expect(t, s.autosuggest, "parsed")
	testing.expect_value(t, s.autosuggest_style, "fg=244,underline")

	use_cached_toml("[settings]\nautosuggest = \"yes\"\nautosuggest_style = \"fg=1\\nbold\"\n")
	s = wayu.read_startup_settings()
	testing.expect(t, !s.autosuggest, "string is not a boolean")
	testing.expect_value(t, s.autosuggest_style, "fg=8")
}

// The generated module: style quoted in, every placeholder replaced, the
// accept keys bound in emacs + viins, only the accept/partial widgets wrapped.
@(test)
test_zsh_suggest_module :: proc(t: ^testing.T) {
	defer wayu.clear_toml_content_cache()
	use_cached_toml(
		"[settings]\nautosuggest = true\nautosuggestions_accept_keys = [\"^Y\", \"^[[121;5u\", \"ctrl-e\"]\n",
	)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	wayu.emit_zsh_suggest(&b, "fg=244,underline")
	code := strings.to_string(b)
	testing.expect(
		t,
		!strings.contains(code, "@STYLE@") && !strings.contains(code, "@BINDS@"),
		"placeholders replaced",
	)
	testing.expect(t, strings.contains(code, `_wayu_suggest_style="fg=244,underline"`), "style")
	testing.expect(
		t,
		strings.contains(
			code,
			"bindkey -M emacs '^Y' wayu-suggest-accept; bindkey -M viins '^Y' wayu-suggest-accept",
		),
		"^Y bound",
	)
	testing.expect(
		t,
		strings.contains(code, "bindkey -M emacs '^[[121;5u' wayu-suggest-accept"),
		"kitty ^Y bound",
	)
	testing.expect(
		t,
		!strings.contains(code, "ctrl-e"),
		"key names (not sequences) skipped, as in config.zsh",
	)
	testing.expect(
		t,
		strings.contains(code, "${history[(r)${(b)BUFFER}*]}"),
		"BUFFER is a literal prefix",
	)
	testing.expect(
		t,
		strings.contains(code, "add-zle-hook-widget zle-line-pre-redraw _wayu_suggest_redraw"),
		"redraw hook",
	)
	testing.expect(
		t,
		strings.contains(code, "add-zle-hook-widget zle-line-finish _wayu_suggest_finish"),
		"finish hook",
	)
	testing.expect_value(t, strings.count(code, "zle -N $w "), 1) // one loop over the 13 wrapped widgets
	testing.expect(
		t,
		strings.has_prefix(code, "if [[ -o interactive && -o zle ]]; then\n") &&
		strings.has_suffix(code, "fi\n"),
		"interactive zle only",
	)

	testing.expect(t, wayu.autosuggest_style_valid("fg=8"), "fg=8")
	for bad in ([]string{"", "fg=1\nbold", strings.repeat("x", 65, context.temp_allocator)}) {
		testing.expectf(t, !wayu.autosuggest_style_valid(bad), "%q must be invalid", bad)
	}
}

// [settings] highlight / highlight_styles (OKAMI-377): off and
// zsh-syntax-highlighting's styles by default; overrides from an inline
// table or [settings.highlight_styles]; "none" = no style; unknown names,
// non-strings and unusable specs keep the default.
@(test)
test_toml_parser_highlight_settings :: proc(t: ^testing.T) {
	defer wayu.clear_toml_content_cache()
	idx :: proc(name: string) -> int {return wayu.highlight_style_index(name)}
	use_cached_toml("[shell]\ntype = \"zsh\"\n")
	s := wayu.read_startup_settings()
	testing.expect(t, !s.highlight, "off by default")
	testing.expect_value(t, s.highlight_styles[idx("unknown-token")], "fg=red,bold")
	testing.expect_value(t, s.highlight_styles[idx("command")], "fg=green")
	testing.expect_value(t, s.highlight_styles[idx("single-hyphen-option")], "")
	testing.expect_value(t, idx("nosuch"), -1)

	use_cached_toml(
		"[settings]\nhighlight = true\nhighlight_styles = { command = \"fg=blue,bold\", comment = \"none\", nosuch = \"fg=1\", builtin = 3, alias = \"fg=1\\nx\" }\n",
	)
	s = wayu.read_startup_settings()
	testing.expect(t, s.highlight, "parsed")
	testing.expect_value(t, s.highlight_styles[idx("command")], "fg=blue,bold")
	testing.expect_value(t, s.highlight_styles[idx("comment")], "")
	testing.expect_value(t, s.highlight_styles[idx("builtin")], "fg=green")
	testing.expect_value(t, s.highlight_styles[idx("alias")], "fg=green")

	use_cached_toml(
		"[settings]\nhighlight = \"yes\"\n[settings.highlight_styles]\npath = \"fg=cyan,underline\"\n",
	)
	s = wayu.read_startup_settings()
	testing.expect(t, !s.highlight, "string is not a boolean")
	testing.expect_value(t, s.highlight_styles[idx("path")], "fg=cyan,underline")
}

// The generated module: every style quoted into the table, the placeholder
// gone, one redraw hook, nothing that forks ($(...) or backtick command
// substitution in the module's own code).
@(test)
test_zsh_highlight_module :: proc(t: ^testing.T) {
	defer wayu.clear_toml_content_cache()
	use_cached_toml(
		"[settings]\nhighlight = true\nhighlight_styles = { command = \"fg=blue\", comment = \"none\" }\n",
	)
	s := wayu.read_startup_settings()
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	wayu.emit_zsh_highlight(&b, s.highlight_styles)
	code := strings.to_string(b)
	testing.expect(t, !strings.contains(code, "@STYLES@"), "placeholder replaced")
	testing.expect(t, strings.contains(code, "      command 'fg=blue'\n"), "override")
	testing.expect(t, strings.contains(code, "      comment ''\n"), "none = empty")
	testing.expect(t, strings.contains(code, "      unknown-token 'fg=red,bold'\n"), "default")
	styles := wayu.HIGHLIGHT_STYLES
	for st in styles {
		testing.expectf(
			t,
			strings.contains(code, fmt.tprintf("\n      %s '", st.name)),
			"style %s in the table",
			st.name,
		)
		testing.expectf(
			t,
			strings.count(code, st.name) >= 2,
			"style %s used by the module",
			st.name,
		)
	}
	testing.expect_value(
		t,
		strings.count(code, "add-zle-hook-widget zle-line-pre-redraw _wayu_hl_redraw"),
		1,
	)
	testing.expect(t, strings.contains(code, "memo=wayu-highlight"), "entries tagged")
	testing.expect(
		t,
		strings.has_prefix(code, "if [[ -o interactive && -o zle ]]; then\n") &&
		strings.has_suffix(code, "fi\n"),
		"interactive zle only",
	)
	// No command substitution (a fork) in the module's own code: outside
	// comments every "$(" is arithmetic "$((".
	for line in strings.split_lines(code, context.temp_allocator) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "#") {
			continue
		}
		testing.expectf(
			t,
			strings.count(trimmed, "$(") == strings.count(trimmed, "$(("),
			"no command substitution: %q",
			trimmed,
		)
	}
}

@(test)
test_toml_parser_recovers_invalid_lines :: proc(t: ^testing.T) {
	content := "[a]\nll = ls -la\nok = \"fine\"\n[b\nHIDDEN = \"x\"\n[b]\nA = \"1\" trailing\nB = \"2\"\n"
	line, _, valid := first_error(content)
	testing.expect(t, !valid)
	testing.expect_value(t, line, 2)
	kvs_equal(t, section(content, "a"), {{"ll", "ls -la"}, {"ok", "fine"}}, "recovered [a]")
	kvs_equal(
		t,
		section(content, "b"),
		{{"A", `"1" trailing`}, {"B", "2"}},
		"recovered [b] (bad header hides HIDDEN)",
	)

	_, ok := wayu.toml_parse(content)
	testing.expect(t, !ok, "toml_parse stays strict")
}

// A `[header]` line inside a multi-line string is data, not a table.
@(test)
test_toml_parser_ignores_headers_inside_strings :: proc(t: ^testing.T) {
	content := "[a]\nX = \"\"\"\n[b]\nFAKE = 1\"\"\"\n\n[b]\nA = \"1\"\n"
	kvs_equal(t, section(content, "b"), {{"A", "1"}}, "[b] inside a string is not a table")
}

// ---------------------------------------------------------------------------
// OKAMI-247: write-path properties
// ---------------------------------------------------------------------------

// sync_init_orchestrator rewrites init.<ext> through write_init_file ->
// write_file_atomic (temp + rename). With a stow-style symlinked init.zsh
// the TARGET must be replaced and the link kept.
@(test)
test_write_init_file_keeps_symlinked_init :: proc(t: ^testing.T) {
	dir := test_tmp("init-symlink")
	os.remove_all(dir)
	defer os.remove_all(dir)
	data := fmt.tprintf("%s/data", dir)
	dotfiles := fmt.tprintf("%s/dotfiles", dir)
	testing.expect_value(t, os.make_directory_all(data), nil)
	testing.expect_value(t, os.make_directory_all(dotfiles), nil)

	real := fmt.tprintf("%s/init.zsh", dotfiles)
	link := fmt.tprintf("%s/init.zsh", data)
	testing.expect_value(
		t,
		os.write_entire_file(real, transmute([]byte)string("# Wayu Shell Initialization\nold\n")),
		nil,
	)
	testing.expect_value(t, os.symlink(real, link), nil)

	template := wayu.get_init_template(.ZSH)
	wayu.write_init_file(link, template)

	lfi, lerr := os.lstat(link, context.temp_allocator)
	testing.expect_value(t, lerr, nil)
	testing.expect_value(t, lfi.type, os.File_Type.Symlink)
	got, _ := os.read_entire_file(real, context.temp_allocator)
	testing.expect_value(t, string(got), template)
}

// The parse of a large file stays fast.
@(test)
test_toml_parser_large_file_fast :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[t]\n")
	for i in 0 ..< 6000 {fmt.sbprintfln(&b, "a_%d = \"echo %d --flag 'x' # not a comment\" # c", i, i)}
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	doc, ok := wayu.toml_doc_parse_alloc(strings.to_string(b), virtual.arena_allocator(&arena))
	testing.expect(t, ok)
	testing.expect_value(t, len(doc.entries), 6000)
}

// Deep nesting is a parse error, not a stack overflow.
@(test)
test_toml_parser_nesting_cap :: proc(t: ^testing.T) {
	deep := proc(open, close: string, n: int) -> string {
		return strings.concatenate(
			{
				"x = ",
				strings.repeat(open, n, context.temp_allocator),
				strings.repeat(close, n, context.temp_allocator),
				"\n[t]\nok = 1\n",
			},
			context.temp_allocator,
		)
	}
	for src in ([]string{deep("[", "]", 20000), deep("{a=", "}", 20000)}) {
		line, msg, valid := first_error(src)
		testing.expect(t, !valid, "deep nesting rejected")
		testing.expect_value(t, line, 1)
		testing.expectf(t, strings.contains(msg, "nested"), "message: %s", msg)
	}
	_, msg, valid := first_error(deep("[", "]", 100))
	testing.expectf(t, valid, "100 levels accepted: %s", msg)
	free_all(context.temp_allocator)
}

// Error recovery stays linear: 10k bad lines parse in well under a second.
@(test)
test_toml_parser_many_bad_lines_fast :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[t]\n")
	for i in 0 ..< 10000 {fmt.sbprintfln(&b, "k_%d = ls -la", i)}
	start := time.tick_now()
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	doc, ok := wayu.toml_doc_parse_alloc(strings.to_string(b), virtual.arena_allocator(&arena))
	elapsed := time.tick_since(start)
	testing.expect(t, !ok)
	testing.expect_value(t, len(doc.errors), 10000)
	testing.expect_value(t, len(doc.entries), 10000)
	testing.expectf(t, time.duration_seconds(elapsed) < 1, "took %v", elapsed)
	free_all(context.temp_allocator)
}
