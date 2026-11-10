// secrets_store.odin - Encrypted secret constants.
//
//   <data>/secrets.json   {"version":1,"cipher":"chacha20poly1305",
//                          "values":{"NAME":"<base64 nonce||ciphertext||tag>"}}
//                         0600, written atomically under the config lock.
//   master key            256-bit, from crypto.rand_bytes; kept by the backend
//                         in keystore.odin, never next to the ciphertext.
//   run-only secrets      listed under "run_only" in secrets.json (and
//                         marked in entries.json): never in the session
//                         cache; only `wayu secrets run NAME -- CMD`
//                         injects them, into CMD's environment.
//   session cache         <runtime>/wayu-<uid>/secrets-<id>.<ext>: the
//                         decrypted values as `export NAME='…'` lines, 0600
//                         in a 0700 dir we own. core.<ext> sources it when it
//                         is newer than secrets.json, else runs
//                         `wayu secrets cache` once (the only fork).
//
// Cipher: ChaCha20-Poly1305 (RFC 8439, core:crypto/chacha20poly1305), a
// random 96-bit nonce per value, AAD = the variable name, plus "\x00run-only"
// for a run-only value: a value moved to another name, or a run-only value
// whose flag was edited away (to get it into the session cache), fails to
// decrypt.
//
// Decrypted values are only ever written to the session cache and printed
// by `wayu const get NAME`; never to core.<ext>, path_sync, turbo exports,
// backups or logs.

package wayu

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"

SECRETS_STORE_FILE :: "secrets.json"
SECRETS_CIPHER :: "chacha20poly1305"
SECRETS_VERSION :: 1

@(private = "file")
SECRETS_NONCE_SIZE :: chacha20poly1305.IV_SIZE
@(private = "file")
SECRETS_TAG_SIZE :: chacha20poly1305.TAG_SIZE

// One encrypted value. `blob` is base64(nonce || ciphertext || tag).
Secret_Entry :: struct {
	name:     string,
	blob:     string,
	run_only: bool, // only `wayu secrets run` injects it
}

// In-memory secrets.json. Entries are kept sorted by name (stable output).
Secrets_Store :: struct {
	entries: [dynamic]Secret_Entry,
}

secrets_store_destroy :: proc(s: ^Secrets_Store) {
	for e in s.entries {
		delete(e.name)
		delete(e.blob)
	}
	delete(s.entries)
	s.entries = nil
}

secrets_store_find :: proc(s: ^Secrets_Store, name: string) -> int {
	for e, i in s.entries {
		if e.name == name {
			return i
		}
	}
	return -1
}

// <data>/secrets.json (temp-allocated).
secrets_store_path :: proc() -> string {
	return fmt.tprintf("%s/%s", wayu.data, SECRETS_STORE_FILE)
}

// ---------------------------------------------------------------------------
// Crypto
// ---------------------------------------------------------------------------

// Fresh random master key.
secrets_new_key :: proc() -> (key: [SECRETS_KEY_SIZE]byte) {
	crypto.rand_bytes(key[:])
	return
}

// Associated data of a value: its name, plus a run-only marker.
@(private = "file")
secrets_aad :: proc(name: string, run_only: bool) -> []byte {
	if !run_only {
		return transmute([]byte)name
	}
	return transmute([]byte)strings.concatenate({name, "\x00run-only"}, context.temp_allocator)
}

// Encrypt `plaintext` for variable `name`. Result: base64 text (allocator).
secrets_seal :: proc(
	key: [SECRETS_KEY_SIZE]byte,
	name, plaintext: string,
	allocator := context.allocator,
	run_only := false,
) -> string {
	k := key
	defer crypto.zero_explicit(&k, size_of(k))
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, k[:])
	defer chacha20poly1305.reset(&ctx)

	buf := make(
		[]byte,
		SECRETS_NONCE_SIZE + len(plaintext) + SECRETS_TAG_SIZE,
		context.temp_allocator,
	)
	nonce := buf[:SECRETS_NONCE_SIZE]
	ct := buf[SECRETS_NONCE_SIZE:SECRETS_NONCE_SIZE + len(plaintext)]
	tag := buf[SECRETS_NONCE_SIZE + len(plaintext):]
	crypto.rand_bytes(nonce)
	chacha20poly1305.seal(
		&ctx,
		ct,
		tag,
		nonce,
		secrets_aad(name, run_only),
		transmute([]byte)plaintext,
	)
	return base64.encode(buf, allocator = allocator)
}

// Decrypt a blob for variable `name`. ok = false on bad base64, a short
// blob, a wrong key, a different name (AAD) or any tampering. The result
// is allocated with `allocator`; wipe it with secrets_wipe when done.
secrets_open :: proc(
	key: [SECRETS_KEY_SIZE]byte,
	name, blob: string,
	allocator := context.allocator,
	run_only := false,
) -> (
	plaintext: string,
	ok: bool,
) {
	raw, err := base64.decode(blob, allocator = context.temp_allocator)
	if err != nil || len(raw) < SECRETS_NONCE_SIZE + SECRETS_TAG_SIZE {
		return "", false
	}
	k := key
	defer crypto.zero_explicit(&k, size_of(k))
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, k[:])
	defer chacha20poly1305.reset(&ctx)

	nonce := raw[:SECRETS_NONCE_SIZE]
	ct := raw[SECRETS_NONCE_SIZE:len(raw) - SECRETS_TAG_SIZE]
	tag := raw[len(raw) - SECRETS_TAG_SIZE:]
	dst := make([]byte, len(ct), allocator)
	if !chacha20poly1305.open(&ctx, dst, nonce, secrets_aad(name, run_only), ct, tag) {
		delete(dst, allocator)
		return "", false
	}
	return string(dst), true
}

// Overwrite then free a decrypted value.
secrets_wipe :: proc(s: string, allocator := context.allocator) {
	if len(s) == 0 {
		return
	}
	crypto.zero_explicit(raw_data(s), len(s))
	delete(s, allocator)
}

// ---------------------------------------------------------------------------
// secrets.json
// ---------------------------------------------------------------------------

// Parse secrets.json text. err (temp-allocated) explains a rejection.
// Strict: one JSON object with exactly the keys secrets_store_format writes
// ("version", "cipher", "values", optional "run_only"), nothing after it;
// every name a shell variable name; every value a string; "run_only" a list
// of distinct names that are in "values".
secrets_store_parse :: proc(text: string) -> (store: Secrets_Store, err: string) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return {}, "out of memory"
	}
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

	p := json.make_parser_from_string(text, .JSON, true, scratch)
	root, perr := json.parse_value(&p)
	if perr != nil {
		return {}, fmt.tprintf("not valid JSON (%v)", perr)
	}
	if p.curr_token.kind != .EOF {
		return {}, "not valid JSON (text after the closing brace)"
	}
	doc, is_obj := root.(json.Object)
	if !is_obj {
		return {}, "not a JSON object"
	}
	for k in doc {
		switch k {
		case "version", "cipher", "values", "run_only":
		case:
			return {}, fmt.tprintf("unknown field %q", k)
		}
	}
	version, v_ok := doc["version"].(json.Integer)
	if !v_ok || version != SECRETS_VERSION {
		return {}, fmt.tprintf(
			"unsupported version %v (expected %d)",
			doc["version"],
			SECRETS_VERSION,
		)
	}
	cipher, c_ok := doc["cipher"].(json.String)
	if !c_ok || cipher != SECRETS_CIPHER {
		return {}, fmt.tprintf(
			"unsupported cipher %v (expected %q)",
			doc["cipher"],
			SECRETS_CIPHER,
		)
	}
	values, vals_ok := doc["values"].(json.Object)
	if !vals_ok {
		return {}, "\"values\" must be an object of name: ciphertext"
	}
	run_only: [dynamic]string
	run_only.allocator = scratch
	if ro, has_ro := doc["run_only"]; has_ro {
		list, l_ok := ro.(json.Array)
		if !l_ok {
			return {}, "\"run_only\" must be a list of names"
		}
		for item in list {
			name, s_ok := item.(json.String)
			if !s_ok {
				return {}, "\"run_only\" must be a list of names"
			}
			if name not_in values {
				return {}, fmt.tprintf("\"run_only\" names %q, which is not in \"values\"", name)
			}
			if slice.contains(run_only[:], name) {
				return {}, fmt.tprintf("\"run_only\" lists %q twice", name)
			}
			append(&run_only, name)
		}
	}
	for name, v in values {
		if !is_shell_var_name(name) {
			return {}, fmt.tprintf("%q is not a valid variable name", name)
		}
		if _, s_ok := v.(json.String); !s_ok {
			return {}, fmt.tprintf("the value of %s is not a string", name)
		}
	}
	store.entries = make([dynamic]Secret_Entry, 0, len(values))
	for name, v in values {
		append(
			&store.entries,
			Secret_Entry {
				name = strings.clone(name),
				blob = strings.clone(v.(json.String)),
				run_only = slice.contains(run_only[:], name),
			},
		)
	}
	slice.sort_by(store.entries[:], proc(a, b: Secret_Entry) -> bool {return a.name < b.name})
	return store, ""
}

// secrets.json text: pretty-printed, names sorted, trailing newline.
secrets_store_format :: proc(s: ^Secrets_Store, allocator := context.allocator) -> string {
	slice.sort_by(s.entries[:], proc(a, b: Secret_Entry) -> bool {return a.name < b.name})
	b := strings.builder_make(allocator)
	fmt.sbprintfln(&b, "%c", '{')
	fmt.sbprintfln(&b, `  "version": %d,`, SECRETS_VERSION)
	fmt.sbprintfln(&b, `  "cipher": "%s",`, SECRETS_CIPHER)
	if len(s.entries) == 0 {
		strings.write_string(&b, "  \"values\": {}\n")
	} else {
		run_only := 0
		for e in s.entries {
			if e.run_only {
				run_only += 1
			}
		}
		strings.write_string(&b, "  \"values\": {\n")
		for e, i in s.entries {
			strings.write_string(&b, "    \"")
			n := json_escape(e.name); strings.write_string(&b, n); delete(n)
			strings.write_string(&b, "\": \"")
			v := json_escape(e.blob); strings.write_string(&b, v); delete(v)
			strings.write_string(&b, "\",\n" if i + 1 < len(s.entries) else "\"\n")
		}
		strings.write_string(&b, "  },\n" if run_only > 0 else "  }\n")
		if run_only > 0 {
			strings.write_string(&b, "  \"run_only\": [")
			k := 0
			for e in s.entries {
				if !e.run_only {
					continue
				}
				n := json_escape(e.name); fmt.sbprintf(&b, "%s\"%s\"", ", " if k > 0 else "", n)
				delete(n)
				k += 1
			}
			strings.write_string(&b, "]\n")
		}
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

// Read <data>/secrets.json. A missing file is an empty store; an unreadable
// or malformed one is an error (never treated as empty).
secrets_store_load :: proc() -> (store: Secrets_Store, exists: bool, err: string) {
	path := secrets_store_path()
	if !os.exists(path) {
		return {}, false, ""
	}
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		return {}, true, fmt.tprintf("cannot read %s: %v", path, rerr)
	}
	defer delete(data)
	s, perr := secrets_store_parse(string(data))
	if len(perr) > 0 {
		return {}, true, fmt.tprintf("%s: %s", path, perr)
	}
	return s, true, ""
}

// secrets_store_load, exiting EXIT_CONFIG on a malformed store.
secrets_store_load_or_exit :: proc() -> (store: Secrets_Store, exists: bool) {
	s, ex, err := secrets_store_load()
	if len(err) > 0 {
		print_error_simple("%s", err)
		wayu_exit(EXIT_CONFIG)
	}
	return s, ex
}

// Write the store (caller holds the config lock), then drop the session
// cache so no shell sources values older than the store.
secrets_store_save :: proc(s: ^Secrets_Store) -> (ok: bool, err: string) {
	text := secrets_store_format(s)
	defer delete(text)
	path := secrets_store_path()
	if !os.exists(wayu.data) {
		if e := os.make_directory_all(wayu.data); e != nil {
			return false, fmt.tprintf("I/O error: cannot create %s: %v", wayu.data, e)
		}
	}
	if e := write_file_atomic(path, transmute([]byte)text); e != nil {
		return false, fmt.tprintf("I/O error: cannot write %s: %v", path, e)
	}
	restrict_file_mode(path)
	secrets_cache_invalidate()
	return true, ""
}

// Names in the store (sorted, temp-allocated). Empty on a missing or
// malformed store: callers that must report errors load the store.
secrets_names :: proc() -> []string {
	s, _, err := secrets_store_load()
	if len(err) > 0 {
		return {}
	}
	defer secrets_store_destroy(&s)
	names := make([]string, len(s.entries), context.temp_allocator)
	for e, i in s.entries {names[i] = strings.clone(e.name, context.temp_allocator)}
	return names
}

// Is `name` stored as a secret? (Malformed store: false.)
secrets_has :: proc(name: string) -> bool {
	for n in secrets_names() {
		if n == name {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Master key for a store operation
// ---------------------------------------------------------------------------

// Key to decrypt existing values. Every failure is an error.
secrets_key_for_read :: proc() -> (key: [SECRETS_KEY_SIZE]byte, ok: bool, err: string) {
	backend := secrets_backend_active()
	k, status, msg := keystore_load(backend)
	switch status {
	case .OK:
		return k, true, ""
	case .MISSING:
		return key, false, fmt.tprintf(
			"the master key is missing (%s); secrets.json cannot be decrypted without it",
			msg,
		)
	case .UNAVAILABLE:
		return key, false, msg
	case .INVALID:
		return key, false, msg
	}
	return key, false, msg
}

// Key to encrypt a new value. A key is created only when the backend
// reports none AND the store holds no ciphertext (never over existing
// secrets, which would make them undecryptable).
secrets_key_for_write :: proc(
	store_has_values: bool,
) -> (
	key: [SECRETS_KEY_SIZE]byte,
	ok: bool,
	err: string,
) {
	backend := secrets_backend_active()
	k, status, msg := keystore_load(backend)
	switch status {
	case .OK:
		return k, true, ""
	case .MISSING:
		if store_has_values {
			return key, false, fmt.tprintf(
				"the master key is missing (%s) but %s holds encrypted values: refusing to create a new key over them",
				msg,
				secrets_store_path(),
			)
		}
		nk := secrets_new_key()
		if saved, serr := keystore_save(backend, nk, false); !saved {
			crypto.zero_explicit(&nk, size_of(nk))
			return key, false, serr
		}
		return nk, true, ""
	case .UNAVAILABLE, .INVALID:
		return key, false, msg
	}
	return key, false, msg
}

// ---------------------------------------------------------------------------
// Store operations (used by `wayu const` and `wayu secrets`)
// ---------------------------------------------------------------------------

// Encrypt and store `value` under `name`. Caller holds the config lock and
// has handled --dry-run. existed = the name was already a secret.
secrets_set :: proc(
	name, value: string,
	run_only := false,
) -> (
	existed: bool,
	ok: bool,
	err: string,
) {
	s, _, lerr := secrets_store_load()
	if len(lerr) > 0 {
		return false, false, lerr
	}
	defer secrets_store_destroy(&s)

	key, kok, kerr := secrets_key_for_write(len(s.entries) > 0)
	if !kok {
		return false, false, kerr
	}
	defer crypto.zero_explicit(&key, size_of(key))

	blob := secrets_seal(key, name, value, run_only = run_only)
	if i := secrets_store_find(&s, name); i >= 0 {
		delete(s.entries[i].blob)
		s.entries[i].blob = blob
		s.entries[i].run_only = run_only
		existed = true
	} else {
		append(
			&s.entries,
			Secret_Entry{name = strings.clone(name), blob = blob, run_only = run_only},
		)
	}
	sok, serr := secrets_store_save(&s)
	return existed, sok, serr
}

// Remove `name`. removed = false when it was not a secret. Caller holds
// the config lock and has handled --dry-run. Needs no key.
secrets_remove :: proc(name: string) -> (removed: bool, ok: bool, err: string) {
	s, exists, lerr := secrets_store_load()
	if len(lerr) > 0 {
		return false, false, lerr
	}
	defer secrets_store_destroy(&s)
	if !exists {
		return false, true, ""
	}
	i := secrets_store_find(&s, name)
	if i < 0 {
		return false, true, ""
	}
	delete(s.entries[i].name)
	delete(s.entries[i].blob)
	ordered_remove(&s.entries, i)
	sok, serr := secrets_store_save(&s)
	return true, sok, serr
}

// Decrypt one value (allocator; wipe with secrets_wipe).
secrets_get :: proc(
	name: string,
	allocator := context.allocator,
) -> (
	value: string,
	found: bool,
	ok: bool,
	err: string,
) {
	s, _, lerr := secrets_store_load()
	if len(lerr) > 0 {
		return "", false, false, lerr
	}
	defer secrets_store_destroy(&s)
	i := secrets_store_find(&s, name)
	if i < 0 {
		return "", false, true, ""
	}
	key, kok, kerr := secrets_key_for_read()
	if !kok {
		return "", true, false, kerr
	}
	defer crypto.zero_explicit(&key, size_of(key))
	v, dok := secrets_open(key, name, s.entries[i].blob, allocator, s.entries[i].run_only)
	if !dok {
		return "", true, false, fmt.tprintf(
			"%s does not decrypt with the current master key (wrong key or tampered store)",
			name,
		)
	}
	return v, true, true, ""
}

// ---------------------------------------------------------------------------
// Session cache
// ---------------------------------------------------------------------------

// `${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}` with one trailing '/' removed — the
// same expression core.<ext> evaluates (temp-allocated).
secrets_runtime_base :: proc() -> string {
	base := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if len(base) == 0 {
		base = os.get_env("TMPDIR", context.temp_allocator)
	}
	if len(base) == 0 {
		base = "/tmp"
	}
	if len(base) > 1 && strings.has_suffix(base, "/") {
		base = base[:len(base) - 1]
	}
	return base
}

// Per-data-dir id in the cache name: two wayu data dirs (e.g. a test
// HOME) never share a cache. Baked into core.<ext> at build time.
secrets_cache_id :: proc() -> string {
	return fmt.tprintf("%016x", hash.fnv64a(transmute([]byte)wayu.data))
}

// <runtime>/wayu-<uid> (temp-allocated).
secrets_cache_dir :: proc() -> string {
	return fmt.tprintf("%s/wayu-%d", secrets_runtime_base(), posix.getuid())
}

// <runtime>/wayu-<uid>/secrets-<id>.<ext> (temp-allocated).
secrets_cache_path :: proc(shell: ShellType) -> string {
	return fmt.tprintf(
		"%s/secrets-%s.%s",
		secrets_cache_dir(),
		secrets_cache_id(),
		get_shell_extension(shell),
	)
}

// Create (0700) or verify the cache dir: a real directory (not a symlink),
// owned by us, no group/other permissions. Anything else is refused.
secrets_cache_dir_ensure :: proc(dir: string) -> (ok: bool, err: string) {
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	if posix.mkdir(cdir, posix.S_IRWXU) != .OK && posix.errno() != .EEXIST {
		return false, fmt.tprintf("cannot create %s: %s", dir, posix.strerror(posix.errno()))
	}
	return secrets_cache_dir_check(dir)
}

// Verify an existing cache dir (see secrets_cache_dir_ensure).
secrets_cache_dir_check :: proc(dir: string) -> (ok: bool, err: string) {
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	st: posix.stat_t
	if posix.lstat(cdir, &st) != .OK {
		return false, fmt.tprintf("cannot stat %s: %s", dir, posix.strerror(posix.errno()))
	}
	if !posix.S_ISDIR(st.st_mode) {
		return false, fmt.tprintf("%s is not a directory", dir)
	}
	if st.st_uid != posix.getuid() {
		return false, fmt.tprintf("%s is owned by another user", dir)
	}
	if st.st_mode & (posix.S_IRWXG | posix.S_IRWXO) != {} {
		return false, fmt.tprintf("%s is accessible by group/other (expected mode 0700)", dir)
	}
	return true, ""
}

// Shell code of the cache: one export per value, single-quoted (literal:
// no expansion of `$`, backticks or `\`). Invalid names are skipped.
secrets_cache_content :: proc(
	shell: ShellType,
	names, values: []string,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(
		&b,
		"# wayu secrets session cache - generated by `wayu secrets cache`; do not edit.\n",
	)
	for name, i in names {
		if !is_shell_var_name(name) {
			continue
		}
		if shell == .FISH {
			q := escape_fish_string(values[i], context.temp_allocator)
			fmt.sbprintfln(&b, "set -gx %s %s", name, q)
			crypto.zero_explicit(raw_data(q), len(q))
		} else {
			q := shell_single_quote(values[i], context.temp_allocator)
			fmt.sbprintfln(&b, "export %s=%s", name, q)
			crypto.zero_explicit(raw_data(q), len(q))
		}
	}
	return strings.to_string(b)
}

// Remove every shell's cache for this data dir (store changed, rekey, lock).
secrets_cache_invalidate :: proc() -> (removed: int) {
	for sh in ([]ShellType{.ZSH, .BASH, .FISH}) {
		p := secrets_cache_path(sh)
		if os.exists(p) && os.remove(p) == nil {
			removed += 1
		}
	}
	return
}

// Decrypt everything and write the cache for `shell`. The cache's mtime is
// pushed past secrets.json's whole second, so core's `-nt` test (whole
// seconds in some shells) sees it as newer.
secrets_cache_write :: proc(shell: ShellType) -> (path: string, ok: bool, err: string) {
	s, exists, lerr := secrets_store_load()
	if len(lerr) > 0 {
		return "", false, lerr
	}
	defer secrets_store_destroy(&s)
	path = secrets_cache_path(shell)
	if !exists {
		return path, false, fmt.tprintf(
			"no secrets stored (%s does not exist)",
			secrets_store_path(),
		)
	}

	// Run-only values are never decrypted here: they never reach the cache.
	names := make([dynamic]string, 0, len(s.entries), context.temp_allocator)
	values := make([dynamic]string, 0, len(s.entries), context.temp_allocator)
	defer for v in values {secrets_wipe(v)}
	if secrets_session_count(&s) > 0 {
		key, kok, kerr := secrets_key_for_read()
		if !kok {
			return path, false, kerr
		}
		defer crypto.zero_explicit(&key, size_of(key))
		for e in s.entries {
			if e.run_only {
				continue
			}
			v, dok := secrets_open(key, e.name, e.blob)
			if !dok {
				return path, false, fmt.tprintf(
					"%s does not decrypt with the current master key (wrong key or tampered store)",
					e.name,
				)
			}
			append(&names, e.name)
			append(&values, v)
		}
	}

	dir := secrets_cache_dir()
	if dok, derr := secrets_cache_dir_ensure(dir); !dok {
		return path, false, derr
	}
	content := secrets_cache_content(shell, names[:], values[:])
	defer secrets_wipe(content)
	if werr := write_file_atomic(path, transmute([]byte)content); werr != nil {
		return path, false, fmt.tprintf("cannot write %s: %v", path, werr)
	}
	restrict_file_mode(path)

	mtime := time.now()
	if fi, serr := os.stat(secrets_store_path(), context.temp_allocator); serr == nil {
		after := time.from_nanoseconds(
			(time.to_unix_nanoseconds(fi.modification_time) / 1e9 + 1) * 1e9,
		)
		if time.diff(mtime, after) > 0 {
			mtime = after
		}
	}
	_ = os.chtimes(path, mtime, mtime)
	return path, true, ""
}

// ---------------------------------------------------------------------------
// core.<ext> / turbo: source the cache, regenerate it when stale
// ---------------------------------------------------------------------------

// Values the session cache exports (all but run-only ones).
secrets_session_count :: proc(s: ^Secrets_Store) -> (n: int) {
	for e in s.entries {
		if !e.run_only {
			n += 1
		}
	}
	return
}

// Does the store hold any value the shell exports? (Decides whether core
// gets the loader; a store of only run-only secrets needs none.)
secrets_store_nonempty :: proc() -> bool {
	s, _, err := secrets_store_load()
	if len(err) > 0 {
		return false
	}
	defer secrets_store_destroy(&s)
	return secrets_session_count(&s) > 0
}

// The Secrets section of core.<ext> (and of `wayu export --eval`, with
// sep = ";"): no fork when the cache is current (`-O` and `-nt` are
// builtins); otherwise one `wayu secrets cache`, which prints a single
// warning and exits non-zero when it can't decrypt — startup continues
// without the secrets. Nothing when no secret exists. zsh/bash statements
// are one per line so they also survive `eval $(...)` joined by `;`.
emit_secrets_loader :: proc(b: ^strings.Builder, shell: ShellType, sep := "\n") {
	if !secrets_store_nonempty() {
		return
	}
	ext := get_shell_extension(shell)
	tail := fmt.tprintf("/wayu-%d/secrets-%s.%s", posix.getuid(), secrets_cache_id(), ext)
	store := secrets_store_path()
	bin := wayu_self_path()
	if len(bin) == 0 {
		bin = "wayu"
	}

	if shell == .FISH {
		qstore := escape_fish_string(store, context.temp_allocator)
		fmt.sbprintln(b, "# === Secrets (encrypted store, per-session cache) ===")
		fmt.sbprintln(b, "set -l _wayu_sc /tmp")
		fmt.sbprintln(
			b,
			`if test -n "$XDG_RUNTIME_DIR"; set _wayu_sc $XDG_RUNTIME_DIR; else if test -n "$TMPDIR"; set _wayu_sc $TMPDIR; end`,
		)
		fmt.sbprintfln(
			b,
			"set _wayu_sc (string replace -r '(.)/$' '$1' -- $_wayu_sc)%s",
			escape_fish_string(tail, context.temp_allocator),
		)
		fmt.sbprintfln(b, "if not test -O $_wayu_sc; or not test $_wayu_sc -nt %s", qstore)
		fmt.sbprintfln(
			b,
			"    command %s secrets cache --shell fish </dev/null >/dev/null",
			escape_fish_string(bin, context.temp_allocator),
		)
		fmt.sbprintln(b, "end")
		fmt.sbprintfln(
			b,
			"if test -O $_wayu_sc; and test $_wayu_sc -nt %s; source $_wayu_sc; end",
			qstore,
		)
		fmt.sbprintln(b, "set -e _wayu_sc")
		fmt.sbprintln(b)
		return
	}

	qstore := shell_single_quote(store, context.temp_allocator)
	fresh := fmt.tprintf(`[ -O "$_wayu_sc" ] && [ "$_wayu_sc" -nt %s ]`, qstore)
	lines := [?]string {
		`_wayu_sc=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}`,
		`[ "$_wayu_sc" = / ] || _wayu_sc=${_wayu_sc%/}`,
		fmt.tprintf(`_wayu_sc="$_wayu_sc"%s`, shell_single_quote(tail, context.temp_allocator)),
		// `{` opens a struct verb in Odin's fmt: emit it via %c.
		fmt.tprintf(
			"%c %s; } || command %s secrets cache --shell %s </dev/null >/dev/null",
			'{',
			fresh,
			shell_single_quote(bin, context.temp_allocator),
			ext,
		),
		fmt.tprintf(`if %s; then source "$_wayu_sc"; fi`, fresh),
		"unset _wayu_sc",
	}
	if sep == "\n" {
		fmt.sbprintln(b, "# === Secrets (encrypted store, per-session cache) ===")
	}
	for line in lines {
		strings.write_string(b, line)
		strings.write_string(b, sep)
	}
	if sep == "\n" {
		fmt.sbprintln(b)
	}
}

// ---------------------------------------------------------------------------
// Env-store seam
// ---------------------------------------------------------------------------
//
// The ONLY place the secrets code writes the env store (<data>/entries.json,
// entries.odin). A secret constant is an env entry {"name", "secret": true}
// with no value, at the position it was added (or the plain entry it
// replaced); its ciphertext is in secrets.json. Both procs run under the
// config lock, after --dry-run was handled, and do not regenerate core
// (callers do).

// Record that `name` is a secret constant: an existing entry keeps its
// position and loses its plaintext value, else a marker is appended.
// `run_only` is recorded too ({"name", "secret": true, "run_only": true}).
// converted = a plain value was there (the add converted it).
env_store_mark_secret :: proc(
	name: string,
	run_only := false,
) -> (
	converted: bool,
	ok: bool,
	err: string,
) {
	store, rerr, rok := entries_read()
	if !rok {
		return false, false, rerr
	}
	defer entries_store_destroy(&store)
	plain: string // the plaintext value being converted (owned; wiped below)
	defer if len(plain) > 0 {
		crypto.zero_explicit(raw_data(plain), len(plain))
		delete(plain)
	}
	if i := entries_find(&store, .ENV, name); i >= 0 {
		e := &store.env[i]
		converted = !e.secret
		plain = e.value
		e.value = ""
		e.secret = true
		e.run_only = run_only
	} else {
		append(
			&store.env,
			StoreEnv{name = strings.clone(name), secret = true, run_only = run_only},
		)
	}
	if !entries_save(&store) {
		return converted, false, fmt.tprintf("I/O error: could not update %s", ENTRIES_FILE)
	}
	if len(plain) > 0 {
		scrub_entries_backups(plain)
	}
	return converted, true, ""
}

// Delete every entries.json backup that still holds `plain` (as its JSON
// string form): converting a constant to a secret must not leave its
// plaintext behind in the backups taken before the conversion.
@(private = "file")
scrub_entries_backups :: proc(plain: string) {
	needle, merr := json.marshal(plain)
	if merr != nil {
		return
	}
	defer {
		crypto.zero_explicit(raw_data(needle), len(needle))
		delete(needle)
	}
	backups := list_backups_for_file(entries_file_path())
	defer free_backup_infos(backups)
	for b in backups {
		data, rerr := os.read_entire_file(b.backup_file, context.allocator)
		if rerr != nil {
			continue
		}
		hit := strings.contains(string(data), string(needle))
		crypto.zero_explicit(raw_data(data), len(data))
		delete(data)
		if hit {
			os.remove(b.backup_file)
		}
	}
}

// Forget that `name` is a secret constant (const remove): delete its entry.
env_store_unmark_secret :: proc(name: string) -> (ok: bool, err: string) {
	#partial switch entries_kv_delete(.ENV, {name}) {
	case .BAD_STORE:
		return false, ENTRY_ERROR_CONFIG_PREFIX + "nothing was written"
	case .IO_ERROR:
		return false, fmt.tprintf("I/O error: could not update %s", ENTRIES_FILE)
	}
	return true, ""
}

// ---------------------------------------------------------------------------
// `wayu const add --secret`, get, remove
// ---------------------------------------------------------------------------

// Read a secret value from stdin: no echo on a terminal, else all of stdin
// (one trailing newline removed). Caller wipes the result.
@(private = "file")
read_secret_value :: proc(name: string) -> (value: string, ok: bool) {
	tty := bool(posix.isatty(posix.STDIN_FILENO))
	saved: posix.termios
	if tty {
		fmt.eprintf("Value for %s (input hidden): ", name)
		if posix.tcgetattr(posix.STDIN_FILENO, &saved) == .OK {
			quiet := saved
			quiet.c_lflag -= {.ECHO}
			posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &quiet)
		}
	}
	b := strings.builder_make()
	buf: [512]byte
	for {
		n := posix.read(posix.STDIN_FILENO, raw_data(buf[:]), len(buf))
		if n <= 0 {
			break
		}
		strings.write_bytes(&b, buf[:n])
		if tty && strings.contains_rune(strings.to_string(b), '\n') {
			break
		}
	}
	crypto.zero_explicit(&buf, size_of(buf))
	if tty {
		posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &saved)
		fmt.eprintln()
	}
	s := strings.to_string(b)
	if tty {
		if i := strings.index_byte(s, '\n'); i >= 0 {
			s = s[:i]
		}
	} else {
		s = strings.trim_suffix(s, "\n")
	}
	s = strings.trim_suffix(s, "\r")
	value = strings.clone(s)
	crypto.zero_explicit(raw_data(b.buf), len(b.buf))
	strings.builder_destroy(&b)
	return value, len(value) > 0
}

// `wayu const add NAME [VALUE] --secret`. Without VALUE it is read from
// stdin (hidden on a terminal), so it stays out of argv and history.
const_add_secret :: proc(args: []string) {
	if len(args) == 0 {
		print_cli_usage_error(&CONSTANTS_SPEC, "add")
		wayu_exit(EXIT_USAGE)
	}
	name := args[0]
	value: string
	owned := false
	if len(args) >= 2 {
		value = strings.join(args[1:], " ")
		owned = true
	} else if !wayu.dry_run {
		v, ok := read_secret_value(name)
		if !ok {
			print_error_simple("No value for secret %s (pass VALUE or pipe it on stdin)", name)
			wayu_exit(EXIT_USAGE)
		}
		value = v
		owned = true
	}
	defer if owned {
		secrets_wipe(value)
	}

	v := validate_constant(name, value if len(value) > 0 else "x")
	if len(v.warning) > 0 {
		delete(v.warning)
	}
	if !v.valid {
		print_error_simple("%s", v.error_message)
		delete(v.error_message)
		wayu_exit(EXIT_DATAERR)
	}

	if wayu.dry_run {
		print_info(
			"[dry-run] Would store %s %s encrypted in %s (value not shown)",
			"run-only secret" if wayu.run_only_flag else "secret",
			name,
			secrets_store_path(),
		)
		return
	}

	hook_pre_constant_add(name, "") // hooks never see a secret value
	{
		config_lock_acquire_or_exit()
		defer config_lock_release()
		run_only := wayu.run_only_flag
		existed, ok, err := secrets_set(name, value, run_only)
		if !ok {
			exit_with_secret_error(err)
		}
		converted, mok, merr := env_store_mark_secret(name, run_only)
		if !mok {
			exit_with_entry_error(strings.clone(merr))
		}
		regenerate_init_core_silently()
		mode := " (run-only: wayu secrets run)" if run_only else ""
		switch {
		case converted:
			print_success("Constant converted to an encrypted secret%s: %s", mode, name)
		case existed:
			print_success("Secret updated%s: %s", mode, name)
		case:
			print_success("Secret added (encrypted)%s: %s", mode, name)
		}
	}
	hook_post_constant_add(name, "")
}

// Print a store/key error and exit: I/O → EXIT_IOERR, else EXIT_CONFIG.
exit_with_secret_error :: proc(err: string) -> ! {
	print_error_simple("%s", err)
	wayu_exit(EXIT_IOERR if strings.has_prefix(err, "I/O error") else EXIT_CONFIG)
}

// `wayu const get NAME` for a secret: decrypt and print. Returns false
// when NAME is not a secret (the caller looks in the plain store).
const_get_secret :: proc(name: string) -> bool {
	if !secrets_store_has_name_or_exit(name) {
		return false
	}
	value, _, ok, err := secrets_get(name)
	if !ok {
		exit_with_secret_error(err)
	}
	defer secrets_wipe(value)
	fmt.println(value)
	return true
}

// Remove a secret constant. Returns false when NAME is not a secret.
// Caller holds the config lock and handled --dry-run.
const_remove_secret :: proc(name: string) -> bool {
	removed, ok, err := secrets_remove(name)
	if !ok {
		exit_with_secret_error(err)
	}
	if !removed {
		return false
	}
	if uok, uerr := env_store_unmark_secret(name); !uok {
		exit_with_entry_error(strings.clone(uerr))
	}
	return true
}

// Is NAME a secret? Exits EXIT_CONFIG on a malformed store.
secrets_store_has_name_or_exit :: proc(name: string) -> bool {
	s, _ := secrets_store_load_or_exit()
	defer secrets_store_destroy(&s)
	return secrets_store_find(&s, name) >= 0
}

// ---------------------------------------------------------------------------
// `wayu secrets`
// ---------------------------------------------------------------------------

handle_secrets_command :: proc(action: Action, args: []string) {
	#partial switch action {
	case .LIST:
		s, _ := secrets_store_load_or_exit()
		defer secrets_store_destroy(&s)
		if len(s.entries) == 0 {
			print_info("No secrets (add one with: wayu const add NAME --secret)")
			return
		}
		width := 0
		for e in s.entries {width = max(width, len(e.name))}
		for e in s.entries {fmt.printfln("%-*s  %s", width, e.name, "run-only" if e.run_only else "session")}
	case .UPDATE:
		secrets_rekey()
	case .CLEAN:
		if wayu.dry_run {
			print_info(
				"[dry-run] Would delete the secrets session cache in %s",
				secrets_cache_dir(),
			)
			return
		}
		n := secrets_cache_invalidate()
		if n > 0 {
			print_success("Session cache deleted; new shells decrypt the store again")
		} else {
			print_info("No session cache to delete")
		}
	case .TURBO:
		secrets_cache_command()
	case .RUN:
		secrets_run_command(args)
	case .HELP:
		print_secrets_help()
	case:
		print_error_simple("Unknown secrets action")
		print_secrets_help()
		wayu_exit(EXIT_USAGE)
	}
}

// Hidden `wayu secrets cache [--shell sh]`, run by core.<ext>. On failure
// prints exactly one warning to stderr and exits EXIT_CONFIG; the shell
// starts without the secrets.
@(private = "file")
secrets_cache_command :: proc() {
	if wayu.dry_run {
		print_info("[dry-run] Would write %s", secrets_cache_path(wayu.shell))
		return
	}
	path, ok, err := secrets_cache_write(wayu.shell)
	if !ok {
		if len(path) > 0 && os.exists(path) {
			os.remove(path)
		}
		fmt.eprintfln("wayu: secrets not loaded: %s", err)
		wayu_exit(EXIT_CONFIG)
	}
}

// New master key; every value re-encrypted; caches dropped.
@(private = "file")
secrets_rekey :: proc() {
	config_lock_acquire_or_exit()
	defer config_lock_release()

	s, exists := secrets_store_load_or_exit()
	defer secrets_store_destroy(&s)
	backend := secrets_backend_active()

	if wayu.dry_run {
		print_info(
			"[dry-run] Would create a new master key (%s) and re-encrypt %d secret(s)",
			SECRETS_BACKEND_NAMES[backend],
			len(s.entries),
		)
		return
	}
	if !exists || len(s.entries) == 0 {
		print_info("No secrets to re-encrypt")
		return
	}

	old_key, kok, kerr := secrets_key_for_read()
	if !kok {
		exit_with_secret_error(kerr)
	}
	defer crypto.zero_explicit(&old_key, size_of(old_key))

	new_key := secrets_new_key()
	defer crypto.zero_explicit(&new_key, size_of(new_key))

	new_blobs := make([]string, len(s.entries))
	defer delete(new_blobs)
	for e, i in s.entries {
		v, dok := secrets_open(old_key, e.name, e.blob, run_only = e.run_only)
		if !dok {
			for b in new_blobs[:i] {delete(b)}
			exit_with_secret_error(
				fmt.tprintf(
					"%s does not decrypt with the current master key: nothing was changed",
					e.name,
				),
			)
		}
		new_blobs[i] = secrets_seal(new_key, e.name, v, run_only = e.run_only)
		secrets_wipe(v)
	}

	if saved, serr := keystore_save(backend, new_key, true); !saved {
		for b in new_blobs {delete(b)}
		exit_with_secret_error(serr)
	}
	for &e, i in s.entries {
		delete(e.blob)
		e.blob = new_blobs[i]
	}
	if sok, serr := secrets_store_save(&s); !sok {
		// Put the old key back so the unchanged store stays readable.
		_, _ = keystore_save(backend, old_key, true)
		exit_with_secret_error(serr)
	}
	print_success(
		"Re-encrypted %d secret(s) with a new master key (%s)",
		len(s.entries),
		SECRETS_BACKEND_NAMES[backend],
	)
}

print_secrets_help :: proc() {
	print_header("Secrets", "🔐")
	fmt.println()
	fmt.println("Constants whose values are stored encrypted (ChaCha20-Poly1305) in")
	fmt.println("<data>/secrets.json. The master key lives in the [secrets] backend.")
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_secondary(), RESET)
	fmt.println(
		"  wayu const add NAME [VALUE] --secret   Store an encrypted constant (VALUE from stdin if omitted)",
	)
	fmt.println("  wayu const get NAME                    Decrypt and print it")
	fmt.println("  wayu const rm NAME                     Remove it")
	fmt.println("  wayu secrets list                      List secret names")
	fmt.println("  wayu secrets rekey                     New master key, re-encrypt every secret")
	fmt.println("  wayu secrets lock                      Delete the decrypted session cache")
	fmt.println(
		"  wayu secrets run NAME... -- CMD [ARGS] Run CMD with these secrets set (no shell)",
	)
	fmt.println(
		"  wayu const add NAME [VALUE] --run-only Secret only `secrets run` injects (never exported)",
	)
}

// ---------------------------------------------------------------------------
// `wayu doctor`
// ---------------------------------------------------------------------------

// Secrets health: store readable and 0600, backend usable, key present,
// every value decrypts, cache dir safe. With no stored secret nothing is
// asked of the backend (no keychain prompt on a machine without secrets).
check_secrets :: proc(results: ^[dynamic]CheckResult) {
	ensure_arena_initialized()
	add :: proc(results: ^[dynamic]CheckResult, name: string, status: CheckStatus, msg: string) {
		append(
			results,
			CheckResult{name = clone_arena(name), status = status, message = clone_arena(msg)},
		)
	}

	backend_cfg, cfg_ok, raw := secrets_backend_configured()
	if !cfg_ok {
		add(
			results,
			"secrets",
			.ERROR,
			fmt.tprintf(
				"[secrets] backend = %q is not one of auto, keychain, secret-service, file",
				raw,
			),
		)
		return
	}
	s, exists, err := secrets_store_load()
	defer secrets_store_destroy(&s)
	if len(err) > 0 {
		add(results, "secrets", .ERROR, err)
		return
	}
	if !exists || len(s.entries) == 0 {
		add(results, "secrets", .INFO, "No encrypted secrets (wayu const add NAME --secret)")
		return
	}

	path := secrets_store_path()
	if fi, serr := os.stat(path, context.temp_allocator); serr == nil {
		if fi.mode &
			   {
					   .Read_Group,
					   .Write_Group,
					   .Execute_Group,
					   .Read_Other,
					   .Write_Other,
					   .Execute_Other,
				   } !=
		   {} {
			add(
				results,
				"secrets store",
				.ERROR,
				fmt.tprintf("%s is accessible by group/other: chmod 600 it", path),
			)
		} else {
			add(
				results,
				"secrets store",
				.OK,
				fmt.tprintf(
					"%d secret(s) (%d run-only), mode 0600",
					len(s.entries),
					len(s.entries) - secrets_session_count(&s),
				),
			)
		}
	}

	backend := secrets_backend_resolve(backend_cfg)
	bname := SECRETS_BACKEND_NAMES[backend]
	if prog := keystore_backend_program(backend); len(prog) > 0 && !check_command_exists(prog) {
		add(
			results,
			"secrets backend",
			.ERROR,
			fmt.tprintf("%s: `%s` not found on PATH", bname, prog),
		)
		return
	}
	key, status, msg := keystore_load(backend)
	defer crypto.zero_explicit(&key, size_of(key))
	if status != .OK {
		add(results, "secrets backend", .ERROR, fmt.tprintf("%s: %s", bname, msg))
		return
	}
	bad := make([dynamic]string, context.temp_allocator)
	for e in s.entries {
		v, ok := secrets_open(key, e.name, e.blob, run_only = e.run_only)
		if !ok {
			append(&bad, e.name); continue
		}
		secrets_wipe(v)
	}
	if len(bad) > 0 {
		add(
			results,
			"secrets backend",
			.ERROR,
			fmt.tprintf(
				"%s: key present, but %d secret(s) do not decrypt: %s",
				bname,
				len(bad),
				strings.join(bad[:], ", ", context.temp_allocator),
			),
		)
	} else {
		add(
			results,
			"secrets backend",
			.OK,
			fmt.tprintf("%s: key present, every secret decrypts", bname),
		)
	}

	dir := secrets_cache_dir()
	if os.exists(dir) {
		if ok, derr := secrets_cache_dir_check(dir); !ok {
			add(results, "secrets cache", .ERROR, derr)
		} else {
			add(results, "secrets cache", .OK, fmt.tprintf("%s is private (0700)", dir))
		}
	}
}

// ---------------------------------------------------------------------------
// `wayu secrets run NAME... -- CMD [ARGS...]`
// ---------------------------------------------------------------------------

// Decrypt the named secrets (run-only or not) into this process's
// environment, then replace wayu with CMD (execvp: PATH lookup, no shell,
// no fork), so CMD's exit status and signals are the caller's. Values are
// never printed. `args` still holds the `--` (cli_parser keeps it for
// `secrets run`).
secrets_run_command :: proc(args: []string) {
	sep := -1
	for a, i in args {
		if a == "--" {
			sep = i; break
		}
	}
	if sep < 0 || sep + 1 >= len(args) || sep == 0 {
		print_error_simple("Usage: wayu secrets run NAME... -- CMD [ARGS...]")
		wayu_exit(EXIT_USAGE)
	}
	names := args[:sep]
	cmd := args[sep + 1:]

	s, _ := secrets_store_load_or_exit()
	defer secrets_store_destroy(&s)
	for n in names {
		if secrets_store_find(&s, n) < 0 {
			print_error_simple("Not a secret: %s (see wayu secrets list)", n)
			wayu_exit(EXIT_DATAERR)
		}
	}

	if wayu.dry_run {
		print_info(
			"[dry-run] Would run %s with %s set",
			strings.join(cmd, " ", context.temp_allocator),
			strings.join(names, ", ", context.temp_allocator),
		)
		return
	}

	key, kok, kerr := secrets_key_for_read()
	if !kok {
		exit_with_secret_error(kerr)
	}
	for n in names {
		e := s.entries[secrets_store_find(&s, n)]
		v, dok := secrets_open(key, e.name, e.blob, run_only = e.run_only)
		if !dok {
			crypto.zero_explicit(&key, size_of(key))
			exit_with_secret_error(
				fmt.tprintf(
					"%s does not decrypt with the current master key (wrong key or tampered store)",
					n,
				),
			)
		}
		cname := strings.clone_to_cstring(n, context.temp_allocator)
		cval := strings.clone_to_cstring(v, context.temp_allocator)
		secrets_wipe(v)
		posix.setenv(cname, cval, true)
		crypto.zero_explicit(rawptr(cval), len(cval))
	}
	crypto.zero_explicit(&key, size_of(key))

	argv := make([]cstring, len(cmd) + 1, context.temp_allocator)
	for a, i in cmd {argv[i] = strings.clone_to_cstring(a, context.temp_allocator)}
	argv[len(cmd)] = nil
	posix.execvp(argv[0], raw_data(argv))

	// execvp returned: it failed.
	errno := posix.errno()
	#partial switch errno {
	case .ENOENT, .ENOTDIR:
		fmt.eprintfln("wayu: %s: command not found", cmd[0])
		wayu_exit(EXIT_EXEC_NOT_FOUND)
	case:
		fmt.eprintfln("wayu: %s: %s", cmd[0], posix.strerror(errno))
		wayu_exit(EXIT_EXEC_NOT_RUNNABLE)
	}
}
