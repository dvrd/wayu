// test_entries.odin - the entry store <data>/entries.json (OKAMI-192):
// round trip, order, strict reader, file mode.

package test_wayu

import wayu "../../src"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Write `content` as <dir>/entries.json (fixture helper for every suite).
write_entries_json :: proc(t: ^testing.T, dir, content: string, loc := #caller_location) {
	path := fmt.tprintf("%s/%s", dir, wayu.ENTRIES_FILE)
	testing.expect(
		t,
		wayu.safe_write_file(path, transmute([]byte)content),
		"write entries.json",
		loc = loc,
	)
}

// Point wayu.data (and config) at a fresh per-process dir for one test.
@(private = "file")
entries_test_dir :: proc(name: string) -> string {
	dir := test_tmp(name)
	os.remove_all(dir)
	os.make_directory_all(dir)
	return dir
}

@(test)
test_entries_round_trip_keeps_order :: proc(t: ^testing.T) {
	dir := entries_test_dir("entries-round-trip")
	defer os.remove_all(dir)
	saved_config, saved_data := wayu.wayu.config, wayu.wayu.data
	wayu.wayu.config, wayu.wayu.data = dir, dir
	defer {wayu.wayu.config, wayu.wayu.data = saved_config, saved_data}

	store := wayu.EntryStore {
		version = wayu.ENTRIES_FORMAT_VERSION,
	}
	defer wayu.entries_store_destroy(&store)
	// Reverse-alphabetical: declaration order is PATH priority.
	for kv in ([][2]string{{"zz", "/zz"}, {"mm", "/m m"}, {"aa", `/a"a`}}) {
		append(&store.paths, wayu.StorePath{strings.clone(kv[0]), strings.clone(kv[1])})
	}
	for kv in ([][2]string {
			{"zz", "ls"},
			{`q"k`, "echo \"hi\"\n\\x"},
			{"g.st", "git log --format='%h'"},
		}) {
		append(&store.aliases, wayu.StoreAlias{strings.clone(kv[0]), strings.clone(kv[1])})
	}
	append(&store.env, wayu.StoreEnv{strings.clone("EDITOR"), strings.clone("nvim"), false, false})
	append(
		&store.env,
		wayu.StoreEnv{strings.clone("UNI"), strings.clone("café ☕ \x1b[1m"), false, false},
	)
	append(&store.env, wayu.StoreEnv{strings.clone("EMPTY"), strings.clone(""), false, false})

	testing.expect(t, wayu.entries_save(&store))

	path := wayu.entries_file_path()
	fi, serr := os.stat(path, context.temp_allocator)
	testing.expect_value(t, serr, nil)
	testing.expect_value(t, fi.mode, os.perm_number(0o600))

	data, _ := os.read_entire_file(path, context.temp_allocator)
	text := string(data)
	testing.expect(
		t,
		strings.has_prefix(
			text,
			"{\n  \"version\": 1,\n  \"paths\": [\n    {\"key\": \"zz\", \"dir\": \"/zz\"},\n",
		),
		text,
	)
	testing.expect(t, strings.has_suffix(text, "]\n}\n"), "pretty-printed with a trailing newline")

	got, err, ok := wayu.entries_read()
	defer wayu.entries_store_destroy(&got)
	testing.expectf(t, ok, "read back: %s", err)
	testing.expect_value(t, len(got.paths), 3)
	testing.expect_value(t, len(got.aliases), 3)
	testing.expect_value(t, len(got.env), 3)
	if len(got.paths) != 3 || len(got.aliases) != 3 || len(got.env) != 3 {
		return
	}
	for p, i in store.paths {
		testing.expect_value(t, got.paths[i].key, p.key)
		testing.expect_value(t, got.paths[i].dir, p.dir)
	}
	for a, i in store.aliases {
		testing.expect_value(t, got.aliases[i].name, a.name)
		testing.expect_value(t, got.aliases[i].value, a.value)
	}
	for e, i in store.env {
		testing.expect_value(t, got.env[i].name, e.name)
		testing.expect_value(t, got.env[i].value, e.value)
		testing.expect(t, !got.env[i].secret)
	}

	// Serialising the read-back store gives the same bytes (stable output).
	again := wayu.entries_serialize(&got)
	defer delete(again)
	testing.expect_value(t, again, text)
}

@(test)
test_entries_missing_file_is_empty_store :: proc(t: ^testing.T) {
	dir := entries_test_dir("entries-missing")
	defer os.remove_all(dir)
	saved_data := wayu.wayu.data
	wayu.wayu.data = dir
	defer wayu.wayu.data = saved_data

	store, err, ok := wayu.entries_read()
	defer wayu.entries_store_destroy(&store)
	testing.expectf(t, ok, "missing file must read as empty: %s", err)
	testing.expect_value(t, store.version, wayu.ENTRIES_FORMAT_VERSION)
	testing.expect_value(t, len(store.paths) + len(store.aliases) + len(store.env), 0)

	empty := wayu.entries_serialize(&store)
	defer delete(empty)
	testing.expect_value(
		t,
		empty,
		"{\n  \"version\": 1,\n  \"paths\": [],\n  \"aliases\": [],\n  \"env\": []\n}\n",
	)
}

@(test)
test_entries_malformed_is_an_error_naming_the_file :: proc(t: ^testing.T) {
	dir := entries_test_dir("entries-malformed")
	defer os.remove_all(dir)
	saved_data := wayu.wayu.data
	wayu.wayu.data = dir
	defer wayu.wayu.data = saved_data

	cases := []string {
		`{"version": 1, "paths": [`,
		`not json`,
		`{"version": 2, "paths": []}`,
		`{"paths": []}`,
		`{"version": 1, "paths": [{"key": "a", "dir": "/a"}, {"key": "a", "dir": "/b"}]}`,
		`{"version": 1, "paths": [{"key": "", "dir": "/a"}]}`,
		`{"version": 1, "paths": [{"key": "a", "dir": " "}]}`,
		`{"version": 1, "aliases": [{"name": "ll", "value": "a"}, {"name": "ll", "value": "b"}]}`,
		`{"version": 1, "env": [{"name": "", "value": "x"}]}`,
		`{"version": 1, "env": [{"name": "A", "value": "1"}, {"name": "A", "value": "2"}]}`,
		`{"version": 1, "version": 1}`,
		`{"version": 1, "paths": "x"}`,
	}
	for c in cases {
		write_entries_json(t, dir, c)
		store, err, ok := wayu.entries_read()
		wayu.entries_store_destroy(&store)
		testing.expectf(t, !ok, "malformed store accepted: %s", c)
		testing.expectf(
			t,
			strings.contains(err, wayu.ENTRIES_FILE),
			"%s: error %q must name the file",
			c,
			err,
		)
	}
}

@(test)
test_entries_secret_flag_serialized_only_when_true :: proc(t: ^testing.T) {
	store := wayu.EntryStore {
		version = wayu.ENTRIES_FORMAT_VERSION,
	}
	defer wayu.entries_store_destroy(&store)
	append(&store.env, wayu.StoreEnv{strings.clone("PLAIN"), strings.clone("v"), false, false})
	append(
		&store.env,
		wayu.StoreEnv{strings.clone("TOKEN"), strings.clone("fake-not-written"), true, false},
	)
	text := wayu.entries_serialize(&store)
	defer delete(text)
	testing.expect(t, strings.contains(text, `{"name": "PLAIN", "value": "v"}`), text)
	testing.expect(t, strings.contains(text, `{"name": "TOKEN", "secret": true}`), text)
	testing.expect(
		t,
		!strings.contains(text, "fake-not-written"),
		"a secret's value never lands in entries.json",
	)
	testing.expect(t, !strings.contains(text, `"secret": false`), text)

	parsed, err, ok := wayu.entries_parse(text)
	defer wayu.entries_store_destroy(&parsed)
	testing.expectf(t, ok, "parse: %s", err)
	if len(parsed.env) == 2 {
		testing.expect(t, !parsed.env[0].secret)
		testing.expect(t, parsed.env[1].secret)
		testing.expect_value(t, parsed.env[1].value, "")
	}
}

// Many parses (good and bad) leave nothing behind: the test runner fails
// on leaks.
@(test)
test_entries_parse_is_leak_free :: proc(t: ^testing.T) {
	good := `{"version": 1, "paths": [{"key": "a", "dir": "/a"}], "aliases": [{"name": "ll", "value": "ls"}], "env": [{"name": "A", "value": "1"}]}`
	for _ in 0 ..< 50 {
		s, _, ok := wayu.entries_parse(good)
		testing.expect(t, ok)
		wayu.entries_store_destroy(&s)
		bad, _, bok := wayu.entries_parse(
			`{"version": 1, "paths": [{"key": "a", "dir": "/a"}, {"key": "a", "dir": "/b"}]}`,
		)
		testing.expect(t, !bok)
		wayu.entries_store_destroy(&bad)
	}
	free_all(context.temp_allocator)
}

// The rc line `wayu init` adds finds the data dir by itself: XDG default for
// zsh/bash, the same lookup in fish syntax (no ${X:-y} there).
@(test)
test_bootstrap_line_per_shell :: proc(t: ^testing.T) {
	want_zsh := strings.concatenate(
		{`source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}`, `/init.zsh"`},
		context.temp_allocator,
	)
	testing.expect_value(t, wayu.bootstrap_source_line("zsh"), want_zsh)
	testing.expect(t, strings.has_suffix(wayu.bootstrap_source_line("bash"), `/init.bash"`))
	fish := wayu.bootstrap_source_line("fish")
	testing.expect(t, !strings.contains(fish, ":-"), "fish line uses no POSIX expansion")
	testing.expect(
		t,
		strings.contains(fish, "$WAYU_DATA_DIR/init.fish") &&
		strings.contains(fish, "$XDG_DATA_HOME/wayu/init.fish") &&
		strings.contains(fish, "~/.local/share/wayu/init.fish"),
	)
	free_all(context.temp_allocator)
}
