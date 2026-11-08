// test_toml_parser.odin - the single TOML parser (OKAMI-240), seeded
// property tests for read -> write round-trips (OKAMI-173) and write-path
// properties: key order, editor round-trip, symlinked targets (OKAMI-247).

package test_wayu

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import wayu "../../src"

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

KV :: struct { key, value: string }

// Run the readers that use the startup cache (alias/const/path lists, the
// generator) against `content` without touching disk.
@(private = "file")
use_cached_toml :: proc(content: string) {
	wayu.clear_toml_content_cache()
	wayu.TOML_CONTENT_CACHE.content = content
	wayu.TOML_CONTENT_CACHE.loaded = true
	wayu.TOML_CONTENT_CACHE.owned = false
}

@(private = "file")
section :: proc(content, name: string) -> []KV {
	kvs := wayu.toml_read_section(content, name)
	defer delete(kvs)
	out := make([]KV, len(kvs), context.temp_allocator)
	for kv, i in kvs {
		out[i] = {strings.clone(kv.key, context.temp_allocator), strings.clone(kv.value, context.temp_allocator)}
		delete(kv.key); delete(kv.value)
	}
	return out
}

@(private = "file")
kvs_equal :: proc(t: ^testing.T, got, want: []KV, what: string, loc := #caller_location) -> bool {
	ok := len(got) == len(want)
	if ok {
		for g, i in got {
			if g.key != want[i].key || g.value != want[i].value { ok = false; break }
		}
	}
	if !ok { testing.expectf(t, false, "%s:\n got  %v\n want %v", what, got, want, loc = loc) }
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
	content := "\xEF\xBB\xBF[env]\r\n" + // BOM + CRLF
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

	want := []KV{
		{"I", "1000"}, {"H", "31"}, {"P", "5"}, {"B", "true"}, {"F", "3.14"}, {"E", "1e3"},
		{"D", "1979-05-27T07:32:00Z"}, {"DS", "1979-05-27 07:32:00"},
		{"ML", "line1\nline2 joined"}, {"MQ", "a\""}, {"LIT", `C:\no\escape`},
		{"ESC", "\x1b[1m é 😀 A tab\tq\""}, {"EMPTY", ""}, {"quoted key", "v"},
		// ARR / TBL are not scalars: flat-table readers skip them.
	}
	kvs_equal(t, section(content, "env"), want, "[env] value forms")
}

@(test)
test_toml_parser_rejects_invalid :: proc(t: ^testing.T) {
	Case :: struct { src: string, line: int }
	cases := []Case{
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
		{"[env]\nll = ls -la", 2},
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
	content := "\xEF\xBB\xBF[settings]\nautosuggestions_accept_keys = [\n  \"^Y\", # ctrl-y\n  \"^E\",\n]\n\n" +
		"[aliases]\n\".\" = \"cd .\"\n\"..\" = \"cd ..\"\n\"q\\\"k\" = \"echo quoted\"\n"
	config, ok := wayu.toml_parse(content)
	defer wayu.cleanup_toml_config(&config)
	testing.expect(t, ok, "BOM, multi-line array and quoted keys are valid TOML")
	names := make([dynamic]string, context.temp_allocator)
	for a in config.aliases { append(&names, a.name) }
	testing.expectf(t, slice.equal(names[:], []string{".", "..", `q"k`}), "alias names %v", names)
	testing.expectf(t, slice.equal(config.settings.autosuggestions_accept_keys, []string{"^Y", "^E"}),
		"accept keys %v", config.settings.autosuggestions_accept_keys)

	use_cached_toml(content)
	defer wayu.clear_toml_content_cache()
	keys := wayu.plugin_accept_keys_from_toml()
	defer { for k in keys { delete(k) }; delete(keys) }
	testing.expectf(t, slice.equal(keys, []string{"^Y", "^E"}), "plugin loader accept keys %v", keys)

	// The editor finds the decoded key (alias rm ..).
	out, removed, bad := wayu.toml_table_delete(content, "aliases", {".."})
	defer delete(out)
	testing.expect_value(t, bad, 0)
	testing.expect_value(t, removed, 1)
	testing.expect(t, !strings.contains(out, `"..`), out)
	out2, removed2, _ := wayu.toml_table_delete(content, "aliases", {`q"k`})
	defer delete(out2)
	testing.expect_value(t, removed2, 1)
}

// X-19: one input, every reader. Valid TOML -> identical view everywhere.
@(test)
test_toml_readers_parity_seed :: proc(t: ^testing.T) {
	content := "[paths]\nzz = \"/zz\" # first = highest priority\nmm = '/m m'\naa = \"/a\\\"a\"\n\n" +
		"[aliases]\n\"q\\\"k\" = \"echo quoted\"\nglf = \"git log --format='%h'\"\ng.st = \"git status\"\n\n" +
		"[env]\nN = 42\nCERT = \"\"\"\n-----BEGIN-----\nabc=\n-----END-----\"\"\"\nEMPTY = \"\"\n"
	want_paths := []KV{{"zz", "/zz"}, {"mm", "/m m"}, {"aa", `/a"a`}}
	want_aliases := []KV{{`q"k`, "echo quoted"}, {"glf", "git log --format='%h'"}, {"g.st", "git status"}}
	want_env := []KV{{"N", "42"}, {"CERT", "-----BEGIN-----\nabc=\n-----END-----"}, {"EMPTY", ""}}

	_, _, valid := first_error(content)
	testing.expect(t, valid)
	check_all_readers(t, content, want_paths, want_aliases, want_env)
}

// Every consumer of [paths]/[aliases]/[env] must return `want_*`.
@(private = "file")
check_all_readers :: proc(t: ^testing.T, content: string, want_paths, want_aliases, want_env: []KV, loc := #caller_location) -> bool {
	ok := true
	// 1. the shared reader
	ok &= kvs_equal(t, section(content, "paths"), want_paths, "toml_read_section paths", loc)
	ok &= kvs_equal(t, section(content, "aliases"), want_aliases, "toml_read_section aliases", loc)
	ok &= kvs_equal(t, section(content, "env"), want_env, "toml_read_section env", loc)

	// 2. toml_parse (validate, doctor) and the lenient TUI view
	nonempty := make([dynamic]KV, context.temp_allocator)
	for p in want_paths { if len(p.value) > 0 { append(&nonempty, p) } }
	for strict in ([]bool{true, false}) {
		config: wayu.TomlConfig
		if strict {
			parsed, pok := wayu.toml_parse(content)
			config = parsed
			testing.expect(t, pok, "toml_parse", loc = loc)
		} else {
			config = wayu.toml_parse_lenient(content)
		}
		got_p := make([dynamic]KV, context.temp_allocator)
		for e in config.path.entries { append(&got_p, KV{"", e}) }
		want_p := make([dynamic]KV, context.temp_allocator)
		for p in nonempty { append(&want_p, KV{"", p.value}) }
		ok &= kvs_equal(t, got_p[:], want_p[:], "TomlConfig.path.entries (order = priority)", loc)
		got_a := make([dynamic]KV, context.temp_allocator)
		for a in config.aliases { append(&got_a, KV{a.name, a.command}) }
		ok &= kvs_equal(t, got_a[:], want_aliases, "TomlConfig.aliases", loc)
		got_e := make([dynamic]KV, context.temp_allocator)
		for c in config.constants { append(&got_e, KV{c.name, c.value}) }
		ok &= kvs_equal(t, got_e[:], want_env, "TomlConfig.constants", loc)
		wayu.cleanup_toml_config(&config)
	}

	// 3. CLI list readers and the shell generator (startup cache)
	use_cached_toml(content)
	defer wayu.clear_toml_content_cache()
	{
		entries := wayu.read_toml_alias_entries()
		got := make([dynamic]KV, context.temp_allocator)
		for e in entries { append(&got, KV{e.name, e.value}) }
		ok &= kvs_equal(t, got[:], want_aliases, "read_toml_alias_entries (alias list)", loc)
		wayu.cleanup_entries(&entries)
	}
	{
		entries := wayu.read_wayu_toml_constants()
		got := make([dynamic]KV, context.temp_allocator)
		for e in entries { append(&got, KV{e.name, e.value}) }
		ok &= kvs_equal(t, got[:], want_env, "read_wayu_toml_constants (const list)", loc)
		wayu.cleanup_entries(&entries)
	}
	{
		entries := wayu.toml_path_read_keyed()
		got := make([dynamic]KV, context.temp_allocator)
		for e in entries { append(&got, KV{strings.clone(e.key, context.temp_allocator), strings.clone(e.path, context.temp_allocator)}); delete(e.key); delete(e.path) }
		delete(entries)
		ok &= kvs_equal(t, got[:], nonempty[:], "toml_path_read_keyed (path list)", loc)
	}
	for sec, i in ([]string{"paths", "aliases", "env"}) {
		all := [][]KV{want_paths, want_aliases, want_env}
		want := all[i]
		kvs := wayu.read_toml_section_kvs(sec)
		got := make([dynamic]KV, context.temp_allocator)
		for kv in kvs { if len(kv.key) > 0 { append(&got, KV{strings.clone(kv.key, context.temp_allocator), strings.clone(kv.value, context.temp_allocator)}) } }
		wayu.destroy_toml_kvs(&kvs)
		want_nonempty_key := make([dynamic]KV, context.temp_allocator)
		for w in want { if len(w.key) > 0 { append(&want_nonempty_key, w) } }
		ok &= kvs_equal(t, got[:], want_nonempty_key[:], fmt.tprintf("read_toml_section_kvs %s (generator)", sec), loc)
	}

	// 4. the editor sees the same keys: deleting each removes exactly it
	for sec, i in ([]string{"paths", "aliases", "env"}) {
		all := [][]KV{want_paths, want_aliases, want_env}
		want := all[i]
		for w, j in want {
			out, removed, bad := wayu.toml_table_delete(content, sec, {w.key})
			defer delete(out)
			ok &= testing.expectf(t, bad == 0 && removed == 1, "editor: delete %s.%q removed=%d bad=%d", sec, w.key, removed, bad, loc = loc)
			rest := make([dynamic]KV, context.temp_allocator)
			for o, k in want { if k != j && o.key != w.key { append(&rest, o) } }
			ok &= kvs_equal(t, section(out, sec), rest[:], fmt.tprintf("after deleting %s.%q", sec, w.key), loc)
		}
	}
	return ok
}

// ---------------------------------------------------------------------------
// Recovery: invalid lines behave as before for the lenient readers
// ---------------------------------------------------------------------------

@(test)
test_toml_parser_recovers_invalid_lines :: proc(t: ^testing.T) {
	content := "[aliases]\nll = ls -la\nok = \"fine\"\n[env\nHIDDEN = \"x\"\n[env]\nA = \"1\" trailing\nB = \"2\"\n"
	line, _, valid := first_error(content)
	testing.expect(t, !valid)
	testing.expect_value(t, line, 2)
	// Same values the old line readers produced.
	kvs_equal(t, section(content, "aliases"), {{"ll", "ls -la"}, {"ok", "fine"}}, "recovered aliases")
	kvs_equal(t, section(content, "env"), {{"A", `"1" trailing`}, {"B", "2"}}, "recovered env (bad header hides HIDDEN)")

	// toml_parse stays strict; the lenient view (TUI) matches the CLI.
	_, ok := wayu.toml_parse(content)
	testing.expect(t, !ok)
	config := wayu.toml_parse_lenient(content)
	defer wayu.cleanup_toml_config(&config)
	testing.expect_value(t, len(config.aliases), 2)

	// The editor can still replace a recovered line in place.
	out, existed, bad := wayu.toml_table_set(content, "aliases", "ll", `ll = "ls -l"`)
	defer delete(out)
	testing.expect(t, existed && bad == 0)
	testing.expect(t, strings.contains(out, "[aliases]\nll = \"ls -l\"\nok"), out)
}

@(test)
test_toml_editor_refuses_broken_multiline :: proc(t: ^testing.T) {
	content := "[env]\nA = \"1\"\nX = [\n  \"a\",\n  junk\n]\nB = \"2\"\n"
	out, _, bad := wayu.toml_table_set(content, "env", "C", `C = "3"`)
	defer delete(out)
	testing.expect_value(t, bad, 3)
	testing.expect_value(t, out, "")

	// A broken value in ANOTHER table does not block this one.
	other := "[aliases]\nX = \"\"\"\nnever closed\n[env]\nA = \"1\"\n"
	out2, _, bad2 := wayu.toml_table_set(other, "env", "B", `B = "2"`)
	defer delete(out2)
	testing.expect_value(t, bad2, 0)
	testing.expect(t, strings.contains(out2, "A = \"1\"\nB = \"2\""), out2)
}

// A `[header]` line inside a multi-line string is data, not a table.
@(test)
test_toml_editor_ignores_headers_inside_strings :: proc(t: ^testing.T) {
	content := "[aliases]\nX = \"\"\"\n[env]\nFAKE = 1\"\"\"\n\n[env]\nA = \"1\"\n"
	kvs_equal(t, section(content, "env"), {{"A", "1"}}, "[env] inside a string is not a table")
	out, existed, bad := wayu.toml_table_set(content, "env", "A", `A = "2"`)
	defer delete(out)
	testing.expect(t, existed && bad == 0)
	testing.expect(t, strings.contains(out, "FAKE = 1\"\"\""), "string body untouched")
	testing.expect(t, strings.has_suffix(out, "[env]\nA = \"2\"\n"), out)
}

// Keys wayu writes are always valid TOML; an alias named g.st used to be
// written bare (= a dotted key) and is still found by that name.
@(test)
test_toml_writer_quotes_keys :: proc(t: ^testing.T) {
	Case :: struct { key, want: string }
	cases := []Case{{"ll", "ll"}, {"g.st", `"g.st"`}, {"..", `".."`}, {`q"k`, `"q\"k"`}, {"a b", `"a b"`}, {"é", `"é"`}}
	for c in cases {
		got := wayu.toml_format_key(c.key)
		defer delete(got)
		testing.expectf(t, got == c.want, "toml_format_key(%q) = %s, want %s", c.key, got, c.want)
	}

	legacy := "[aliases]\ng.st = \"git status\"\n"
	out, existed, _ := wayu.toml_table_set(legacy, "aliases", "g.st", `"g.st" = "git st"`)
	defer delete(out)
	testing.expect(t, existed, "bare dotted key matched by its joined name")
	testing.expect_value(t, out, "[aliases]\n\"g.st\" = \"git st\"\n")

	esc := wayu.escape_toml_string("a\x1bb\x7f\x00")
	defer delete(esc)
	testing.expect_value(t, esc, `a\u001Bb\u007F\u0000`)
}

@(test)
test_mask_toml_env_section_uses_parser :: proc(t: ^testing.T) {
	content := "[env]\n\"API TOKEN\" = \"fake-quoted-key-secret\"\nKEY_LIST = [\n  \"fake-arr-1\",\n]\nX = 1\n[aliases]\nll = \"ls\"\n"
	out := wayu.mask_toml_env_section(content)
	defer delete(out)
	testing.expect(t, !strings.contains(out, "fake-"), out)
	testing.expect(t, strings.contains(out, "\"API TOKEN\" = \"********\""), out)
	testing.expect(t, strings.contains(out, "X = 1\n[aliases]\nll = \"ls\"\n"), out)

	broken := "[env]\nPEM = \"\"\"\nfake-pem-body\n"
	out2 := wayu.mask_toml_env_section(broken)
	defer delete(out2)
	testing.expect(t, !strings.contains(out2, "fake-pem"), "unterminated multi-line [env] value never leaks")
}

// ---------------------------------------------------------------------------
// OKAMI-173: seeded property test - random keys/values through every form
// ---------------------------------------------------------------------------

@(private = "file")
Rng :: struct { s: u64 }

@(private = "file")
rng_next :: proc(r: ^Rng) -> u64 {
	// xorshift64*: deterministic across platforms and Odin versions.
	r.s ~= r.s >> 12
	r.s ~= r.s << 25
	r.s ~= r.s >> 27
	return r.s * 0x2545F4914F6CDD1D
}

@(private = "file")
rng_int :: proc(r: ^Rng, n: int) -> int { return int(rng_next(r) % u64(n)) }

@(private = "file")
PIECES := [?]string{
	"a", "Z", "0", "_", "-", ".", " ", "\t", "\"", "'", "\\", "#", "=", "[", "]", "{", "}", ",",
	"é", "☕", "😀", "$HOME", "\\u00e9", "\\n", "%h", "'''", "\"\"\"", "\x1b", "\n", "\r",
}

@(private = "file")
rand_text :: proc(r: ^Rng, max_len: int, allow_newline: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	for _ in 0..<rng_int(r, max_len + 1) {
		p := PIECES[rng_int(r, len(PIECES))]
		if !allow_newline && (p == "\n" || p == "\r") { continue }
		strings.write_string(&b, p)
	}
	return strings.to_string(b)
}

// Encode `v` as a random valid TOML string form.
@(private = "file")
encode_value :: proc(r: ^Rng, v: string) -> string {
	plain_literal := !strings.contains_any(v, "'\n\r\x1b")
	ml_literal_ok := !strings.contains_any(v, "'\r\x1b")
	switch rng_int(r, 5) {
	case 1:
		if plain_literal { return strings.concatenate({"'", v, "'"}, context.temp_allocator) }
	case 2:
		if ml_literal_ok { return strings.concatenate({"'''\n", v, "'''"}, context.temp_allocator) }
	case 3:
		// Multi-line basic: raw newlines, everything else escaped.
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "\"\"\"\n")
		for i in 0..<len(v) {
			c := v[i]
			switch c {
			case '\n':      strings.write_byte(&b, '\n')
			case '"':       strings.write_string(&b, `\"`)
			case '\\':      strings.write_string(&b, `\\`)
			case '\r':      strings.write_string(&b, `\r`)
			case 0x1b:      strings.write_string(&b, `\e`)
			case:           strings.write_byte(&b, c)
			}
		}
		strings.write_string(&b, "\"\"\"")
		return strings.to_string(b)
	case 4:
		// Basic with \u escapes for some ASCII letters.
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '"')
		esc := wayu.escape_toml_string(v)
		defer delete(esc)
		for i := 0; i < len(esc); i += 1 {
			c := esc[i]
			if c == '\\' { // keep existing escapes intact
				strings.write_string(&b, esc[i:i+2])
				i += 1
				continue
			}
			if (c >= 'a' && c <= 'z') && rng_int(r, 3) == 0 { fmt.sbprintf(&b, `\u%04x`, c) } else { strings.write_byte(&b, c) }
		}
		strings.write_byte(&b, '"')
		return strings.to_string(b)
	}
	esc := wayu.escape_toml_string(v)
	defer delete(esc)
	return strings.concatenate({`"`, esc, `"`}, context.temp_allocator)
}

@(private = "file")
encode_key :: proc(r: ^Rng, k: string) -> string {
	if wayu.toml_key_is_plain(k) && rng_int(r, 4) != 0 { return k }
	if !strings.contains_any(k, "'\n\r\x1b") && rng_int(r, 2) == 0 {
		return strings.concatenate({"'", k, "'"}, context.temp_allocator)
	}
	esc := wayu.escape_toml_string(k)
	defer delete(esc)
	return strings.concatenate({`"`, esc, `"`}, context.temp_allocator)
}

@(private = "file")
NOISE := [?]string{
	"",
	"# [env]",
	"# fake = \"commented out\"",
	"   # indented comment",
}

@(private = "file")
SECTIONS := [?]string{"paths", "aliases", "env"}

// Random document: [paths]/[aliases]/[env] in random order with random
// entries and noise, plus unrelated tables. Returns the text and the
// expected (key, value) list per section.
@(private = "file")
gen_doc :: proc(r: ^Rng) -> (string, [3][]KV) {
	b := strings.builder_make(context.temp_allocator)
	if rng_int(r, 4) == 0 { strings.write_string(&b, "\xEF\xBB\xBF") }
	strings.write_string(&b, "[shell]\ntype = \"zsh\"\n\n")
	if rng_int(r, 2) == 0 {
		strings.write_string(&b, "[settings]\nautosuggestions_accept_keys = [\n  \"^Y\", # y\n  \"^E\",\n]\n\n")
	}
	want: [3][]KV
	order := [3]int{0, 1, 2}
	for i := 2; i > 0; i -= 1 { j := rng_int(r, i + 1); order[i], order[j] = order[j], order[i] }
	for si in order {
		fmt.sbprintfln(&b, "[%s]%s", SECTIONS[si], rng_int(r, 3) == 0 ? "  # table" : "")
		seen := make(map[string]bool, allocator = context.temp_allocator)
		kvs := make([dynamic]KV, context.temp_allocator)
		for _ in 0..<rng_int(r, 10) {
			k := rand_text(r, 4, false)
			if rng_int(r, 2) == 0 { k = fmt.tprintf("k%d", rng_int(r, 1000)) }
			if k in seen { continue }
			seen[k] = true
			v := rand_text(r, 8, true)
			if si == 0 && len(v) == 0 { v = "/bin" }
			if rng_int(r, 4) == 0 { strings.write_string(&b, NOISE[rng_int(r, len(NOISE))]); strings.write_byte(&b, '\n') }
			indents := []string{"", "  ", "\t"}
			eqs := []string{" = ", "=", "  =\t"}
			comments := []string{"", " # note \"x\" 'y' = [", "\t#"}
			indent, eq, comment := indents[rng_int(r, 3)], eqs[rng_int(r, 3)], comments[rng_int(r, 3)]
			fmt.sbprintfln(&b, "%s%s%s%s%s", indent, encode_key(r, k), eq, encode_value(r, v), comment)
			append(&kvs, KV{k, v})
		}
		strings.write_byte(&b, '\n')
		want[si] = kvs[:]
	}
	if rng_int(r, 2) == 0 {
		strings.write_string(&b, "[[plugins]]\nname = \"p\"\n\n[profile.work]\ncondition = \"true\"\n")
	}
	return strings.to_string(b), want
}

// Canonical serialisation, exactly what wayu's writer emits.
@(private = "file")
serialize :: proc(want: [3][]KV) -> string {
	b := strings.builder_make(context.temp_allocator)
	for kvs, si in want {
		fmt.sbprintfln(&b, "[%s]", SECTIONS[si])
		for kv in kvs {
			k := wayu.toml_format_key(kv.key)
			v := wayu.escape_toml_string(kv.value)
			fmt.sbprintfln(&b, "%s = \"%s\"", k, v)
			delete(k); delete(v)
		}
	}
	return strings.to_string(b)
}

PROPERTY_SEED :: 0x5EED_0173
PROPERTY_RUNS :: 1000

@(test)
test_toml_property_read_write_round_trip :: proc(t: ^testing.T) {
	r := Rng{PROPERTY_SEED}
	for run in 0..<PROPERTY_RUNS {
		free_all(context.temp_allocator)
		content, want := gen_doc(&r)

		if ok, e := wayu.toml_check(content); !ok {
			testing.expectf(t, false, "run %d: generated TOML rejected (line %d: %s):\n%s", run, e.line, e.msg, content)
			delete(e.msg)
			return
		}
		// parse -> every reader agrees with what was generated
		if !check_all_readers(t, content, want[0], want[1], want[2]) {
			fmt.eprintfln("run %d failed on:\n%s", run, content)
			return
		}
		// parse -> serialize -> parse is the identity
		canon := serialize(want)
		for si in 0..<3 {
			if !kvs_equal(t, section(canon, SECTIONS[si]), want[si], fmt.tprintf("run %d: re-serialised [%s]", run, SECTIONS[si])) {
				fmt.eprintfln("%s", canon)
				return
			}
		}
		// editor round-trip: set every key to a new value in place - order,
		// other tables and the rest of the file are preserved.
		edited := content
		for si in 0..<3 {
			expect := slice.clone(want[si], context.temp_allocator)
			for &kv, i in expect {
				nv := fmt.tprintf("v%d-%d %s", run, i, kv.value)
				k := wayu.toml_format_key(kv.key)
				v := wayu.escape_toml_string(nv)
				out, existed, bad := wayu.toml_table_set(edited, SECTIONS[si], kv.key, fmt.tprintf("%s = \"%s\"", k, v))
				delete(k); delete(v)
				if !testing.expectf(t, existed && bad == 0, "run %d: set %s.%q existed=%v bad=%d", run, SECTIONS[si], kv.key, existed, bad) { return }
				edited = strings.clone(out, context.temp_allocator)
				delete(out)
				kv.value = nv
			}
			if !kvs_equal(t, section(edited, SECTIONS[si]), expect, fmt.tprintf("run %d: [%s] after in-place sets", run, SECTIONS[si])) { return }
			want[si] = expect
		}
		if ok, e := wayu.toml_check(edited); !ok {
			testing.expectf(t, false, "run %d: edited file invalid (line %d: %s):\n%s", run, e.line, e.msg, edited)
			delete(e.msg)
			return
		}
		// secret masking keeps exactly the [env] keys
		masked := wayu.mask_toml_env_section(content)
		mkvs := section(masked, "env")
		delete(masked)
		testing.expectf(t, len(mkvs) == len(want[2]),
			"run %d: masking changed the [env] key count", run)
	}
}

// ---------------------------------------------------------------------------
// OKAMI-247: write-path properties
// ---------------------------------------------------------------------------

// Reverse-alphabetical keys: declaration order (PATH priority) must survive
// adds, rewrites and deletes, and every reader must report it.
@(test)
test_toml_key_order_reverse_alphabetical :: proc(t: ^testing.T) {
	content := "[paths]\nzz = \"/zz\"\nyy = \"/yy\"\nbb = \"/bb\"\n"
	out1, _, _ := wayu.toml_table_set(content, "paths", "aa", `aa = "/aa"`)
	defer delete(out1)
	out2, _, _ := wayu.toml_table_set(out1, "paths", "yy", `yy = "/YY"`)
	defer delete(out2)
	out3, _, _ := wayu.toml_table_delete(out2, "paths", {"bb"})
	defer delete(out3)
	want := []KV{{"zz", "/zz"}, {"yy", "/YY"}, {"aa", "/aa"}}
	check_all_readers(t, out3, want, {}, {})
}

// Every TOML value form survives a rewrite of a neighbouring entry
// byte-for-byte (golden round-trip).
@(test)
test_toml_rich_values_round_trip_through_rewrite :: proc(t: ^testing.T) {
	content := "[env]\n" +
		"S = \"basic \\\"q\\\" \\u00e9\" # c\n" +
		"L = 'lit \\n'\n" +
		"MB = \"\"\"\nmulti\nline\"\"\"\n" +
		"ML = '''\nraw\\\nlines'''\n" +
		"I = 1_000\n" +
		"F = 6.02e23\n" +
		"B = false\n" +
		"D = 2026-11-07\n" +
		"A = [1, \"two\", [3]]\n" +
		"T = { k = \"v\", n = { m = 1 } }\n" +
		"ARR = [\n  \"x\", # inside\n]\n" +
		"EDIT = \"old\"\n"
	out, existed, bad := wayu.toml_table_set(content, "env", "EDIT", `EDIT = "new"`)
	defer delete(out)
	testing.expect(t, existed && bad == 0)
	want, _ := strings.replace(content, `EDIT = "old"`, `EDIT = "new"`, 1, context.temp_allocator)
	testing.expect_value(t, out, want)
	_, _, valid := first_error(out)
	testing.expect(t, valid)

	out2, removed, _ := wayu.toml_table_delete(out, "env", {"MB", "ARR", "T"})
	defer delete(out2)
	testing.expect_value(t, removed, 3)
	testing.expect(t, !strings.contains(out2, "multi") && !strings.contains(out2, "inside") && !strings.contains(out2, "{ k"), out2)
	kvs_equal(t, section(out2, "env"), {
		{"S", "basic \"q\" é"}, {"L", `lit \n`}, {"ML", "raw\\\nlines"}, {"I", "1000"},
		{"F", "6.02e23"}, {"B", "false"}, {"D", "2026-11-07"}, {"EDIT", "new"},
	}, "values after deleting multi-line entries")
}

// Verify (OKAMI-247 follow-up): sync_init_orchestrator rewrites init.<ext>
// through write_init_file -> write_file_atomic (temp + rename). With a
// stow-style symlinked init.zsh the TARGET must be replaced and the link
// kept. (wayu.toml writes: test_write_integrity.rb Test 6.)
@(test)
test_write_init_file_keeps_symlinked_init :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/wayu-test-init-symlink-%d", os.get_pid())
	os.remove_all(dir)
	defer os.remove_all(dir)
	data := fmt.tprintf("%s/data", dir)
	dotfiles := fmt.tprintf("%s/dotfiles", dir)
	testing.expect_value(t, os.make_directory_all(data), nil)
	testing.expect_value(t, os.make_directory_all(dotfiles), nil)

	real := fmt.tprintf("%s/init.zsh", dotfiles)
	link := fmt.tprintf("%s/init.zsh", data)
	testing.expect_value(t, os.write_entire_file(real, transmute([]byte)string("# Wayu Shell Initialization\nold\n")), nil)
	testing.expect_value(t, os.symlink(real, link), nil)

	template := wayu.get_init_template(.ZSH)
	wayu.write_init_file(link, template)

	lfi, lerr := os.lstat(link, context.temp_allocator)
	testing.expect_value(t, lerr, nil)
	testing.expect_value(t, lfi.type, os.File_Type.Symlink)
	got, _ := os.read_entire_file(real, context.temp_allocator)
	testing.expect_value(t, string(got), template)
}

// The parse of a large file stays fast (all readers parse the whole file).
@(test)
test_toml_parser_large_file_fast :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[aliases]\n")
	for i in 0..<6000 { fmt.sbprintfln(&b, "a_%d = \"echo %d --flag 'x' # not a comment\" # c", i, i) }
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	doc, ok := wayu.toml_doc_parse_alloc(strings.to_string(b), virtual.arena_allocator(&arena))
	testing.expect(t, ok)
	testing.expect_value(t, len(doc.entries), 6000)
}
