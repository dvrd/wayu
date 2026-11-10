// entries.odin - the entry store: <data>/entries.json
//
// PATH entries, aliases and environment constants are managed by wayu
// commands (`wayu path|alias|const add/rm`, the TUI, templates) and live in
// the data dir, not in the hand-edited wayu.toml:
//
//   {
//     "version": 1,
//     "paths": [
//       {"key": "local_bin", "dir": "/usr/local/bin"}
//     ],
//     "aliases": [
//       {"name": "ll", "value": "ls -la"}
//     ],
//     "env": [
//       {"name": "EDITOR", "value": "nvim"}
//     ],
//     "fpath": ["$HOME/.grok/completions/zsh"],
//     "generators": [
//       {"shell": "zsh", "cmd": "ng", "args": "completion script"}
//     ]
//   }
//
// `fpath` (zsh completion dirs, put on fpath before compinit) and
// `generators` (`source <(cmd args)` / `eval "$(cmd args)"` lines, run
// through the evalcache in that shell's core) are filled by `wayu optimize`
// (optimize.odin) and `wayu completions fpath`; each is written only when
// non-empty.
//
// Arrays keep their order: paths order = PATH priority, aliases and env keep
// insertion order. A path's `key` is the name `wayu path add key=dir` gives
// it (else derived from the dir) and what `wayu path rm key` matches.
//
// Reading is strict: a missing file is an empty store, anything that does not
// parse (or breaks the schema) is a config error naming the file — never
// silently treated as empty. Writes replace the whole file atomically, under
// the config lock (callers take it), mode 0600 (env values may be secrets),
// after a backup.
package wayu

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

ENTRIES_FILE :: "entries.json"

// Format marker of entries.json (not a migration hook: other values are
// rejected).
ENTRIES_FORMAT_VERSION :: 1

StorePath :: struct {
	key: string,
	dir: string,
}

StoreAlias :: struct {
	name:  string,
	value: string,
}

// `secret` marks a constant whose value is kept encrypted outside this file
// (no `value` here); `run_only` (with `secret`) marks one that is only
// injected by `wayu secrets run`, never exported by the shell. Each is
// serialized only when true.
StoreEnv :: struct {
	name:     string,
	value:    string,
	secret:   bool,
	run_only: bool,
}

// A cached generator: core.<shell> runs `_wayu_evalcache cmd args` (output
// cached, re-run when the binary changes). `args` uses the [tools] args
// syntax (tool_args_to_shell).
StoreGenerator :: struct {
	shell: string, // "zsh" | "bash" | "fish": the core it is emitted into
	cmd:   string,
	args:  string,
}

EntryStore :: struct {
	version:    int,
	paths:      [dynamic]StorePath,
	aliases:    [dynamic]StoreAlias,
	env:        [dynamic]StoreEnv,
	fpath:      [dynamic]string,
	generators: [dynamic]StoreGenerator,
}

// Which name/value list of the store an alias/constant operation targets.
EntryKind :: enum {
	ALIAS,
	ENV,
}

// <data>/entries.json (temp allocator unless given).
entries_file_path :: proc(allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/%s", wayu.data, ENTRIES_FILE, allocator = allocator)
}

entries_store_destroy :: proc(s: ^EntryStore) {
	for p in s.paths {delete(p.key); delete(p.dir)}
	for a in s.aliases {delete(a.name); delete(a.value)}
	for e in s.env {delete(e.name); delete(e.value)}
	for f in s.fpath {delete(f)}
	for g in s.generators {delete(g.shell); delete(g.cmd); delete(g.args)}
	delete(s.paths)
	delete(s.aliases)
	delete(s.env)
	delete(s.fpath)
	delete(s.generators)
	s^ = {}
}

// Parse entries.json content strictly (OKAMI-321): exactly one JSON
// document (RFC 8259: no trailing commas, nothing after it, no duplicate
// keys, valid UTF-8, no NUL), every field of the schema with its exact type
// and no unknown field, `"version": 1` as a number, names valid (aliases:
// alias_name_error; constants: shell variable names; PATH keys: letters,
// digits, `_`), values present (an alias's command non-empty; a constant's
// value unless it is a secret), names / keys unique, dirs non-empty without
// ':' or newlines. `err` (temp allocator) says what is wrong when ok=false.
// On success the store's strings are in context.allocator.
entries_parse :: proc(content: string) -> (store: EntryStore, err: string, ok: bool) {
	if serr := json_strict_check(content); len(serr) > 0 {
		return {}, fmt.tprintf("not valid JSON (%s)", serr), false
	}

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return {}, "out of memory", false
	}
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

	doc, perr := json.parse_string(content, .JSON, true, scratch)
	if perr != nil {
		return {}, fmt.tprintf("not valid JSON (%v)", perr), false
	}
	raw: EntryStore
	if werr := entries_from_json(doc, &raw, scratch); len(werr) > 0 {
		return {}, werr, false
	}
	for p, i in raw.paths {
		if len(p.key) == 0 {
			return {}, fmt.tprintf("paths[%d] has no \"key\"", i), false
		}
		if !entries_is_path_key(p.key) {
			return {},
				fmt.tprintf(
					"paths[%d]: invalid \"key\" %q (letters, digits and _ only)",
					i,
					p.key,
				),
				false
		}
		if len(strings.trim_space(p.dir)) == 0 {
			return {}, fmt.tprintf("paths[%d] (%s) has no \"dir\"", i, p.key), false
		}
		if !is_path_entry_safe(p.dir) {
			return {},
				fmt.tprintf("paths[%d] (%s): \"dir\" contains ':' or a newline", i, p.key),
				false
		}
		for q in raw.paths[:i] {
			if q.key == p.key {
				return {}, fmt.tprintf("paths: key %q appears twice", p.key), false
			}
		}
	}
	for a, i in raw.aliases {
		if len(a.name) == 0 {
			return {}, fmt.tprintf("aliases[%d] has no \"name\"", i), false
		}
		if nerr := alias_name_error(a.name); len(nerr) > 0 {
			return {}, fmt.tprintf("aliases[%d]: %s", i, nerr), false
		}
		if len(strings.trim_space(a.value)) == 0 {
			return {}, fmt.tprintf("aliases[%d] (%s) has an empty \"value\"", i, a.name), false
		}
		for b in raw.aliases[:i] {
			if b.name == a.name {
				return {}, fmt.tprintf("aliases: %q appears twice", a.name), false
			}
		}
	}
	for e, i in raw.env {
		if len(e.name) == 0 {
			return {}, fmt.tprintf("env[%d] has no \"name\"", i), false
		}
		if !is_shell_var_name(e.name) {
			return {},
				fmt.tprintf(
					"env[%d]: invalid \"name\" %q (letters, digits and _, not starting with a digit)",
					i,
					e.name,
				),
				false
		}
		for f in raw.env[:i] {
			if f.name == e.name {
				return {}, fmt.tprintf("env: %q appears twice", e.name), false
			}
		}
	}

	for f, i in raw.fpath {
		if len(strings.trim_space(f)) == 0 {
			return {}, fmt.tprintf("fpath[%d] is empty", i), false
		}
		if !is_path_entry_safe(f) {
			return {}, fmt.tprintf("fpath[%d] contains ':' or a newline", i), false
		}
		for g in raw.fpath[:i] {
			if g == f {
				return {}, fmt.tprintf("fpath: %q appears twice", f), false
			}
		}
	}
	for g, i in raw.generators {
		switch g.shell {
		case "zsh", "bash", "fish":
		case:
			return {}, fmt.tprintf("generators[%d]: \"shell\" must be zsh, bash or fish", i), false
		}
		if !is_safe_alias_name(g.cmd) {
			return {}, fmt.tprintf("generators[%d]: invalid \"cmd\" %q", i, g.cmd), false
		}
		if strings.contains_any(g.args, "\n\r") {
			return {},
				fmt.tprintf("generators[%d] (%s): \"args\" contains a newline", i, g.cmd),
				false
		}
		for h in raw.generators[:i] {
			if h.shell == g.shell && h.cmd == g.cmd && h.args == g.args {
				return {},
					fmt.tprintf("generators: %s %s (%s) appears twice", g.cmd, g.args, g.shell),
					false
			}
		}
	}

	store.version = raw.version
	store.paths = make([dynamic]StorePath, 0, len(raw.paths))
	store.aliases = make([dynamic]StoreAlias, 0, len(raw.aliases))
	store.env = make([dynamic]StoreEnv, 0, len(raw.env))
	for p in raw.paths {append(&store.paths, StorePath{strings.clone(p.key), strings.clone(p.dir)})}
	for a in raw.aliases {append(&store.aliases, StoreAlias{strings.clone(a.name), strings.clone(a.value)})}
	for e in raw.env {append(&store.env, StoreEnv{strings.clone(e.name), strings.clone(e.value), e.secret, e.secret && e.run_only})}
	store.fpath = make([dynamic]string, 0, len(raw.fpath))
	store.generators = make([dynamic]StoreGenerator, 0, len(raw.generators))
	for f in raw.fpath {append(&store.fpath, strings.clone(f))}
	for g in raw.generators {append(&store.generators, StoreGenerator{strings.clone(g.shell), strings.clone(g.cmd), strings.clone(g.args)})}
	return store, "", true
}

// A PATH entry key: letters, digits and `_` (what sanitize_path_key and
// derive_path_key produce, plus upper case for hand edits).
@(private = "file")
entries_is_path_key :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	for i in 0 ..< len(s) {
		c := s[i]
		ok :=
			(c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
		if !ok do return false
	}
	return true
}

// Fill `raw` (allocated with `allocator`) from the parsed entries.json
// document, checking every field's presence and type and refusing unknown
// fields. Returns the error ("" when the document fits the schema);
// temp-allocated.
@(private = "file")
entries_from_json :: proc(
	doc: json.Value,
	raw: ^EntryStore,
	allocator: runtime.Allocator,
) -> string {
	root, is_obj := doc.(json.Object)
	if !is_obj do return "the top level must be an object"
	for k in root {
		switch k {
		case "version", "paths", "aliases", "env", "fpath", "generators":
		case:
			return fmt.tprintf("unknown field %q", k)
		}
	}
	version, has_version := root["version"]
	if !has_version do return "missing \"version\""
	n, is_int := version.(json.Integer)
	if !is_int || n != ENTRIES_FORMAT_VERSION {
		return fmt.tprintf("\"version\" must be the number %d", ENTRIES_FORMAT_VERSION)
	}
	raw.version = int(n)
	raw.paths = make([dynamic]StorePath, allocator)
	raw.aliases = make([dynamic]StoreAlias, allocator)
	raw.env = make([dynamic]StoreEnv, allocator)
	raw.fpath = make([dynamic]string, allocator)
	raw.generators = make([dynamic]StoreGenerator, allocator)

	items, err := entries_json_array(root, "paths")
	if len(err) > 0 do return err
	for item, i in items {
		at := fmt.tprintf("paths[%d]", i)
		o, oerr := entries_json_object(item, at, {"key", "dir"}, 2)
		if len(oerr) > 0 do return oerr
		p: StorePath
		ferr: string
		entries_json_str(o, "key", at, &p.key, &ferr)
		entries_json_str(o, "dir", at, &p.dir, &ferr)
		if len(ferr) > 0 do return ferr
		append(&raw.paths, p)
	}

	items, err = entries_json_array(root, "aliases")
	if len(err) > 0 do return err
	for item, i in items {
		at := fmt.tprintf("aliases[%d]", i)
		o, oerr := entries_json_object(item, at, {"name", "value"}, 2)
		if len(oerr) > 0 do return oerr
		a: StoreAlias
		ferr: string
		entries_json_str(o, "name", at, &a.name, &ferr)
		entries_json_str(o, "value", at, &a.value, &ferr)
		if len(ferr) > 0 do return ferr
		append(&raw.aliases, a)
	}

	items, err = entries_json_array(root, "env")
	if len(err) > 0 do return err
	for item, i in items {
		at := fmt.tprintf("env[%d]", i)
		o, oerr := entries_json_object(item, at, {"name", "value", "secret", "run_only"}, 1)
		if len(oerr) > 0 do return oerr
		e: StoreEnv
		ferr: string
		entries_json_str(o, "name", at, &e.name, &ferr)
		has_value := entries_json_str(o, "value", at, &e.value, &ferr)
		entries_json_flag(o, "secret", at, &e.secret, &ferr)
		entries_json_flag(o, "run_only", at, &e.run_only, &ferr)
		if len(ferr) > 0 do return ferr
		switch {
		case e.secret && has_value:
			return fmt.tprintf("%s (%s): a secret has no \"value\" here", at, e.name)
		case !e.secret && !has_value:
			return fmt.tprintf("%s (%s) has no \"value\"", at, e.name)
		case e.run_only && !e.secret:
			return fmt.tprintf("%s (%s): \"run_only\" needs \"secret\": true", at, e.name)
		}
		append(&raw.env, e)
	}

	items, err = entries_json_array(root, "fpath")
	if len(err) > 0 do return err
	for item, i in items {
		s, is_str := item.(json.String)
		if !is_str do return fmt.tprintf("fpath[%d] must be a string", i)
		append(&raw.fpath, string(s))
	}

	items, err = entries_json_array(root, "generators")
	if len(err) > 0 do return err
	for item, i in items {
		at := fmt.tprintf("generators[%d]", i)
		o, oerr := entries_json_object(item, at, {"shell", "cmd", "args"}, 3)
		if len(oerr) > 0 do return oerr
		g: StoreGenerator
		ferr: string
		entries_json_str(o, "shell", at, &g.shell, &ferr)
		entries_json_str(o, "cmd", at, &g.cmd, &ferr)
		entries_json_str(o, "args", at, &g.args, &ferr)
		if len(ferr) > 0 do return ferr
		append(&raw.generators, g)
	}
	return ""
}

// root[key] as an array (absent: empty). err is temp-allocated.
@(private = "file")
entries_json_array :: proc(root: json.Object, key: string) -> (items: json.Array, err: string) {
	v, has := root[key]
	if !has do return nil, ""
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil, fmt.tprintf("%q must be an array", key)
	return arr, ""
}

// `v` as an object whose fields are all in `allowed`, with the first
// `required` of them present. err is temp-allocated.
@(private = "file")
entries_json_object :: proc(
	v: json.Value,
	at: string,
	allowed: []string,
	required: int,
) -> (
	o: json.Object,
	err: string,
) {
	obj, is_obj := v.(json.Object)
	if !is_obj do return nil, fmt.tprintf("%s must be an object", at)
	for k in obj {
		known := false
		for a in allowed {
			if k == a {
				known = true; break
			}
		}
		if !known do return nil, fmt.tprintf("%s: unknown field %q", at, k)
	}
	for a in allowed[:required] {
		if a not_in obj do return nil, fmt.tprintf("%s has no %q", at, a)
	}
	return obj, ""
}

// dst^ = o[key] when it is a string; returns whether the field is present.
// A non-string records an error in err^ (the first one wins).
@(private = "file")
entries_json_str :: proc(o: json.Object, key, at: string, dst: ^string, err: ^string) -> bool {
	v, has := o[key]
	if !has do return false
	str, is_str := v.(json.String)
	if !is_str {
		if len(err^) == 0 do err^ = fmt.tprintf("%s: %q must be a string", at, key)
		return true
	}
	dst^ = string(str)
	return true
}

// dst^ = o[key] when it is a boolean (absent: unchanged); a non-boolean
// records an error in err^ (the first one wins).
@(private = "file")
entries_json_flag :: proc(o: json.Object, key, at: string, dst: ^bool, err: ^string) {
	v, has := o[key]
	if !has do return
	val, is_bool := v.(json.Boolean)
	if !is_bool {
		if len(err^) == 0 do err^ = fmt.tprintf("%s: %q must be true or false", at, key)
		return
	}
	dst^ = bool(val)
}

// Strict RFC 8259 syntax check of a whole JSON text: exactly one value
// surrounded by whitespace only, no trailing commas, no duplicate keys in
// an object, valid UTF-8, no control characters inside strings, no NUL
// (`\u0000`), nesting at most 64 deep. core:encoding/json accepts trailing
// commas and ignores whatever follows the first value. Returns the problem
// with its line ("" when the text is fine); temp-allocated.
json_strict_check :: proc(s: string) -> string {
	if !utf8.valid_string(s) {
		return "not valid UTF-8"
	}
	p := Json_Strict {
		s = s,
	}
	if !jsc_value(&p) {
		return p.err
	}
	jsc_ws(&p)
	if p.i != len(p.s) {
		jsc_fail(&p, "unexpected content after the JSON document")
		return p.err
	}
	return ""
}

@(private = "file")
Json_Strict :: struct {
	s:     string,
	i:     int,
	depth: int,
	err:   string,
}

@(private = "file")
jsc_fail :: proc(p: ^Json_Strict, msg: string) -> bool {
	if len(p.err) == 0 {
		line := 1 + strings.count(p.s[:min(p.i, len(p.s))], "\n")
		p.err = fmt.tprintf("line %d: %s", line, msg)
	}
	return false
}

@(private = "file")
jsc_ws :: proc(p: ^Json_Strict) {
	for p.i < len(p.s) {
		switch p.s[p.i] {
		case ' ', '\t', '\n', '\r':
			p.i += 1
		case:
			return
		}
	}
}

@(private = "file")
jsc_value :: proc(p: ^Json_Strict) -> bool {
	jsc_ws(p)
	if p.i >= len(p.s) do return jsc_fail(p, "unexpected end of the file")
	switch c := p.s[p.i]; c {
	case '{', '[':
		return jsc_container(p, c)
	case '"':
		_, ok := jsc_string(p)
		return ok
	case 't':
		return jsc_literal(p, "true")
	case 'f':
		return jsc_literal(p, "false")
	case 'n':
		return jsc_literal(p, "null")
	case '-', '0' ..= '9':
		return jsc_number(p)
	}
	return jsc_fail(p, fmt.tprintf("unexpected character %q", rune(p.s[p.i])))
}

// An object (open == '{') or array (open == '[').
@(private = "file")
jsc_container :: proc(p: ^Json_Strict, open: u8) -> bool {
	close: u8 = '}' if open == '{' else ']'
	p.depth += 1
	if p.depth > 64 do return jsc_fail(p, "nested too deeply")
	p.i += 1
	keys := make([dynamic]string, context.temp_allocator)
	jsc_ws(p)
	if p.i < len(p.s) && p.s[p.i] == close {
		p.i += 1
		p.depth -= 1
		return true
	}
	for {
		if open == '{' {
			jsc_ws(p)
			if p.i >= len(p.s) || p.s[p.i] != '"' do return jsc_fail(p, "expected a quoted key")
			key := jsc_string(p) or_return
			for k in keys {
				if k == key do return jsc_fail(p, fmt.tprintf("key %q appears twice in one object", key))
			}
			append(&keys, key)
			jsc_ws(p)
			if p.i >= len(p.s) || p.s[p.i] != ':' do return jsc_fail(p, "expected ':' after a key")
			p.i += 1
		}
		jsc_value(p) or_return
		jsc_ws(p)
		if p.i >= len(p.s) do return jsc_fail(p, "unexpected end of the file")
		if p.s[p.i] == ',' {
			p.i += 1
			jsc_ws(p)
			if p.i < len(p.s) && p.s[p.i] == close do return jsc_fail(p, "trailing comma")
			continue
		}
		if p.s[p.i] == close {
			p.i += 1
			p.depth -= 1
			return true
		}
		return jsc_fail(p, fmt.tprintf("expected ',' or '%c'", rune(close)))
	}
}

// A string token at p.i (the opening quote); returns its raw text.
@(private = "file")
jsc_string :: proc(p: ^Json_Strict) -> (raw: string, ok: bool) {
	p.i += 1
	start := p.i
	for p.i < len(p.s) {
		c := p.s[p.i]
		switch {
		case c == '"':
			raw = p.s[start:p.i]
			p.i += 1
			return raw, true
		case c == '\\':
			if p.i + 1 >= len(p.s) do return "", jsc_fail(p, "unterminated string")
			switch p.s[p.i + 1] {
			case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
				p.i += 2
			case 'u':
				if p.i + 6 > len(p.s) do return "", jsc_fail(p, "incomplete \\u escape")
				hex := p.s[p.i + 2:p.i + 6]
				for h in hex {
					if !strings.contains_rune("0123456789abcdefABCDEF", h) {
						return "", jsc_fail(p, "invalid \\u escape")
					}
				}
				if hex == "0000" do return "", jsc_fail(p, "NUL character (\\u0000) in a string")
				p.i += 6
			case:
				return "", jsc_fail(p, "invalid escape in a string")
			}
		case c < 0x20:
			return "", jsc_fail(p, "control character inside a string (escape it)")
		case:
			p.i += 1
		}
	}
	return "", jsc_fail(p, "unterminated string")
}

@(private = "file")
jsc_literal :: proc(p: ^Json_Strict, word: string) -> bool {
	if !strings.has_prefix(p.s[p.i:], word) do return jsc_fail(p, "invalid literal")
	p.i += len(word)
	return true
}

// -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
@(private = "file")
jsc_number :: proc(p: ^Json_Strict) -> bool {
	digits :: proc(p: ^Json_Strict) -> int {
		n := 0
		for p.i < len(p.s) && p.s[p.i] >= '0' && p.s[p.i] <= '9' {
			p.i += 1
			n += 1
		}
		return n
	}
	if p.s[p.i] == '-' do p.i += 1
	if p.i < len(p.s) && p.s[p.i] == '0' {
		p.i += 1
	} else if digits(p) == 0 {
		return jsc_fail(p, "invalid number")
	}
	if p.i < len(p.s) && p.s[p.i] == '.' {
		p.i += 1
		if digits(p) == 0 do return jsc_fail(p, "invalid number")
	}
	if p.i < len(p.s) && (p.s[p.i] == 'e' || p.s[p.i] == 'E') {
		p.i += 1
		if p.i < len(p.s) && (p.s[p.i] == '+' || p.s[p.i] == '-') do p.i += 1
		if digits(p) == 0 do return jsc_fail(p, "invalid number")
	}
	return true
}

// Read entries.json without exiting or printing. Missing file = empty store
// (ok). Unreadable or malformed: ok=false and `err` (temp allocator) is the
// full message, naming the file.
entries_read :: proc() -> (store: EntryStore, err: string, ok: bool) {
	file := entries_file_path()
	data, rerr := os.read_entire_file(file, context.allocator)
	if rerr != nil {
		if !os.exists(file) {
			return EntryStore{version = ENTRIES_FORMAT_VERSION}, "", true
		}
		return {}, fmt.tprintf("cannot read %s: %v", file, rerr), false
	}
	defer delete(data)
	s, perr, pok := entries_parse(string(data))
	if !pok {
		return {},
			fmt.tprintf(
				"%s: %s (wayu manages this file; restore it with 'wayu backup restore entries')",
				file,
				perr,
			),
			false
	}
	return s, "", true
}

// entries_read for commands: on failure print the reason and exit
// EXIT_CONFIG (wayu_exit restores the terminal when the TUI is up).
entries_load :: proc() -> EntryStore {
	store, err, ok := entries_read()
	if !ok {
		print_error_simple("%s", err)
		wayu_exit(EXIT_CONFIG)
	}
	return store
}

// entries.json text: stable key order, one entry per line, trailing newline.
// Caller deletes.
entries_serialize :: proc(s: ^EntryStore) -> string {
	b := strings.builder_make()
	q :: proc(b: ^strings.Builder, v: string) {
		e := json_escape(v)
		defer delete(e)
		strings.write_byte(b, '"')
		strings.write_string(b, e)
		strings.write_byte(b, '"')
	}
	section :: proc(b: ^strings.Builder, name: string, n: int, last: bool) -> bool {
		fmt.sbprintf(b, "  \"%s\": [", name)
		if n == 0 {
			strings.write_string(b, "]")
			strings.write_string(b, "\n" if last else ",\n")
			return false
		}
		strings.write_byte(b, '\n')
		return true
	}
	close :: proc(b: ^strings.Builder, last: bool) {
		strings.write_string(b, "  ]")
		strings.write_string(b, "\n" if last else ",\n")
	}

	strings.write_string(&b, "{\n")
	fmt.sbprintf(&b, "  \"version\": %d,\n", ENTRIES_FORMAT_VERSION)
	if section(&b, "paths", len(s.paths), false) {
		for p, i in s.paths {
			strings.write_string(&b, "    {\"key\": "); q(&b, p.key)
			strings.write_string(&b, ", \"dir\": "); q(&b, p.dir)
			strings.write_string(&b, "}," if i + 1 < len(s.paths) else "}")
			strings.write_byte(&b, '\n')
		}
		close(&b, false)
	}
	if section(&b, "aliases", len(s.aliases), false) {
		for a, i in s.aliases {
			strings.write_string(&b, "    {\"name\": "); q(&b, a.name)
			strings.write_string(&b, ", \"value\": "); q(&b, a.value)
			strings.write_string(&b, "}," if i + 1 < len(s.aliases) else "}")
			strings.write_byte(&b, '\n')
		}
		close(&b, false)
	}
	env_last := len(s.fpath) == 0 && len(s.generators) == 0
	if section(&b, "env", len(s.env), env_last) {
		for e, i in s.env {
			strings.write_string(&b, "    {\"name\": "); q(&b, e.name)
			if e.secret {
				strings.write_string(&b, ", \"secret\": true")
				if e.run_only {
					strings.write_string(&b, ", \"run_only\": true")
				}
			} else {
				strings.write_string(&b, ", \"value\": "); q(&b, e.value)
			}
			strings.write_string(&b, "}," if i + 1 < len(s.env) else "}")
			strings.write_byte(&b, '\n')
		}
		close(&b, env_last)
	}
	// fpath / generators: written only when non-empty (optimize.odin).
	if len(s.fpath) > 0 {
		gen_none := len(s.generators) == 0
		section(&b, "fpath", len(s.fpath), gen_none)
		for f, i in s.fpath {
			strings.write_string(&b, "    "); q(&b, f)
			strings.write_string(&b, "," if i + 1 < len(s.fpath) else "")
			strings.write_byte(&b, '\n')
		}
		close(&b, gen_none)
	}
	if len(s.generators) > 0 {
		section(&b, "generators", len(s.generators), true)
		for g, i in s.generators {
			strings.write_string(&b, "    {\"shell\": "); q(&b, g.shell)
			strings.write_string(&b, ", \"cmd\": "); q(&b, g.cmd)
			strings.write_string(&b, ", \"args\": "); q(&b, g.args)
			strings.write_string(&b, "}," if i + 1 < len(s.generators) else "}")
			strings.write_byte(&b, '\n')
		}
		close(&b, true)
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

// First string of the store that is not valid UTF-8 (JSON text must be), or "".
@(private = "file")
entries_invalid_utf8 :: proc(s: ^EntryStore) -> string {
	for p in s.paths {
		if !utf8.valid_string(p.dir) || !utf8.valid_string(p.key) {
			return p.key
		}
	}
	for a in s.aliases {
		if !utf8.valid_string(a.value) || !utf8.valid_string(a.name) {
			return a.name
		}
	}
	for e in s.env {
		if !utf8.valid_string(e.value) || !utf8.valid_string(e.name) {
			return e.name
		}
	}
	for f in s.fpath {
		if !utf8.valid_string(f) {
			return f
		}
	}
	for g in s.generators {
		if !utf8.valid_string(g.cmd) || !utf8.valid_string(g.args) {
			return g.cmd
		}
	}
	return ""
}

// Persist `s` to entries.json: backup of the current file (once per CLI
// run), atomic replace, mode 0600. Caller holds the config lock and has
// handled --dry-run. Prints the reason and returns false on failure.
entries_save :: proc(s: ^EntryStore) -> bool {
	if bad := entries_invalid_utf8(s); len(bad) > 0 {
		print_error("%q: value is not valid UTF-8; nothing was written", bad)
		return false
	}
	if !os.is_dir(wayu.data) {
		if err := make_directory_all(wayu.data); err != nil {
			print_error("Cannot create %s: %v", wayu.data, err)
			return false
		}
	}
	file := entries_file_path()
	if !create_backup_cli(file) {
		return false
	}
	content := entries_serialize(s)
	defer delete(content)
	if err := write_file_atomic(file, transmute([]byte)content); err != nil {
		print_error("Failed to write %s: %v", file, err)
		return false
	}
	restrict_file_mode(file)
	return true
}

// Index of `name` in the alias / env list, or -1.
entries_find :: proc(s: ^EntryStore, kind: EntryKind, name: string) -> int {
	switch kind {
	case .ALIAS:
		for a, i in s.aliases {
			if a.name == name {
				return i
			}
		}
	case .ENV:
		for e, i in s.env {
			if e.name == name {
				return i
			}
		}
	}
	return -1
}

// Name/value pairs of the alias or env list as ConfigEntry values (owned;
// free with cleanup_entries). Secret constants carry no value here.
entries_as_config_entries :: proc(s: ^EntryStore, kind: EntryKind) -> []ConfigEntry {
	out: [dynamic]ConfigEntry
	switch kind {
	case .ALIAS:
		out = make([dynamic]ConfigEntry, 0, len(s.aliases))
		for a in s.aliases {
			append(
				&out,
				ConfigEntry {
					type = .ALIAS,
					name = strings.clone(a.name),
					value = strings.clone(a.value),
				},
			)
		}
	case .ENV:
		out = make([dynamic]ConfigEntry, 0, len(s.env))
		for e in s.env {
			append(
				&out,
				ConfigEntry {
					type = .CONSTANT,
					name = strings.clone(e.name),
					value = strings.clone(e.value),
				},
			)
		}
	}
	return out[:]
}

StoreEditResult :: enum {
	OK,
	NOT_FOUND, // delete: no such name
	BAD_STORE, // entries.json unreadable / malformed; reason printed, nothing written
	IO_ERROR,
}

@(private = "file")
entries_kind_label :: proc(kind: EntryKind) -> string {
	return "aliases" if kind == .ALIAS else "env"
}

@(private = "file")
print_entries_dry_run :: proc(
	kind: EntryKind,
	removed: []string,
	name := "",
	value := "",
	existed := false,
) {
	// Only the changed names, values masked if secret-looking (OKAMI-208).
	// The TUI sets print_quiet; writing here would draw over its screen.
	if print_quiet do return
	print_header("DRY RUN - No changes will be made", EMOJI_INFO)
	fmt.println()
	fmt.printfln(
		"%sWould update %s (%s):%s",
		BRIGHT_CYAN,
		ENTRIES_FILE,
		entries_kind_label(kind),
		RESET,
	)
	for n in removed {
		fmt.printfln("  %s- %s%s", get_error(), n, RESET)
	}
	if len(removed) == 0 {
		fmt.printfln(
			"  %s%c %s = \"%s\"%s",
			existed ? get_warning() : get_success(),
			existed ? '~' : '+',
			name,
			mask_secret_value(name, value),
			RESET,
		)
	}
	fmt.println()
	fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
}

// Set alias / constant `name` to `value` (new names are appended, existing
// ones keep their position). Honors --dry-run. Caller holds the config lock.
entries_kv_upsert :: proc(
	kind: EntryKind,
	name, value: string,
) -> (
	res: StoreEditResult,
	existed: bool,
) {
	store, err, ok := entries_read()
	if !ok {
		print_error_simple("%s", err)
		return .BAD_STORE, false
	}
	defer entries_store_destroy(&store)

	idx := entries_find(&store, kind, name)
	existed = idx >= 0
	if wayu.dry_run {
		print_entries_dry_run(kind, nil, name, value, existed)
		return .OK, existed
	}
	switch kind {
	case .ALIAS:
		if existed {
			delete(store.aliases[idx].value)
			store.aliases[idx].value = strings.clone(value)
		} else {
			append(&store.aliases, StoreAlias{strings.clone(name), strings.clone(value)})
		}
	case .ENV:
		if existed {
			delete(store.env[idx].value)
			store.env[idx].value = strings.clone(value)
			store.env[idx].secret = false
			store.env[idx].run_only = false
		} else {
			append(&store.env, StoreEnv{name = strings.clone(name), value = strings.clone(value)})
		}
	}
	if !entries_save(&store) {
		return .IO_ERROR, existed
	}
	return .OK, existed
}

// Remove every alias / constant named in `names`. Honors --dry-run. Caller
// holds the config lock.
entries_kv_delete :: proc(kind: EntryKind, names: []string) -> StoreEditResult {
	store, err, ok := entries_read()
	if !ok {
		print_error_simple("%s", err)
		return .BAD_STORE
	}
	defer entries_store_destroy(&store)

	removed := 0
	for n in names {
		idx := entries_find(&store, kind, n)
		if idx < 0 {
			continue
		}
		removed += 1
		switch kind {
		case .ALIAS:
			delete(store.aliases[idx].name); delete(store.aliases[idx].value)
			ordered_remove(&store.aliases, idx)
		case .ENV:
			delete(store.env[idx].name); delete(store.env[idx].value)
			ordered_remove(&store.env, idx)
		}
	}
	if removed == 0 {
		return .NOT_FOUND
	}
	if wayu.dry_run {
		print_entries_dry_run(kind, names)
		return .OK
	}
	if !entries_save(&store) {
		return .IO_ERROR
	}
	return .OK
}

// Upsert one alias/constant under the config lock, then regenerate and
// report. Shared by toml_alias_add + toml_constant_add. `noun` is the
// display word ("Alias"/"Constant"). Errors are heap-owned (see
// exit_with_entry_error for the prefixes that pick the exit code).
entries_entry_upsert :: proc(kind: EntryKind, name, value, noun: string) -> (bool, string) {
	if !config_lock_acquire() {
		return false, strings.clone("I/O error: could not lock wayu config")
	}
	defer config_lock_release()

	res, existed := entries_kv_upsert(kind, name, value)
	switch res {
	case .BAD_STORE:
		return false, strings.clone(ENTRY_ERROR_CONFIG_PREFIX + "nothing was written")
	case .IO_ERROR, .NOT_FOUND:
		return false, fmt.aprintf("I/O error: could not update %s", ENTRIES_FILE)
	case .OK:
	}
	if wayu.dry_run {
		return true, ""
	}

	regenerate_init_core_silently()
	print_success("%s %s: %s", noun, "updated" if existed else "added", name)
	return true, ""
}

// Remove alias/constant `name` under the config lock, then regenerate.
entries_entry_remove :: proc(kind: EntryKind, name, noun: string) -> (bool, string) {
	if !config_lock_acquire() {
		return false, strings.clone("I/O error: could not lock wayu config")
	}
	defer config_lock_release()

	switch entries_kv_delete(kind, {name}) {
	case .NOT_FOUND:
		return false, fmt.aprintf("%s not found: %s", noun, name)
	case .BAD_STORE:
		return false, strings.clone(ENTRY_ERROR_CONFIG_PREFIX + "nothing was written")
	case .IO_ERROR:
		return false, fmt.aprintf("I/O error: could not update %s", ENTRIES_FILE)
	case .OK:
	}
	if wayu.dry_run {
		return true, ""
	}

	regenerate_init_core_silently()
	print_success("%s removed: %s", noun, name)
	return true, ""
}

// Prefix of entry errors that are config errors (malformed entries.json):
// exit_with_entry_error maps them to EXIT_CONFIG. The reason was printed.
ENTRY_ERROR_CONFIG_PREFIX :: "Config error: "
