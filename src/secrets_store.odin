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
SECRETS_VERSION :: 1 // one machine: the master key is the data key
SECRETS_VERSION_MULTI :: 2 // + recipients (secrets_recipients.odin), opt-in
SECRETS_VERSION_MAX :: SECRETS_VERSION_MULTI

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
// version 0 or 1: the v1 format; SECRETS_VERSION_MULTI adds the header
// fields below (secrets_recipients.odin).
Secrets_Store :: struct {
	entries:    [dynamic]Secret_Entry,
	version:    int,
	key_id:     string,
	recipients: [dynamic]Secret_Recipient,
	rotations:  [dynamic]Secret_Rotation,
	recovery:   Secret_Recovery, // recipient == "": none
}

secrets_store_destroy :: proc(s: ^Secrets_Store) {
	for e in s.entries {
		delete(e.name)
		delete(e.blob)
	}
	delete(s.entries)
	s.entries = nil
	secrets_store_header_destroy(s)
}

// Is `s` a multi-machine (version 2) store?
secrets_store_is_multi :: proc(s: ^Secrets_Store) -> bool {
	return s.version == SECRETS_VERSION_MULTI
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

// "NAME does not decrypt …" for a value of `s` (temp-allocated).
secrets_decrypt_error :: proc(s: ^Secrets_Store, name: string) -> string {
	if secrets_store_is_multi(s) {
		return fmt.tprintf(
			"%s does not decrypt with data key %s (a concurrent rekey on another machine, or a tampered store): re-add it with 'wayu const add %s --secret'",
			name,
			s.key_id,
			name,
		)
	}
	return fmt.tprintf(
		"%s does not decrypt with the current master key (wrong key or tampered store)",
		name,
	)
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
// ("version", "cipher", "values", optional "run_only"; version 2 adds
// "key_id", "recipients", optional "rotations" and "recovery", checked by
// secrets_store_parse_header), nothing after it;
// every name a shell variable name; every value a string; "run_only" a list
// of distinct names that are in "values". The depth-limited strict syntax
// check runs first: core:encoding/json recurses without a limit, so a
// deeply nested file would overflow the stack.
secrets_store_parse :: proc(text: string) -> (store: Secrets_Store, err: string) {
	if serr := json_strict_check(text); len(serr) > 0 {
		return {}, fmt.tprintf("not valid JSON (%s)", serr)
	}
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
	version, v_ok := doc["version"].(json.Integer)
	if v_ok && version > SECRETS_VERSION_MAX {
		// A newer format (e.g. a store another machine upgraded): name the
		// fix instead of calling the file malformed.
		return {}, fmt.tprintf(
			"version %d was written by a newer wayu (this one reads up to version %d): upgrade wayu on this machine (brew upgrade wayu, or see the README's Upgrade section)",
			version,
			SECRETS_VERSION_MAX,
		)
	}
	if !v_ok {
		return {}, fmt.tprintf(
			"unsupported version: \"version\" must be the integer %d or %d",
			SECRETS_VERSION,
			SECRETS_VERSION_MULTI,
		)
	}
	if version != SECRETS_VERSION && version != SECRETS_VERSION_MULTI {
		return {}, fmt.tprintf(
			"unsupported version %v (expected %d or %d)",
			version,
			SECRETS_VERSION,
			SECRETS_VERSION_MULTI,
		)
	}
	multi := version == SECRETS_VERSION_MULTI
	for k in doc {
		switch k {
		case "version", "cipher", "values", "run_only":
		case "key_id", "recipients", "rotations", "recovery":
			if !multi {
				return {}, fmt.tprintf("unknown field %q", k)
			}
		case:
			return {}, fmt.tprintf("unknown field %q", k)
		}
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
	store.version = int(version)
	if multi {
		if herr := secrets_store_parse_header(doc, &store); len(herr) > 0 {
			secrets_store_destroy(&store)
			return {}, herr
		}
	}
	return store, ""
}

// secrets.json text: pretty-printed, names sorted, trailing newline.
secrets_store_format :: proc(s: ^Secrets_Store, allocator := context.allocator) -> string {
	slice.sort_by(s.entries[:], proc(a, b: Secret_Entry) -> bool {return a.name < b.name})
	b := strings.builder_make(allocator)
	fmt.sbprintfln(&b, "%c", '{')
	fmt.sbprintfln(
		&b,
		`  "version": %d,`,
		SECRETS_VERSION_MULTI if secrets_store_is_multi(s) else SECRETS_VERSION,
	)
	fmt.sbprintfln(&b, `  "cipher": "%s",`, SECRETS_CIPHER)
	if secrets_store_is_multi(s) {
		secrets_store_format_header(&b, s)
	}
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
	if os.exists(secrets_rekey_pending_path()) {
		secrets_rekey_recover()
	}
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
	// entries.json is backed up (with the secrets.json copy, backup.odin)
	// before the first secrets.json write of the command, so the backup
	// holds the pair as it was before the command (OKAMI-303).
	if !create_backup_cli(entries_file_path()) {
		return false, fmt.tprintf("I/O error: could not back up %s", ENTRIES_FILE)
	}
	if wok, werr := secrets_store_write_to(secrets_store_path(), s); !wok {
		return false, werr
	}
	secrets_cache_invalidate()
	return true, ""
}

// Write the store text to `path` (atomic, 0600), creating the data dir.
secrets_store_write_to :: proc(path: string, s: ^Secrets_Store) -> (ok: bool, err: string) {
	text := secrets_store_format(s)
	defer delete(text)
	// A data dir created here is 0700 (it holds secrets.json).
	if dok, derr := private_dir_make(wayu.data); !dok {
		return false, fmt.tprintf("I/O error: %s", derr)
	}
	if e := write_file_atomic(path, transmute([]byte)text); e != nil {
		return false, fmt.tprintf("I/O error: cannot write %s: %v", path, e)
	}
	restrict_file_mode(path)
	return true, ""
}

// ---------------------------------------------------------------------------
// Rekey: crash-safe key + store swap
// ---------------------------------------------------------------------------
//
// `secrets rekey` writes the re-encrypted store to <data>/secrets.json.rekey,
// then saves the new key, then renames the pending store over secrets.json.
// A crash leaves the pending file; the next store load finishes or undoes
// the rekey (secrets_rekey_recover), so the key and the store never end up
// out of step (OKAMI-302).

// <data>/secrets.json.rekey (temp-allocated).
secrets_rekey_pending_path :: proc() -> string {
	return fmt.tprintf("%s.rekey", secrets_store_path())
}

// Is `key` the store's key? Version 2: its key_id matches (also with no
// values). Version 1: the first value decrypts with it.
secrets_store_opens_with :: proc(s: ^Secrets_Store, key: [SECRETS_KEY_SIZE]byte) -> bool {
	if secrets_store_is_multi(s) {
		return secrets_key_id(key) == s.key_id
	}
	if len(s.entries) == 0 {
		return false
	}
	e := s.entries[0]
	v, ok := secrets_open(key, e.name, e.blob, run_only = e.run_only)
	if ok {
		secrets_wipe(v)
	}
	return ok
}

// Does the store in the file at `path` decrypt with `key`? False when the
// file is missing, malformed or empty.
secrets_store_file_opens_with :: proc(path: string, key: [SECRETS_KEY_SIZE]byte) -> bool {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return false
	}
	s, perr := secrets_store_parse(string(data))
	delete(data)
	defer secrets_store_destroy(&s)
	return len(perr) == 0 && secrets_store_opens_with(&s, key)
}

// An interrupted rekey left secrets.json.rekey: if its values decrypt with
// the stored key, the key was already replaced, so the pending store is
// moved into place; if secrets.json still decrypts with it, the key was not
// replaced and the pending store is dropped. When the key can't be read
// (backend unavailable) nothing changes and the next load tries again.
//
// Only under the config lock: a `secrets rekey` in progress holds it, and
// its pending file must not be judged (and dropped) halfway. Nothing is
// done under --dry-run (the lock is not taken then).
secrets_rekey_recover :: proc() {
	if wayu.dry_run || !config_lock_acquire() {
		return
	}
	defer config_lock_release()
	pending := strings.clone(secrets_rekey_pending_path(), context.temp_allocator)
	data, rerr := os.read_entire_file_from_path(pending, context.allocator)
	if rerr != nil {
		return
	}
	ps, perr := secrets_store_parse(string(data))
	delete(data)
	defer secrets_store_destroy(&ps)
	if len(perr) > 0 {
		return
	}
	backend, cfg_ok, _ := secrets_backend_configured()
	if !cfg_ok {
		return
	}
	key, status, _ := keystore_load(backend)
	defer crypto.zero_explicit(&key, size_of(key))
	if status != .OK {
		return
	}
	if secrets_store_opens_with(&ps, key) {
		if os.rename(pending, secrets_store_path()) == nil {
			secrets_cache_invalidate()
		}
		return
	}
	if secrets_store_file_opens_with(secrets_store_path(), key) {
		os.remove(pending)
	}
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

// keystore_load, plus the one-time move of a wayu 6.0 key: when the
// per-data-dir item is missing but the shared 6.0 item (keystore_load_legacy)
// decrypts this data dir's secrets.json, the key is stored under the new
// item and used. The 6.0 item is kept (another data dir may still need it);
// the notice names the command that deletes it. Reads secrets.json directly
// (not secrets_store_load, which calls back here through rekey recovery).
secrets_key_load :: proc(
	backend: Secrets_Backend,
) -> (
	key: [SECRETS_KEY_SIZE]byte,
	status: Key_Status,
	msg: string,
) {
	key, _, status, msg = secrets_key_load_item(backend)
	return
}

// secrets_key_load, plus the local state stored after the key
// (keystore_decode_item; "" for a moved 6.0 key).
secrets_key_load_item :: proc(
	backend: Secrets_Backend,
) -> (
	key: [SECRETS_KEY_SIZE]byte,
	state: string,
	status: Key_Status,
	msg: string,
) {
	key, state, status, msg = keystore_load_item(backend)
	if status != .MISSING {
		return
	}
	old, old_status, _ := keystore_load_legacy(backend)
	defer crypto.zero_explicit(&old, size_of(old))
	if old_status != .OK {
		return
	}
	data, rerr := os.read_entire_file_from_path(secrets_store_path(), context.allocator)
	if rerr != nil {
		return
	}
	s, perr := secrets_store_parse(string(data))
	delete(data)
	defer secrets_store_destroy(&s)
	if len(perr) > 0 || !secrets_store_opens_with(&s, old) {
		return
	}
	if saved, serr := keystore_save(backend, old, false); !saved {
		return key, "", .UNAVAILABLE, fmt.tprintf(
			"could not move the wayu 6.0 master key to account %s: %s",
			keystore_account(),
			serr,
		)
	}
	fmt.eprintfln(
		"wayu: moved the master key to account %s (one key per data dir). The old shared item is no longer needed by this data dir; delete it once no other wayu data dir uses it: %s",
		keystore_account(),
		keystore_legacy_delete_hint(backend),
	)
	return old, "", .OK, ""
}

// Key to decrypt the values of `s`. Every failure is an error. A version 2
// store pins the data key (secrets_key_multi).
secrets_key_for_read :: proc(
	s: ^Secrets_Store,
) -> (
	key: [SECRETS_KEY_SIZE]byte,
	ok: bool,
	err: string,
) {
	if secrets_store_is_multi(s) {
		return secrets_key_multi(s)
	}
	backend := secrets_backend_active()
	k, local, status, msg := secrets_key_load_local(backend)
	switch status {
	case .OK:
		if local.multi {
			crypto.zero_explicit(&k, size_of(k))
			return key, false, secrets_downgrade_error()
		}
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
	s: ^Secrets_Store,
) -> (
	key: [SECRETS_KEY_SIZE]byte,
	ok: bool,
	err: string,
) {
	if secrets_store_is_multi(s) {
		// Never a new key over a version 2 store: its key is pinned.
		return secrets_key_multi(s)
	}
	store_has_values := len(s.entries) > 0
	backend := secrets_backend_active()
	k, local, status, msg := secrets_key_load_local(backend)
	switch status {
	case .OK:
		if local.multi {
			crypto.zero_explicit(&k, size_of(k))
			return key, false, secrets_downgrade_error()
		}
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

	key, kok, kerr := secrets_key_for_write(&s)
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
	key, kok, kerr := secrets_key_for_read(&s)
	if !kok {
		return "", true, false, kerr
	}
	defer crypto.zero_explicit(&key, size_of(key))
	v, dok := secrets_open(key, name, s.entries[i].blob, allocator, s.entries[i].run_only)
	if !dok {
		return "", true, false, secrets_decrypt_error(&s, name)
	}
	return v, true, true, ""
}

// ---------------------------------------------------------------------------
// Session cache
// ---------------------------------------------------------------------------

// <data>/run: the private fallback base of the session cache, used when
// neither XDG_RUNTIME_DIR nor TMPDIR is set (never a shared /tmp, where
// another user could create wayu-<uid> first) or when the cache dir under
// them is not ours (temp-allocated).
secrets_private_run_dir :: proc() -> string {
	return fmt.tprintf("%s/run", wayu.data)
}

// `${XDG_RUNTIME_DIR:-${TMPDIR:-<data>/run}}` with one trailing '/'
// removed — the same expression core.<ext> evaluates (temp-allocated).
secrets_runtime_base :: proc() -> string {
	base := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if len(base) == 0 {
		base = os.get_env("TMPDIR", context.temp_allocator)
	}
	if len(base) == 0 {
		base = secrets_private_run_dir()
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

// <runtime>/wayu-<uid>, or <data>/run/wayu-<uid> when that path exists but
// is a symlink, not a directory, owned by someone else, or open to group /
// other. core.<ext> makes the same choice (emit_secrets_loader).
// Temp-allocated.
secrets_cache_dir :: proc() -> string {
	dir := fmt.tprintf("%s/wayu-%d", secrets_runtime_base(), posix.getuid())
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(dir, context.temp_allocator), &st) == .OK {
		if !posix.S_ISDIR(st.st_mode) ||
		   st.st_uid != posix.getuid() ||
		   st.st_mode & (posix.S_IRWXG | posix.S_IRWXO) != {} {
			return fmt.tprintf("%s/wayu-%d", secrets_private_run_dir(), posix.getuid())
		}
	}
	return dir
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
	// The private base under the data dir is ours to create (0700).
	run := secrets_private_run_dir()
	if strings.has_prefix(dir, run) && len(dir) > len(run) && dir[len(run)] == '/' {
		crun := strings.clone_to_cstring(run, context.temp_allocator)
		if posix.mkdir(crun, posix.S_IRWXU) != .OK && posix.errno() != .EEXIST {
			return false, fmt.tprintf("cannot create %s: %s", run, posix.strerror(posix.errno()))
		}
	}
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
	HEADER :: "# wayu secrets session cache - generated by `wayu secrets cache`; do not edit.\n"
	prefix := "set -gx " if shell == .FISH else "export "
	sep := " " if shell == .FISH else "="
	// Exact size first: the buffer never grows, so no partial copy of a
	// value is left behind in a freed block (OKAMI-326), and the quoting
	// writes straight into it (no temporary quoted copies).
	size := len(HEADER)
	for name, i in names {
		if is_shell_var_name(name) {
			q :=
				escape_fish_string_len(values[i]) if \
					shell == .FISH else \
					shell_single_quote_len(values[i])
			size += len(prefix) + len(name) + len(sep) + q + 1
		}
	}
	b := strings.builder_make_len_cap(0, size, allocator)
	strings.write_string(&b, HEADER)
	for name, i in names {
		if !is_shell_var_name(name) {
			continue
		}
		strings.write_string(&b, prefix)
		strings.write_string(&b, name)
		strings.write_string(&b, sep)
		if shell == .FISH {
			escape_fish_string_to(&b, values[i])
		} else {
			shell_single_quote_to(&b, values[i])
		}
		strings.write_byte(&b, '\n')
	}
	assert(len(b.buf) == size)
	return strings.to_string(b)
}

// <data>/run/cache-dirs: every cache dir a cache of this data dir was
// written to, one per line, so invalidation also finds caches written under
// another TMPDIR / XDG_RUNTIME_DIR (temp-allocated).
secrets_cache_dirs_file :: proc() -> string {
	return fmt.tprintf("%s/cache-dirs", secrets_private_run_dir())
}

// Every dir a cache of this data dir may be in (deduplicated,
// temp-allocated): the current one, the ones the usual bases give
// (`$XDG_RUNTIME_DIR`, `$TMPDIR`, <data>/run, /tmp), and the ones recorded
// in secrets_cache_dirs_file.
secrets_cache_dirs_known :: proc() -> []string {
	dirs := make([dynamic]string, context.temp_allocator)
	add :: proc(dirs: ^[dynamic]string, dir: string) {
		if len(dir) > 0 && !slice.contains(dirs[:], dir) {
			append(dirs, dir)
		}
	}
	uid_dir :: proc(base: string) -> string {
		b := base
		if len(b) > 1 && strings.has_suffix(b, "/") {
			b = b[:len(b) - 1]
		}
		return fmt.tprintf("%s/wayu-%d", b, posix.getuid())
	}
	add(&dirs, secrets_cache_dir())
	for var in ([]string{"XDG_RUNTIME_DIR", "TMPDIR"}) {
		if base := os.get_env(var, context.temp_allocator); len(base) > 0 {
			add(&dirs, uid_dir(base))
		}
	}
	add(&dirs, uid_dir(secrets_private_run_dir()))
	add(&dirs, uid_dir("/tmp"))
	if data, err := os.read_entire_file_from_path(
		secrets_cache_dirs_file(),
		context.temp_allocator,
	); err == nil {
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if strings.has_prefix(line, "/") {
				add(&dirs, line)
			}
		}
	}
	return dirs[:]
}

// Record `dir` in secrets_cache_dirs_file (0600, atomic) unless it is
// there. Best effort: a lost record only means invalidation misses that
// dir (the cache still goes stale against the store).
@(private = "file")
secrets_cache_dir_record :: proc(dir: string) {
	if strings.contains_any(dir, "\n\r") {
		return
	}
	path := secrets_cache_dirs_file()
	old: string
	if data, err := os.read_entire_file_from_path(path, context.temp_allocator); err == nil {
		old = string(data)
		text := old
		for line in strings.split_lines_iterator(&text) {
			if line == dir {
				return
			}
		}
	}
	if ok, _ := private_dir_ensure(secrets_private_run_dir()); !ok {
		return
	}
	sep := "\n" if len(old) > 0 && !strings.has_suffix(old, "\n") else ""
	text := strings.concatenate({old, sep, dir, "\n"}, context.temp_allocator)
	if write_file_atomic(path, transmute([]byte)text) == nil {
		restrict_file_mode(path)
	}
}

// Remove every shell's cache for this data dir (store changed, rekey, lock)
// from every dir one may be in (secrets_cache_dirs_known). A dir is only
// entered when lstat shows a real directory owned by us; unlink never
// follows a symlinked cache file.
secrets_cache_invalidate :: proc() -> (removed: int) {
	for dir in secrets_cache_dirs_known() {
		st: posix.stat_t
		if posix.lstat(strings.clone_to_cstring(dir, context.temp_allocator), &st) != .OK ||
		   !posix.S_ISDIR(st.st_mode) ||
		   st.st_uid != posix.getuid() {
			continue
		}
		for sh in ([]ShellType{.ZSH, .BASH, .FISH}) {
			p := fmt.tprintf("%s/secrets-%s.%s", dir, secrets_cache_id(), get_shell_extension(sh))
			if posix.unlink(strings.clone_to_cstring(p, context.temp_allocator)) == .OK {
				removed += 1
			}
		}
	}
	return
}

// Decrypt everything and write the cache for `shell`. The cache's mtime is
// pushed past secrets.json's whole second, so core's `-nt` test (whole
// seconds in some shells) sees it as newer.
//
// No lock (it runs at shell start): instead secrets.json's identity (inode,
// size, mtime, ctime) is taken before it is read and checked again after the
// cache is in place. A store write in between (const add, rm, rekey) means
// the cache may hold the old values: it is deleted and rewritten from the new
// store (OKAMI-301). A writer that lands after the re-check deletes the cache
// itself (secrets_store_save invalidates after writing).
secrets_cache_write :: proc(shell: ShellType) -> (path: string, ok: bool, err: string) {
	MAX_ATTEMPTS :: 5
	for _ in 0 ..< MAX_ATTEMPTS {
		before, _ := secrets_store_stamp()
		changed: bool
		path, ok, err, changed = secrets_cache_write_once(shell, before)
		if !changed {
			return
		}
	}
	return path, false, fmt.tprintf(
		"%s kept changing while the session cache was written",
		secrets_store_path(),
	)
}

// Identity of secrets.json for change detection (zero when missing).
Secrets_Store_Stamp :: struct {
	ino:   u64,
	size:  i64,
	mtime: i64, // ns
	ctime: i64, // ns
}

secrets_store_stamp :: proc() -> (stamp: Secrets_Store_Stamp, exists: bool) {
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(secrets_store_path(), context.temp_allocator), &st) !=
	   .OK {
		return {}, false
	}
	ns :: proc(t: posix.timespec) -> i64 {return i64(t.tv_sec) * 1e9 + i64(t.tv_nsec)}
	return {u64(st.st_ino), i64(st.st_size), ns(st.st_mtim), ns(st.st_ctim)}, true
}

// Test seam: runs after the store was read and decrypted, before the cache
// is written (unit tests change the store here to simulate a race).
secrets_cache_race_hook: proc()

// One attempt of secrets_cache_write. changed = secrets.json is no longer
// `before` once the cache was written: the cache was deleted, try again.
@(private = "file")
secrets_cache_write_once :: proc(
	shell: ShellType,
	before: Secrets_Store_Stamp,
) -> (
	path: string,
	ok: bool,
	err: string,
	changed: bool,
) {
	s, exists, lerr := secrets_store_load()
	if len(lerr) > 0 {
		return "", false, lerr, false
	}
	defer secrets_store_destroy(&s)
	path = secrets_cache_path(shell)
	if !exists {
		return path,
			false,
			fmt.tprintf("no secrets stored (%s does not exist)", secrets_store_path()),
			false
	}

	// Run-only values are never decrypted here: they never reach the cache.
	names := make([dynamic]string, 0, len(s.entries), context.temp_allocator)
	values := make([dynamic]string, 0, len(s.entries), context.temp_allocator)
	defer for v in values {secrets_wipe(v)}
	if secrets_session_count(&s) > 0 {
		key, kok, kerr := secrets_key_for_read(&s)
		if !kok {
			return path, false, kerr, false
		}
		defer crypto.zero_explicit(&key, size_of(key))
		for e in s.entries {
			if e.run_only {
				continue
			}
			v, dok := secrets_open(key, e.name, e.blob)
			if !dok {
				return path, false, secrets_decrypt_error(&s, e.name), false
			}
			append(&names, e.name)
			append(&values, v)
		}
	}
	if secrets_cache_race_hook != nil {
		secrets_cache_race_hook()
	}

	dir := secrets_cache_dir()
	if dok, derr := secrets_cache_dir_ensure(dir); !dok {
		return path, false, derr, false
	}
	secrets_cache_dir_record(dir)
	// write_file_atomic follows symlinks: never write decrypted values
	// through one (or keep a planted link the loader would refuse).
	if st: posix.stat_t;
	   posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK &&
	   !posix.S_ISREG(st.st_mode) {
		if rerr := os.remove(path); rerr != nil {
			return path, false, fmt.tprintf("cannot replace %s: %v", path, rerr), false
		}
	}
	content := secrets_cache_content(shell, names[:], values[:])
	defer secrets_wipe(content)
	if werr := write_file_atomic(path, transmute([]byte)content); werr != nil {
		return path, false, fmt.tprintf("cannot write %s: %v", path, werr), false
	}
	restrict_file_mode(path)

	// Newer than the store we read, in whole seconds (some shells' -nt).
	mtime := time.now()
	after := time.from_nanoseconds((before.mtime / 1e9 + 1) * 1e9)
	if time.diff(mtime, after) > 0 {
		mtime = after
	}
	_ = os.chtimes(path, mtime, mtime)

	// The store changed since it was read: these values may be stale.
	if now, _ := secrets_store_stamp(); now != before {
		os.remove(path)
		return path, false, "", true
	}
	return path, true, "", false
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
// without the secrets. Nothing when no secret exists. With sep = ";" the
// statements fit on one line for `eval "$(wayu export --eval)"` (quoted).
emit_secrets_loader :: proc(b: ^strings.Builder, shell: ShellType, sep := "\n") {
	if !secrets_store_nonempty() {
		return
	}
	ext := get_shell_extension(shell)
	uid_dir := fmt.tprintf("/wayu-%d", posix.getuid())
	file := fmt.tprintf("/secrets-%s.%s", secrets_cache_id(), ext)
	run := secrets_private_run_dir()
	fallback := strings.concatenate({run, uid_dir}, context.temp_allocator)
	store := secrets_store_path()
	bin := wayu_self_path()
	if len(bin) == 0 {
		bin = "wayu"
	}
	// The cache is only trusted in a directory we own that is not a symlink
	// and has no group/other permission bits (else <data>/run/wayu-<uid>,
	// the same choice secrets_cache_dir makes),
	// and only when the file itself is ours, not a symlink, and newer than
	// the store. There is no shared /tmp default: <data>/run instead.

	if shell == .FISH {
		fq :: proc(s: string) -> string {return escape_fish_string(s, context.temp_allocator)}
		qstore := fq(store)
		fmt.sbprintln(b, "# === Secrets (encrypted store, per-session cache) ===")
		fmt.sbprintfln(b, "set -l _wayu_sc %s", fq(run))
		fmt.sbprintln(
			b,
			`if test -n "$XDG_RUNTIME_DIR"; set _wayu_sc $XDG_RUNTIME_DIR; else if test -n "$TMPDIR"; set _wayu_sc $TMPDIR; end`,
		)
		fmt.sbprintfln(
			b,
			"set _wayu_sc (string replace -r '(.)/$' '$1' -- $_wayu_sc)%s",
			fq(uid_dir),
		)
		// fish has no fork-free way to read a mode: one `ls` when the dir
		// exists.
		fmt.sbprintln(
			b,
			"if test -L $_wayu_sc; or begin; test -e $_wayu_sc; and begin; not test -d $_wayu_sc; or not test -O $_wayu_sc; or not string match -qr -- '^d...------' (command ls -ldn -- $_wayu_sc 2>/dev/null); end; end",
		)
		fmt.sbprintfln(b, "    set _wayu_sc %s", fq(fallback))
		fmt.sbprintln(b, "end")
		fmt.sbprintfln(b, "set _wayu_sc $_wayu_sc%s", fq(file))
		fmt.sbprintfln(
			b,
			"if not test -O $_wayu_sc; or test -L $_wayu_sc; or not test $_wayu_sc -nt %s",
			qstore,
		)
		fmt.sbprintfln(
			b,
			"    command %s secrets cache --shell fish </dev/null >/dev/null",
			fq(bin),
		)
		fmt.sbprintln(b, "end")
		fmt.sbprintfln(
			b,
			"if test -O $_wayu_sc; and not test -L $_wayu_sc; and test $_wayu_sc -nt %s; source $_wayu_sc; end",
			qstore,
		)
		fmt.sbprintln(b, "set -e _wayu_sc")
		fmt.sbprintln(b)
		return
	}

	sq :: proc(s: string) -> string {return shell_single_quote(s, context.temp_allocator)}
	// "$_wayu_sc" is a dir with no group/other permission bits. zsh: a glob
	// qualifier (no fork; `/` does not follow a symlink). bash cannot read a
	// mode without a fork: one `ls` when the dir exists.
	private_dir :=
		`() { emulate -L zsh; local -a m; m=( $1(N/f:go-rwx:) ); (( $#m )); } "$_wayu_sc"` if \
			shell == .ZSH else \
			`case $(command ls -ldn -- "$_wayu_sc" 2>/dev/null) in d???------*) true ;; *) false ;; esac`
	fresh := strings.concatenate(
		{`[ -O "$_wayu_sc" ] && [ ! -h "$_wayu_sc" ] && [ "$_wayu_sc" -nt `, sq(store), " ]"},
		context.temp_allocator,
	)
	lines := [?]string {
		strings.concatenate(
			{`_wayu_sc=${XDG_RUNTIME_DIR:-${TMPDIR:-`, sq(run), "}}"},
			context.temp_allocator,
		),
		`[ "$_wayu_sc" = / ] || _wayu_sc=${_wayu_sc%/}`,
		strings.concatenate({`_wayu_sc="$_wayu_sc"`, sq(uid_dir)}, context.temp_allocator),
		strings.concatenate(
			{
				`if [ -h "$_wayu_sc" ] || { [ -e "$_wayu_sc" ] && { [ ! -d "$_wayu_sc" ] || [ ! -O "$_wayu_sc" ] || ! `,
				private_dir,
				`; }; }; then _wayu_sc=`,
				sq(fallback),
				"; fi",
			},
			context.temp_allocator,
		),
		strings.concatenate({`_wayu_sc="$_wayu_sc"`, sq(file)}, context.temp_allocator),
		strings.concatenate(
			{
				"{ ",
				fresh,
				"; } || command ",
				sq(bin),
				" secrets cache --shell ",
				ext,
				" </dev/null >/dev/null",
			},
			context.temp_allocator,
		),
		strings.concatenate(
			{"if ", fresh, `; then source "$_wayu_sc"; fi`},
			context.temp_allocator,
		),
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

// Delete every entries.json backup that still holds `plain`: converting a
// constant to a secret must not leave its plaintext behind in the backups
// taken before the conversion.
@(private = "file")
scrub_entries_backups :: proc(plain: string) {
	backups := list_backups_for_file(entries_file_path())
	defer free_backup_infos(backups)
	for b in backups {
		data, rerr := os.read_entire_file(b.backup_file, context.allocator)
		if rerr != nil {
			continue
		}
		hit := entries_text_holds(string(data), plain)
		crypto.zero_explicit(raw_data(data), len(data))
		delete(data)
		if hit {
			backup_remove(b.backup_file)
		}
	}
}

// Does entries.json text hold `plain` in any of its strings? The text is
// parsed and every decoded string compared, so the escaping the backup was
// written with does not matter (\uXXXX vs raw UTF-8, `\r` vs `\u000d`, raw
// DEL). Text that does not parse is searched for `plain` raw and in both
// JSON escapings wayu has written (json_escape, json.marshal).
entries_text_holds :: proc(text, plain: string) -> bool {
	if len(plain) == 0 {
		return false
	}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return strings.contains(text, plain)
	}
	defer {
		// Decoded strings are plaintext copies: wipe before releasing.
		for blk := arena.curr_block; blk != nil; blk = blk.prev {
			crypto.zero_explicit(blk.base, int(blk.used))
		}
		virtual.arena_destroy(&arena)
	}
	scratch := virtual.arena_allocator(&arena)

	holds :: proc(v: json.Value, plain: string) -> bool {
		#partial switch x in v {
		case json.String:
			return strings.contains(x, plain)
		case json.Array:
			for item in x {
				if holds(item, plain) {
					return true
				}
			}
		case json.Object:
			for k, item in x {
				if strings.contains(k, plain) || holds(item, plain) {
					return true
				}
			}
		}
		return false
	}
	if doc, perr := json.parse_string(text, .JSON, true, scratch);
	   perr == nil && holds(doc, plain) {
		return true
	}
	if strings.contains(text, plain) {
		return true
	}
	esc := json_escape(plain)
	defer secrets_wipe(esc)
	if strings.contains(text, esc) {
		return true
	}
	if m, merr := json.marshal(plain, allocator = scratch); merr == nil {
		return strings.contains(text, string(m))
	}
	return false
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
// `prompt` replaces the "Value for NAME" prompt.
read_secret_value :: proc(name: string, prompt := "") -> (value: string, ok: bool) {
	secrets_disable_core_dumps()
	tty := bool(posix.isatty(posix.STDIN_FILENO))
	if tty {
		if len(prompt) > 0 {
			fmt.eprint(prompt)
		} else {
			fmt.eprintf("Value for %s (input hidden): ", name)
		}
		// Echo off; Ctrl+C / Ctrl+Z / SIGTERM restore it (fuzzy.odin).
		no_echo_mode_enable()
	}
	b: [dynamic]byte
	defer secret_buf_destroy(&b)
	buf: [512]byte
	for {
		n := posix.read(posix.STDIN_FILENO, raw_data(buf[:]), len(buf))
		if n < 0 && posix.errno() == .EINTR {
			continue // stopped (Ctrl+Z) and continued
		}
		if n <= 0 {
			break
		}
		secret_buf_append(&b, buf[:n])
		if tty && slice.contains(b[:], '\n') {
			break
		}
	}
	crypto.zero_explicit(&buf, size_of(buf))
	if tty {
		disable_raw_mode()
		fmt.eprintln()
	}
	s := string(b[:])
	if tty {
		if i := strings.index_byte(s, '\n'); i >= 0 {
			s = s[:i]
		}
	} else {
		s = strings.trim_suffix(s, "\n")
	}
	s = strings.trim_suffix(s, "\r")
	value = strings.clone(s)
	return value, len(value) > 0
}

// Append to a buffer that holds plaintext. On growth the old block is wiped
// before it is freed (a plain append would resize and leave the copy in
// freed memory) (OKAMI-326).
secret_buf_append :: proc(buf: ^[dynamic]byte, data: []byte) {
	if len(buf) + len(data) > cap(buf) {
		bigger := make([dynamic]byte, 0, max(2 * cap(buf), len(buf) + len(data), 256))
		append(&bigger, ..buf[:])
		secret_buf_destroy(buf)
		buf^ = bigger
	}
	append(buf, ..data)
}

// Wipe (whole capacity) and free a secret_buf_append buffer.
secret_buf_destroy :: proc(buf: ^[dynamic]byte) {
	if cap(buf) > 0 {
		crypto.zero_explicit(raw_data(buf^), cap(buf))
	}
	delete(buf^)
	buf^ = nil
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
		secrets_disable_core_dumps()
		value = strings.join(args[1:], " ")
		owned = true
		// argv is visible to other local users (ps) and lands in shell
		// history; stdin keeps the value out of both.
		print_warning(
			"The value of %s was passed as an argument: it is visible in ps and your shell history. Omit VALUE to be prompted (input hidden), or pipe it on stdin.",
			name,
		)
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
		// secrets.json is written first; if entries.json then can't be
		// updated, secrets.json goes back to what it was (OKAMI-323), so no
		// value is exported without a constant listing it.
		snap := secrets_store_snapshot()
		defer secrets_store_snapshot_destroy(&snap)
		existed, ok, err := secrets_set(name, value, run_only)
		if !ok {
			exit_with_secret_error(err)
		}
		converted, mok, merr := env_store_mark_secret(name, run_only)
		if !mok {
			secrets_store_snapshot_restore(&snap)
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

// Remove secret constant NAME as a pair: its ciphertext (secrets.json) and
// its entries.json marker; when the marker can't be dropped, secrets.json is
// put back. removed = false when NAME is not a secret. Never exits (the TUI
// deletes through it too); err is temp-allocated. Caller holds the config
// lock and handled --dry-run.
const_remove_secret :: proc(name: string) -> (removed: bool, ok: bool, err: string) {
	snap := secrets_store_snapshot()
	defer secrets_store_snapshot_destroy(&snap)
	rm, rok, rerr := secrets_remove(name)
	if !rok {
		return false, false, rerr
	}
	if !rm {
		return false, true, ""
	}
	if uok, uerr := env_store_unmark_secret(name); !uok {
		secrets_store_snapshot_restore(&snap) // keep the pair consistent
		return false, false, uerr
	}
	return true, true, ""
}

// secrets.json as it was before a two-file change (const add --secret,
// const rm), to put back when the entries.json half fails.
Secrets_Store_Snapshot :: struct {
	data:    []byte,
	existed: bool,
	ok:      bool, // read succeeded (a failed read is never "restored")
}

secrets_store_snapshot :: proc() -> (snap: Secrets_Store_Snapshot) {
	path := secrets_store_path()
	if !os.exists(path) {
		return {ok = true}
	}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return {}
	}
	return {data = data, existed = true, ok = true}
}

secrets_store_snapshot_destroy :: proc(snap: ^Secrets_Store_Snapshot) {
	delete(snap.data)
	snap^ = {}
}

// Put secrets.json back as snapshotted (best effort; caller is failing).
secrets_store_snapshot_restore :: proc(snap: ^Secrets_Store_Snapshot) {
	if !snap.ok {
		return
	}
	path := secrets_store_path()
	if !snap.existed {
		os.remove(path)
	} else if write_file_atomic(path, snap.data) == nil {
		restrict_file_mode(path)
	}
	secrets_cache_invalidate()
}

// `const get NAME` when entries.json marks NAME secret but secrets.json
// has no value for it (e.g. entries.json restored alone): an error, never
// an empty value (OKAMI-303). Returns when NAME is not such a marker.
const_get_exit_if_secret_missing :: proc(name: string) {
	store, _, ok := entries_read()
	if !ok {
		return // the plain lookup reports a malformed entries.json
	}
	i := entries_find(&store, .ENV, name)
	is_marker := i >= 0 && store.env[i].secret
	entries_store_destroy(&store)
	if !is_marker {
		return
	}
	print_error_simple(
		"%s is a secret in %s, but %s has no value for it: restore both with `wayu backup restore entries --yes`, or remove it with `wayu const rm %s`",
		name,
		ENTRIES_FILE,
		SECRETS_STORE_FILE,
		name,
	)
	wayu_exit(EXIT_DATAERR)
}

// entries.json secret markers vs secrets.json values (doctor): a marker
// with no ciphertext is an error (the constant has no value), ciphertext
// with no marker a warning (exported but not listed by `const list`).
@(private = "file")
check_secrets_pairing :: proc(
	results: ^[dynamic]CheckResult,
	s: ^Secrets_Store,
	add: proc(results: ^[dynamic]CheckResult, name: string, status: CheckStatus, msg: string),
) {
	store, _, ok := entries_read()
	if !ok {
		return // the entries check reports it
	}
	defer entries_store_destroy(&store)
	missing := make([dynamic]string, context.temp_allocator)
	for e in store.env {
		if e.secret && secrets_store_find(s, e.name) < 0 {
			append(&missing, e.name)
		}
	}
	orphans := make([dynamic]string, context.temp_allocator)
	for e in s.entries {
		if i := entries_find(&store, .ENV, e.name); i < 0 || !store.env[i].secret {
			append(&orphans, e.name)
		}
	}
	if len(missing) > 0 {
		add(
			results,
			"secrets pairing",
			.ERROR,
			fmt.tprintf(
				"%s marks %s secret but %s has no value: restore both (`wayu backup restore entries --yes`) or `wayu const rm` them",
				ENTRIES_FILE,
				strings.join(missing[:], ", ", context.temp_allocator),
				SECRETS_STORE_FILE,
			),
		)
	}
	if len(orphans) > 0 {
		add(
			results,
			"secrets pairing",
			.WARNING,
			fmt.tprintf(
				"%s holds %s with no secret entry in %s (still exported; `wayu const rm NAME` removes it)",
				SECRETS_STORE_FILE,
				strings.join(orphans[:], ", ", context.temp_allocator),
				ENTRIES_FILE,
			),
		)
	}
}

// Is NAME a secret? Exits EXIT_CONFIG on a malformed store.
secrets_store_has_name_or_exit :: proc(name: string) -> bool {
	s, _ := secrets_store_load_or_exit()
	defer secrets_store_destroy(&s)
	return secrets_store_find(&s, name) >= 0
}

// Is NAME a secret? Never exits: a malformed or unreadable secrets.json is
// printed and returned as a heap-owned entry error (ENTRY_ERROR_CONFIG_PREFIX
// + why), so the CLI exits EXIT_CONFIG and the TUI shows the reason.
secrets_store_has_name :: proc(name: string) -> (is_secret: bool, err: string) {
	s, _, lerr := secrets_store_load()
	if len(lerr) > 0 {
		print_error_simple("%s", lerr)
		return false, strings.concatenate({ENTRY_ERROR_CONFIG_PREFIX, lerr})
	}
	defer secrets_store_destroy(&s)
	return secrets_store_find(&s, name) >= 0, ""
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
	case .IDENTITY, .RECIPIENT, .ADOPT, .RECOVERY:
		for a in args {
			if a == "-h" || a == "--help" || a == "help" {
				print_secrets_help()
				return
			}
		}
		handle_secrets_multi_command(action, args)
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

// New master key; every value re-encrypted; caches dropped. A version 2
// store also re-wraps the new key to every recipient (and the recovery
// stanza) and appends a rotation proof (secrets_store_rewrap_rotate).
@(private = "file")
secrets_rekey :: proc() {
	config_lock_acquire_or_exit()
	defer config_lock_release()

	s, exists := secrets_store_load_or_exit()
	defer secrets_store_destroy(&s)
	backend := secrets_backend_active()
	multi := secrets_store_is_multi(&s)

	if wayu.dry_run {
		print_info(
			"[dry-run] Would create a new %s (%s) and re-encrypt %d secret(s)%s",
			"data key" if multi else "master key",
			SECRETS_BACKEND_NAMES[backend],
			len(s.entries),
			fmt.tprintf(" for %d recipient(s)", len(s.recipients)) if multi else "",
		)
		return
	}
	if !multi && (!exists || len(s.entries) == 0) {
		print_info("No secrets to re-encrypt")
		return
	}

	old_key, kok, kerr := secrets_key_for_read(&s)
	if !kok {
		exit_with_secret_error(kerr)
	}
	defer crypto.zero_explicit(&old_key, size_of(old_key))
	if multi {
		secrets_recipients_check_or_exit(&s, old_key)
	}

	new_key := secrets_new_key()
	defer crypto.zero_explicit(&new_key, size_of(new_key))
	if rok, rerr := secrets_store_reencrypt(&s, old_key, new_key); !rok {
		exit_with_secret_error(rerr)
	}
	old_state, new_state: string
	if multi {
		if wok, werr := secrets_store_rewrap_rotate(&s, old_key, new_key); !wok {
			exit_with_secret_error(werr)
		}
		old_state, new_state = secrets_local_states_for_rotation(backend, &s, old_key, nil)
	}
	secrets_store_commit_new_key(&s, backend, old_key, new_key, old_state, new_state)
	if multi {
		print_success(
			"Re-encrypted %d secret(s) with a new data key %s, wrapped to %d recipient(s)",
			len(s.entries),
			s.key_id,
			len(s.recipients),
		)
		return
	}
	print_success(
		"Re-encrypted %d secret(s) with a new master key (%s)",
		len(s.entries),
		SECRETS_BACKEND_NAMES[backend],
	)
}

// Re-encrypt every value of `s` from old_key to new_key (in memory).
// Nothing changes when one does not decrypt.
secrets_store_reencrypt :: proc(
	s: ^Secrets_Store,
	old_key, new_key: [SECRETS_KEY_SIZE]byte,
) -> (
	ok: bool,
	err: string,
) {
	new_blobs := make([]string, len(s.entries))
	defer delete(new_blobs)
	for e, i in s.entries {
		v, dok := secrets_open(old_key, e.name, e.blob, run_only = e.run_only)
		if !dok {
			for b in new_blobs[:i] {delete(b)}
			return false, fmt.tprintf(
				"%s does not decrypt with the current key: nothing was changed (see wayu doctor)",
				e.name,
			)
		}
		new_blobs[i] = secrets_seal(new_key, e.name, v, run_only = e.run_only)
		secrets_wipe(v)
	}
	for &e, i in s.entries {
		delete(e.blob)
		e.blob = new_blobs[i]
	}
	return true, ""
}

// Make new_key the key of `s` on disk and in the keystore, crash-safe:
// pending store first, then the key, then the rename (a crash at any point
// is finished or undone by secrets_rekey_recover). Then the session cache
// and the backup companions (ciphertext under the old key) are dropped.
// Exits on failure (EXIT_IOERR / EXIT_CONFIG).
secrets_store_commit_new_key :: proc(
	s: ^Secrets_Store,
	backend: Secrets_Backend,
	old_key, new_key: [SECRETS_KEY_SIZE]byte,
	old_state := "",
	new_state := "",
) {
	pending := strings.clone(secrets_rekey_pending_path(), context.temp_allocator)
	if wok, werr := secrets_store_write_to(pending, s); !wok {
		os.remove(pending)
		exit_with_secret_error(werr)
	}
	if saved, serr := keystore_save_item(backend, new_key, new_state, true); !saved {
		os.remove(pending)
		exit_with_secret_error(serr)
	}
	if rerr := os.rename(pending, secrets_store_path()); rerr != nil {
		if secrets_store_file_opens_with(secrets_store_path(), new_key) {
			// The rename took effect after all: the rekey is complete.
			os.remove(pending)
		} else {
			// Put the old key back so the unchanged store stays readable.
			// If that fails too, the pending store stays: it matches the
			// saved new key, and the next load moves it into place.
			if restored, _ := keystore_save_item(backend, old_key, old_state, true); restored {
				os.remove(pending)
			}
			exit_with_secret_error(
				fmt.tprintf("I/O error: cannot replace %s: %v", secrets_store_path(), rerr),
			)
		}
	}
	secrets_cache_invalidate()
	backup_drop_secrets_companions() // their ciphertext is under the old key
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
	fmt.println()
	fmt.printfln("%sMULTI-MACHINE (experimental):%s", get_secondary(), RESET)
	fmt.println(
		"  wayu secrets identity [--name NAME]    Print this machine's age recipient (age1…)",
	)
	fmt.println("  wayu secrets recipient list [--json]   Machines that can read the secrets")
	fmt.println(
		"  wayu secrets recipient add AGE1 [--name NAME]  Let that machine read them (upgrades to v2)",
	)
	fmt.println(
		"  wayu secrets recipient rm NAME --yes   Remove a machine; always rotates the data key",
	)
	fmt.println("  wayu secrets recipient rename OLD NEW  Rename a machine")
	fmt.println(
		"  wayu secrets adopt --yes               Accept the data key in this machine's stanza",
	)
	fmt.println(
		"  wayu secrets recovery add|rm|unlock    Passphrase recovery (passphrase on stdin)",
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
	check_secrets_pairing(results, &s, add)
	check_secrets_files(results, add)
	if !secrets_store_is_multi(&s) && (!exists || len(s.entries) == 0) {
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
	if backend == .KEYCHAIN || backend == .SECRET_SERVICE {
		bname = fmt.tprintf("%s (account %s)", bname, keystore_account())
	}
	if (backend == .KEYCHAIN || backend == .SECRET_SERVICE) &&
	   len(keystore_backend_binary(backend)) == 0 {
		add(
			results,
			"secrets backend",
			.ERROR,
			fmt.tprintf("%s: %s not found", bname, keystore_backend_binary_hint(backend)),
		)
		return
	}
	if secrets_store_is_multi(&s) {
		check_secrets_multi(results, &s, backend, add)
		check_secrets_cache_dir(results, add)
		return
	}
	key, local, status, msg := secrets_key_load_local(backend)
	defer crypto.zero_explicit(&key, size_of(key))
	if status != .OK {
		// A MISSING message already names the account.
		label := SECRETS_BACKEND_NAMES[backend] if status == .MISSING else bname
		add(results, "secrets backend", .ERROR, fmt.tprintf("%s: %s", label, msg))
		return
	}
	if local.multi {
		add(results, "secrets store", .ERROR, secrets_downgrade_error())
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

	check_secrets_cache_dir(results, add)
}

@(private = "file")
check_secrets_cache_dir :: proc(
	results: ^[dynamic]CheckResult,
	add: proc(results: ^[dynamic]CheckResult, name: string, status: CheckStatus, msg: string),
) {
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

	key, kok, kerr := secrets_key_for_read(&s)
	if !kok {
		exit_with_secret_error(kerr)
	}
	for n in names {
		e := s.entries[secrets_store_find(&s, n)]
		v, dok := secrets_open(key, e.name, e.blob, run_only = e.run_only)
		if !dok {
			crypto.zero_explicit(&key, size_of(key))
			exit_with_secret_error(secrets_decrypt_error(&s, n))
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
	secrets_restore_core_limit() // CMD gets the caller's limit back
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
