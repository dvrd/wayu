// test_secrets_store.odin - Encrypted secrets (OKAMI-192, Phase 5 C):
// AEAD round trip and failure modes, secrets.json format, the file key
// backend (0600, O_EXCL, unsafe modes refused), the session-cache shell
// quoting, and keychain / secret-service argv construction (those backends
// are never run here). All values are fake.

package test_wayu

import wayu "../../src"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
test_key :: proc(fill: byte) -> (k: [wayu.SECRETS_KEY_SIZE]byte) {
	for &b in k {b = fill}
	return
}

@(test)
test_secrets_seal_open_round_trip :: proc(t: ^testing.T) {
	key := test_key(7)
	values := []string{"fake-value", "", "multi\nline 'q' \"dq\" $HOME `x` \\", "ünïcødé"}
	for v in values {
		blob := wayu.secrets_seal(key, "FAKE_NAME", v)
		defer delete(blob)
		got, ok := wayu.secrets_open(key, "FAKE_NAME", blob)
		testing.expectf(t, ok && got == v, "round trip of %q failed", v)
		wayu.secrets_wipe(got)
	}
	// A fresh nonce per seal: same input, different ciphertext.
	a := wayu.secrets_seal(key, "FAKE_NAME", "same")
	b := wayu.secrets_seal(key, "FAKE_NAME", "same")
	defer {delete(a); delete(b)}
	testing.expect(t, a != b, "nonce must be random per value")
}

@(test)
test_secrets_open_rejects :: proc(t: ^testing.T) {
	key := test_key(1)
	blob := wayu.secrets_seal(key, "FAKE_A", "fake-secret")
	defer delete(blob)

	_, ok := wayu.secrets_open(key, "FAKE_B", blob)
	testing.expect(t, !ok, "a value moved to another name (AAD) must not decrypt")

	_, ok = wayu.secrets_open(test_key(2), "FAKE_A", blob)
	testing.expect(t, !ok, "wrong key must not decrypt")

	tampered := strings.clone(blob)
	defer delete(tampered)
	raw := transmute([]byte)tampered
	raw[20] = 'A' if raw[20] != 'A' else 'B'
	_, ok = wayu.secrets_open(key, "FAKE_A", tampered)
	testing.expect(t, !ok, "tampered ciphertext must not decrypt")

	_, ok = wayu.secrets_open(key, "FAKE_A", "AAAA")
	testing.expect(t, !ok, "short blob")
	_, ok = wayu.secrets_open(key, "FAKE_A", "not base64 !!")
	testing.expect(t, !ok, "bad base64")
}

@(test)
test_secrets_store_format_parse :: proc(t: ^testing.T) {
	s: wayu.Secrets_Store
	append(
		&s.entries,
		wayu.Secret_Entry{name = strings.clone("ZED"), blob = strings.clone("YmxvYg==")},
	)
	append(
		&s.entries,
		wayu.Secret_Entry{name = strings.clone("ALPHA"), blob = strings.clone("eHl6")},
	)
	defer wayu.secrets_store_destroy(&s)
	text := wayu.secrets_store_format(&s)
	defer delete(text)
	testing.expect_value(
		t,
		text,
		"{\n  \"version\": 1,\n  \"cipher\": \"chacha20poly1305\",\n  \"values\": {\n    \"ALPHA\": \"eHl6\",\n    \"ZED\": \"YmxvYg==\"\n  }\n}\n",
	)

	back, err := wayu.secrets_store_parse(text)
	defer wayu.secrets_store_destroy(&back)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(back.entries), 2)
	if len(back.entries) == 2 {
		testing.expect_value(t, back.entries[0].name, "ALPHA")
		testing.expect_value(t, back.entries[1].blob, "YmxvYg==")
	}

	empty: wayu.Secrets_Store
	etext := wayu.secrets_store_format(&empty)
	defer delete(etext)
	testing.expect(t, strings.contains(etext, `"values": {}`))
}

@(test)
test_secrets_store_parse_rejects :: proc(t: ^testing.T) {
	bad := []string {
		"",
		"{not json",
		`{"version": 2, "cipher": "chacha20poly1305", "values": {}}`,
		`{"version": 1, "cipher": "aes", "values": {}}`,
		// OKAMI-322: strict schema.
		`{"version": 1, "cipher": "chacha20poly1305", "values": {}, "extra": 1}`,
		`{"version": 1, "cipher": "chacha20poly1305", "values": {}} {}`,
		`{"version": 1, "cipher": "chacha20poly1305", "values": {}},`,
		`{"version": "1", "cipher": "chacha20poly1305", "values": {}}`,
		`{"version": 1, "cipher": "chacha20poly1305"}`,
		`{"version": 1, "cipher": "chacha20poly1305", "values": []}`,
		`{"version": 1, "cipher": "chacha20poly1305", "values": {"BAD-NAME": "eHl6"}}`,
		`{"version": 1, "cipher": "chacha20poly1305", "values": {"X\u0000run-only": "eHl6"}}`,
		`{"version": 1, "cipher": "chacha20poly1305", "values": {"FAKE_A": 1}}`,
		`{"version": 1, "cipher": "chacha20poly1305", "values": {"FAKE_A": "eHl6"}, "run_only": ["FAKE_B"]}`,
		`{"version": 1, "cipher": "chacha20poly1305", "values": {"FAKE_A": "eHl6"}, "run_only": ["FAKE_A", "FAKE_A"]}`,
		`{"version": 1, "cipher": "chacha20poly1305", "values": {"FAKE_A": "eHl6"}, "run_only": "FAKE_A"}`,
		`[]`,
	}
	for text in bad {
		s, err := wayu.secrets_store_parse(text)
		wayu.secrets_store_destroy(&s)
		testing.expectf(t, len(err) > 0, "should reject %q", text)
	}
}

@(test)
test_keystore_file_backend :: proc(t: ^testing.T) {
	dir := test_tmp("keystore_file")
	os.remove_all(dir)
	defer os.remove_all(dir)
	path := strings.concatenate({dir, "/secret.key"}, context.temp_allocator)

	_, status, _ := wayu.keystore_load_file(path)
	testing.expect_value(t, status, wayu.Key_Status.MISSING)

	key := test_key(0xab)
	hex := wayu.keystore_encode_hex(key)
	ok, msg := wayu.keystore_save_file(path, hex, false)
	testing.expectf(t, ok, "create failed: %s", msg)

	fi, err := os.stat(path, context.temp_allocator)
	testing.expect(t, err == nil && fi.mode & GROUP_OTHER_BITS == {}, "key file must be 0600")

	got, st2, _ := wayu.keystore_load_file(path)
	testing.expect_value(t, st2, wayu.Key_Status.OK)
	testing.expect(t, got == key, "loaded key differs")

	// O_EXCL: never over an existing key unless rekeying.
	ok, msg = wayu.keystore_save_file(path, hex, false)
	testing.expect(t, !ok && strings.contains(msg, "refusing"), "second create must fail")
	ok, _ = wayu.keystore_save_file(path, wayu.keystore_encode_hex(test_key(1)), true)
	testing.expect(t, ok, "replace (rekey) must work")
	got, _, _ = wayu.keystore_load_file(path)
	testing.expect(t, got == test_key(1), "replaced key not loaded")

	// Group/other readable: refused.
	os.chmod(path, {.Read_User, .Write_User, .Read_Group})
	_, st3, msg3 := wayu.keystore_load_file(path)
	testing.expect_value(t, st3, wayu.Key_Status.INVALID)
	testing.expect(t, strings.contains(msg3, "group/other"))

	// Bad content.
	os.chmod(path, {.Read_User, .Write_User})
	_ = os.write_entire_file(path, transmute([]byte)string("nothex\n"))
	_, st4, _ := wayu.keystore_load_file(path)
	testing.expect_value(t, st4, wayu.Key_Status.INVALID)
}

@(test)
test_keystore_hex :: proc(t: ^testing.T) {
	key := test_key(0x0f)
	hex := wayu.keystore_encode_hex(key)
	testing.expect_value(t, len(hex), 64)
	back, ok := wayu.keystore_decode_hex(
		strings.concatenate({"  ", string(hex), "\n"}, context.temp_allocator),
	)
	testing.expect(t, ok && back == key)
	_, ok = wayu.keystore_decode_hex("abcd")
	testing.expect(t, !ok)
}

@(test)
test_keystore_argv :: proc(t: ^testing.T) {
	expect_argv :: proc(t: ^testing.T, got, want: []string) {
		testing.expectf(t, len(got) == len(want), "argv %v != %v", got, want)
		if len(got) != len(want) {
			return
		}
		for w, i in want {testing.expectf(t, got[i] == w, "argv[%d] %q != %q", i, got[i], w)}
	}
	// OKAMI-306: the account is per data dir ("wayu-<id>").
	saved_data := wayu.wayu.data
	defer wayu.wayu.data = saved_data
	wayu.wayu.data = "/fake/home/.local/share/wayu"
	account := wayu.keystore_account()
	testing.expect(
		t,
		strings.has_prefix(account, "wayu-") &&
		strings.has_suffix(account, wayu.secrets_cache_id()) &&
		len(account) == len("wayu-") + 16,
		account,
	)
	label :: "wayu master key (/fake/home/.local/share/wayu)"
	// The key goes on `security -i`'s stdin, never on argv (ps shows argv).
	expect_argv(t, wayu.keychain_store_argv(), {"security", "-i"})
	testing.expect_value(
		t,
		wayu.keychain_store_line("00ff"),
		fmt.tprintf(
			"add-generic-password -U -a \"%s\" -s \"wayu-master-key\" -l \"%s\" -w \"00ff\"\n",
			account,
			label,
		),
	)
	// security's line parser: `"` and `\` escaped inside double quotes; a
	// control character (newline) cannot end the command early.
	testing.expect_value(t, wayu.keychain_quote("a b\"c\\d'e\nf"), "\"a b\\\"c\\\\d'e?f\"")
	expect_argv(
		t,
		wayu.keychain_load_argv(),
		{"security", "find-generic-password", "-a", account, "-s", "wayu-master-key", "-w"},
	)
	// secret-tool reads the key from stdin: it is never on argv.
	expect_argv(
		t,
		wayu.secret_service_store_argv(),
		{"secret-tool", "store", "--label=" + label, "service", "wayu", "account", account},
	)
	expect_argv(
		t,
		wayu.secret_service_load_argv(),
		{"secret-tool", "lookup", "service", "wayu", "account", account},
	)
	// The wayu 6.0 shared items (read once to move the key).
	expect_argv(
		t,
		wayu.keychain_legacy_load_argv(),
		{"security", "find-generic-password", "-a", "wayu", "-s", "wayu-master-key", "-w"},
	)
	expect_argv(
		t,
		wayu.secret_service_legacy_load_argv(),
		{"secret-tool", "lookup", "service", "wayu", "account", "master"},
	)
	testing.expect_value(
		t,
		wayu.keystore_legacy_delete_hint(.KEYCHAIN),
		"security delete-generic-password -a wayu -s wayu-master-key",
	)
	testing.expect_value(
		t,
		wayu.keystore_legacy_delete_hint(.SECRET_SERVICE),
		"secret-tool clear service wayu account master",
	)
	// Another data dir: another account.
	wayu.wayu.data = "/fake/other/wayu"
	testing.expect(t, wayu.keystore_account() != account, "data dirs must not share a key")
}

// The keychain / Secret Service programs come from fixed system paths: a
// `security` / `secret-tool` planted first in PATH (it would receive the
// key) is never used, and the test-only env override is compiled out.
@(test)
test_keystore_binary_ignores_path :: proc(t: ^testing.T) {
	dir := test_tmp("keystore-path")
	os.remove_all(dir)
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	for name in ([]string{"security", "secret-tool"}) {
		p := fmt.tprintf("%s/%s", dir, name)
		_ = os.write_entire_file(p, "#!/bin/sh\nexit 0\n")
		_ = os.chmod(p, {.Read_User, .Write_User, .Execute_User})
	}
	saved_path, _ := os.lookup_env("PATH", context.allocator)
	defer {
		os.set_env("PATH", saved_path)
		delete(saved_path)
	}
	os.set_env("PATH", fmt.tprintf("%s:%s", dir, saved_path))
	os.set_env("WAYU_TEST_SECURITY_BIN", fmt.tprintf("%s/security", dir))
	os.set_env("WAYU_TEST_SECRET_TOOL_BIN", fmt.tprintf("%s/secret-tool", dir))
	defer {
		os.unset_env("WAYU_TEST_SECURITY_BIN")
		os.unset_env("WAYU_TEST_SECRET_TOOL_BIN")
	}

	kc := wayu.keystore_backend_binary(.KEYCHAIN)
	testing.expect(t, kc == "" || kc == wayu.KEYSTORE_SECURITY_BIN, kc)
	when ODIN_OS == .Darwin {
		testing.expect_value(t, kc, wayu.KEYSTORE_SECURITY_BIN)
	}
	ss := wayu.keystore_backend_binary(.SECRET_SERVICE)
	in_system_dir := ss == ""
	for d in wayu.KEYSTORE_SECRET_TOOL_DIRS {
		if ss == fmt.tprintf("%s/secret-tool", d) {
			in_system_dir = true
		}
	}
	testing.expect(t, in_system_dir, ss)
	testing.expect_value(t, wayu.keystore_backend_binary(.FILE), "")
}

@(test)
test_secrets_backend_parse :: proc(t: ^testing.T) {
	for word, b in wayu.SECRETS_BACKEND_NAMES {
		got, ok := wayu.secrets_backend_parse(word)
		testing.expect(t, ok && got == b)
	}
	_, ok := wayu.secrets_backend_parse("vault")
	testing.expect(t, !ok)
	testing.expect_value(t, wayu.secrets_backend_resolve(.FILE), wayu.Secrets_Backend.FILE)
	testing.expect(t, wayu.secrets_backend_resolve(.AUTO) != .AUTO)

	v, found := wayu.toml_secrets_backend_value(
		"[shell]\ntype = \"zsh\"\n\n[secrets]\nbackend = \"file\"\n",
	)
	testing.expect(t, found && v == "file")
	_, found = wayu.toml_secrets_backend_value("[shell]\ntype = \"zsh\"\n")
	testing.expect(t, !found)
}

@(test)
test_secrets_cache_content_quoting :: proc(t: ^testing.T) {
	names := []string{"FAKE_A", "FAKE_B", "bad-name"}
	values := []string{`it's $HOME "q" \n`, "l1\nl2", "x"}
	sh := wayu.secrets_cache_content(.ZSH, names, values)
	defer delete(sh)
	testing.expect(t, strings.contains(sh, `export FAKE_A='it'\''s $HOME "q" \n'`), sh)
	testing.expect(t, strings.contains(sh, "export FAKE_B='l1\nl2'\n"), sh)
	testing.expect(t, !strings.contains(sh, "bad-name"), "invalid names skipped")

	fish := wayu.secrets_cache_content(.FISH, names, values)
	defer delete(fish)
	testing.expect(t, strings.contains(fish, `set -gx FAKE_A 'it\'s $HOME "q" \\n'`), fish)
	testing.expect(t, strings.contains(fish, "set -gx FAKE_B 'l1\nl2'\n"), fish)
}

@(test)
test_secrets_cache_dir_check :: proc(t: ^testing.T) {
	dir := test_tmp("secrets_cache_dir")
	os.remove_all(dir)
	defer os.remove_all(dir)
	ok, msg := wayu.secrets_cache_dir_ensure(dir)
	testing.expectf(t, ok, "ensure failed: %s", msg)
	fi, err := os.stat(dir, context.temp_allocator)
	testing.expect(t, err == nil && fi.mode & GROUP_OTHER_BITS == {}, "cache dir must be 0700")

	os.chmod(dir, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group})
	ok, msg = wayu.secrets_cache_dir_check(dir)
	testing.expect(
		t,
		!ok && strings.contains(msg, "0700"),
		"a group-accessible dir must be refused",
	)
}

@(test)
test_secrets_run_only_storage :: proc(t: ^testing.T) {
	// secrets.json: "run_only" lists the run-only names; parse restores the flag.
	s: wayu.Secrets_Store
	append(
		&s.entries,
		wayu.Secret_Entry {
			name = strings.clone("FAKE_B"),
			blob = strings.clone("eHl6"),
			run_only = true,
		},
	)
	append(
		&s.entries,
		wayu.Secret_Entry{name = strings.clone("FAKE_A"), blob = strings.clone("YWJj")},
	)
	defer wayu.secrets_store_destroy(&s)
	text := wayu.secrets_store_format(&s)
	defer delete(text)
	testing.expect(t, strings.contains(text, "  },\n  \"run_only\": [\"FAKE_B\"]\n}\n"), text)
	back, err := wayu.secrets_store_parse(text)
	defer wayu.secrets_store_destroy(&back)
	testing.expect_value(t, err, "")
	if len(back.entries) == 2 {
		testing.expect(
			t,
			!back.entries[0].run_only && back.entries[1].run_only,
			"run_only flag lost",
		)
	}
	testing.expect_value(t, wayu.secrets_session_count(&back), 1)

	// The flag is bound into the AAD: flipping it fails decryption.
	key := test_key(3)
	blob := wayu.secrets_seal(key, "FAKE_B", "fake-v", run_only = true)
	defer delete(blob)
	_, ok := wayu.secrets_open(key, "FAKE_B", blob)
	testing.expect(t, !ok, "run-only value must not decrypt as a session value")
	v, ok2 := wayu.secrets_open(key, "FAKE_B", blob, run_only = true)
	testing.expect(t, ok2 && v == "fake-v")
	wayu.secrets_wipe(v)
}

@(test)
test_entries_run_only_marker :: proc(t: ^testing.T) {
	text := `{"version": 1, "env": [{"name": "FAKE_A", "secret": true, "run_only": true}, {"name": "FAKE_B", "secret": true}, {"name": "FAKE_C", "value": "x"}]}`
	// run_only without secret is refused by the strict reader (OKAMI-321).
	_, _, lenient := wayu.entries_parse(
		`{"version": 1, "env": [{"name": "FAKE_C", "value": "x", "run_only": true}]}`,
	)
	testing.expect(t, !lenient, "run_only without secret is an error")
	store, err, ok := wayu.entries_parse(text)
	defer wayu.entries_store_destroy(&store)
	testing.expectf(t, ok, "parse failed: %s", err)
	if len(store.env) != 3 {
		return
	}
	testing.expect(t, store.env[0].run_only && !store.env[1].run_only, "run_only read")
	testing.expect(t, !store.env[2].run_only, "a plain constant is not run-only")
	out := wayu.entries_serialize(&store)
	defer delete(out)
	testing.expect(
		t,
		strings.contains(out, `{"name": "FAKE_A", "secret": true, "run_only": true}`),
		out,
	)
	testing.expect(t, strings.contains(out, `{"name": "FAKE_B", "secret": true}`), out)
	testing.expect(t, !strings.contains(out, `"FAKE_C", "value": "x", "run_only"`), out)
}

// OKAMI-296: backups are found whatever escaping wrote them (raw UTF-8 above
// U+00FF, CR as \u000d or \r, raw DEL), so a converted constant's plaintext
// never survives in an entries.json backup.
@(test)
test_entries_text_holds_any_escaping :: proc(t: ^testing.T) {
	plains := []string{"pässwörd€xyz", "fake\rcr", "fake\x7fdel", "fake-𝄞-\"q\"\\"}
	for plain in plains {
		store := wayu.EntryStore {
			version = 1,
		}
		append(
			&store.env,
			wayu.StoreEnv{name = strings.clone("FAKE_A"), value = strings.clone(plain)},
		)
		text := wayu.entries_serialize(&store)
		wayu.entries_store_destroy(&store)
		defer delete(text)
		testing.expectf(
			t,
			wayu.entries_text_holds(text, plain),
			"not found in writer output: %q",
			plain,
		)
		testing.expectf(
			t,
			!wayu.entries_text_holds(text, "fake-other-value"),
			"false hit for %q",
			plain,
		)
	}
	// Other escapings of the same value (\uXXXX for non-ASCII, \r, \u007f).
	testing.expect(
		t,
		wayu.entries_text_holds(
			`{"version": 1, "env": [{"name": "FAKE_A", "value": "pässwörd€xyz"}]}`,
			"pässwörd€xyz",
		),
	)
	testing.expect(
		t,
		wayu.entries_text_holds(
			`{"version": 1, "env": [{"name": "FAKE_A", "value": "fake\r\u007fx"}]}`,
			"fake\r\x7fx",
		),
	)
	// Unparsable text: raw search.
	testing.expect(t, wayu.entries_text_holds(`{"env": [ "pässwörd€xyz"`, "pässwörd€xyz"))
}

// Allocator that counts allocations and every block released (freed, or left
// behind by a resize) while still holding non-zero bytes.
@(private = "file")
Wipe_Check :: struct {
	backing: runtime.Allocator,
	allocs:  int,
	dirty:   int,
}

@(private = "file")
wipe_check_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	w := (^Wipe_Check)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		w.allocs += 1
	case .Free, .Resize, .Resize_Non_Zeroed:
		if old_memory != nil {
			for b in ([^]byte)(old_memory)[:old_size] {
				if b != 0 {
					w.dirty += 1
					break
				}
			}
		}
		if mode != .Free {
			w.allocs += 1
		}
	}
	return w.backing.procedure(w.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// OKAMI-326: buffers holding plaintext never leave an unwiped copy behind.
@(test)
test_secret_buffers_wiped :: proc(t: ^testing.T) {
	check := Wipe_Check {
		backing = context.allocator,
	}
	alloc := runtime.Allocator{wipe_check_proc, &check}

	// stdin buffer: grows several times, every old block wiped.
	{
		context.allocator = alloc
		b: [dynamic]byte
		chunk := [100]byte{}
		for &c in chunk {c = 'x'}
		for _ in 0 ..< 40 {wayu.secret_buf_append(&b, chunk[:])}
		testing.expect_value(t, len(b), 4000)
		wayu.secret_buf_destroy(&b)
	}
	testing.expect_value(t, check.dirty, 0)

	// Session cache text: one exact-size allocation (no regrowth).
	check = {
		backing = context.allocator,
	}
	names := []string{"FAKE_A", "FAKE_B", "bad-name", "FAKE_C"}
	long := strings.repeat("fake-'\\-", 200, context.temp_allocator)
	values := []string{"it's", long, "x", ""}
	for sh in ([]wayu.ShellType{.ZSH, .BASH, .FISH}) {
		check.allocs = 0
		content := wayu.secrets_cache_content(sh, names, values, alloc)
		testing.expectf(
			t,
			check.allocs == 1 && check.dirty == 0,
			"%v: allocs=%d dirty=%d",
			sh,
			check.allocs,
			check.dirty,
		)
		wayu.secrets_wipe(content, alloc)
	}
	testing.expect_value(t, check.dirty, 0)
}

// A private data dir + runtime dir for store tests (no key backend is ever
// asked: the stores below hold only run-only values). Restores on return.
@(private = "file")
Store_Sandbox :: struct {
	data, runtime: string,
	saved_data:    string,
	saved_xdg:     string,
	had_xdg:       bool,
	saved_tmp:     string,
	had_tmp:       bool,
}

@(private = "file")
store_sandbox_enter :: proc(name: string) -> (sb: Store_Sandbox) {
	root := test_tmp(name)
	os.remove_all(root)
	sb.data = strings.concatenate({root, "/data"}, context.temp_allocator)
	sb.runtime = strings.concatenate({root, "/rt"}, context.temp_allocator)
	os.make_directory_all(sb.data)
	os.make_directory_all(sb.runtime)
	sb.saved_data = wayu.wayu.data
	wayu.wayu.data = sb.data
	sb.saved_xdg, sb.had_xdg = os.lookup_env("XDG_RUNTIME_DIR", context.temp_allocator)
	sb.saved_tmp, sb.had_tmp = os.lookup_env("TMPDIR", context.temp_allocator)
	os.set_env("XDG_RUNTIME_DIR", sb.runtime)
	os.set_env("TMPDIR", sb.runtime)
	return
}

@(private = "file")
store_sandbox_leave :: proc(sb: ^Store_Sandbox) {
	wayu.wayu.data = sb.saved_data
	if sb.had_xdg {
		os.set_env("XDG_RUNTIME_DIR", sb.saved_xdg)
	} else {
		os.unset_env("XDG_RUNTIME_DIR")
	}
	if sb.had_tmp {
		os.set_env("TMPDIR", sb.saved_tmp)
	} else {
		os.unset_env("TMPDIR")
	}
	os.remove_all(strings.trim_suffix(sb.data, "/data"))
}

// secrets.json holding `n` run-only entries (fake ciphertext: never opened).
@(private = "file")
write_run_only_store :: proc(n: int) {
	s: wayu.Secrets_Store
	defer wayu.secrets_store_destroy(&s)
	for i in 0 ..< n {
		append(
			&s.entries,
			wayu.Secret_Entry {
				name = strings.clone(fmt.tprintf("FAKE_R%d", i)),
				blob = strings.clone("eHl6"),
				run_only = true,
			},
		)
	}
	text := wayu.secrets_store_format(&s)
	defer delete(text)
	_ = os.write_entire_file(wayu.secrets_store_path(), transmute([]byte)text)
}

@(private = "file")
race_calls: int
@(private = "file")
race_always: bool

// OKAMI-301: a store write between reading secrets.json and writing the
// cache must not leave a cache marked fresh with the old values.
@(test)
test_secrets_cache_write_detects_store_change :: proc(t: ^testing.T) {
	sb := store_sandbox_enter("secrets_cache_race")
	defer store_sandbox_leave(&sb)
	defer wayu.secrets_cache_race_hook = nil

	write_run_only_store(1)
	race_calls = 0
	race_always = false
	wayu.secrets_cache_race_hook = proc() {
		race_calls += 1
		if race_calls == 1 || race_always {
			write_run_only_store(race_calls + 1) // a concurrent `const add`
		}
	}
	path, ok, err := wayu.secrets_cache_write(.ZSH)
	testing.expectf(t, ok, "cache write failed: %s", err)
	testing.expect_value(t, race_calls, 2) // detected, rewritten from the new store
	testing.expect(t, os.exists(path), "cache missing after a clean retry")

	// A store that never settles: error, and no cache left behind.
	race_calls = 0
	race_always = true
	path, ok, err = wayu.secrets_cache_write(.ZSH)
	testing.expect(t, !ok && strings.contains(err, "kept changing"), err)
	testing.expect(t, !os.exists(path), "stale cache left behind")
}
