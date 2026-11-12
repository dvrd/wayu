// keystore.odin - Where the master key of the encrypted secrets store lives.
//
// One interface (keystore_load / keystore_save) over three backends, chosen
// by `[secrets] backend` in wayu.toml:
//
//   keychain        macOS login keychain via /usr/bin/security (generic
//                   password, account "wayu-<id>", service
//                   "wayu-master-key"). Storing runs `security -i` and writes
//                   the command line on its stdin: the key is never on argv.
//   secret-service  freedesktop Secret Service via `secret-tool` from a
//                   system dir (KEYSTORE_SECRET_TOOL_DIRS; service "wayu",
//                   account "wayu-<id>"; the key is written to its stdin,
//                   never on argv).
//
//   <id> is the data dir's id (keystore_account): one key per data dir.
//   file            <config>/secret.key: 64 hex chars, mode 0600, created
//                   with O_EXCL; refused when group/other can read it.
//   auto (default)  keychain on macOS; secret-service on Linux when
//                   `secret-tool` is installed in a system dir; else file.
//
// Every external command runs through run_command_* (no shell), by absolute
// path: never looked up in PATH, where a planted `security` would receive
// the key. The key is never printed, logged or written anywhere else.

package wayu

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

SECRETS_KEY_SIZE :: 32 // 256-bit master key

Secrets_Backend :: enum {
	AUTO,
	KEYCHAIN,
	SECRET_SERVICE,
	FILE,
}

// The `[secrets] backend` words, in Secrets_Backend order.
SECRETS_BACKEND_NAMES := [Secrets_Backend]string {
	.AUTO           = "auto",
	.KEYCHAIN       = "keychain",
	.SECRET_SERVICE = "secret-service",
	.FILE           = "file",
}

// Outcome of keystore_load.
Key_Status :: enum {
	OK, // key loaded
	MISSING, // the backend answered: there is no key (safe to create one)
	UNAVAILABLE, // the backend could not be asked or refused (locked, denied, not installed)
	INVALID, // a key is stored but unusable (bad format, unsafe file mode)
}

KEYCHAIN_ACCOUNT_PREFIX :: "wayu" // account = "wayu-<data dir id>" (keystore_account)
KEYCHAIN_SERVICE :: "wayu-master-key"
SECRET_SERVICE_SERVICE :: "wayu"
SECRET_KEY_FILE :: "secret.key"

// `security find-generic-password` exit status for "item not found".
@(private = "file")
KEYCHAIN_NOT_FOUND_EXIT :: 44

// Keychain / Secret Service may show an unlock dialog: generous deadline.
@(private = "file")
KEYSTORE_TIMEOUT_MS :: 120_000

// The keychain backend's program: never looked up in PATH.
KEYSTORE_SECURITY_BIN :: "/usr/bin/security"

// Where the secret-service backend looks for `secret-tool` (in order):
// root-owned system dirs only (NixOS: /run/current-system/sw/bin), never
// PATH.
KEYSTORE_SECRET_TOOL_DIRS := [?]string {
	"/usr/bin",
	"/usr/local/bin",
	"/bin",
	"/run/current-system/sw/bin",
}

// Test-only (-define:WAYU_TEST_KEYSTORE=true; never set in a release
// build): WAYU_TEST_SECURITY_BIN / WAYU_TEST_SECRET_TOOL_BIN replace the
// programs so tests can fake the keychain. Release builds never read them.
WAYU_TEST_KEYSTORE :: #config(WAYU_TEST_KEYSTORE, false)

// Backend word → enum; ok = false for an unknown word.
secrets_backend_parse :: proc(word: string) -> (Secrets_Backend, bool) {
	for name, b in SECRETS_BACKEND_NAMES {
		if name == word {
			return b, true
		}
	}
	return .AUTO, false
}

// `[secrets] backend` from wayu.toml (AUTO when absent). ok = false when
// the value is not one of SECRETS_BACKEND_NAMES; `raw` is then that value
// (temp-allocated).
secrets_backend_configured :: proc() -> (backend: Secrets_Backend, ok: bool, raw: string) {
	content, has_toml := get_cached_toml_content()
	if !has_toml {
		return .AUTO, true, ""
	}

	word, found := toml_secrets_backend_value(content)
	if !found {
		return .AUTO, true, ""
	}
	b, known := secrets_backend_parse(word)
	if !known {
		return .AUTO, false, word
	}
	return b, true, ""
}

// The raw `[secrets] backend` string of a wayu.toml document
// (temp-allocated). found = false when the key is absent or not a string.
toml_secrets_backend_value :: proc(content: string) -> (value: string, found: bool) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return "", false
	}
	defer virtual.arena_destroy(&arena)
	doc, _ := toml_doc_parse_alloc(content, virtual.arena_allocator(&arena))
	v := get_toml_value(&doc, "secrets.backend")
	if v == nil || v.type != .STRING {
		return "", false
	}
	return strings.clone(v.str_val, context.temp_allocator), true
}

// AUTO → the concrete backend for this machine.
secrets_backend_resolve :: proc(b: Secrets_Backend) -> Secrets_Backend {
	if b != .AUTO {
		return b
	}
	when ODIN_OS == .Darwin {
		return .KEYCHAIN
	} else {
		if len(keystore_backend_binary(.SECRET_SERVICE)) > 0 {
			return .SECRET_SERVICE
		}
		return .FILE
	}
}

// The configured backend, resolved. Prints and exits EXIT_CONFIG on an
// unknown `[secrets] backend`.
secrets_backend_active :: proc() -> Secrets_Backend {
	b, ok, raw := secrets_backend_configured()
	if !ok {
		print_error_simple(
			"wayu.toml: [secrets] backend = %q is not one of auto, keychain, secret-service, file",
			raw,
		)
		wayu_exit(EXIT_CONFIG)
	}
	return secrets_backend_resolve(b)
}

// Absolute path of the program a backend runs: KEYSTORE_SECURITY_BIN, or
// the first executable `secret-tool` in KEYSTORE_SECRET_TOOL_DIRS. "" when
// it is not installed there (and for file). Never searches PATH.
// Temp-allocated.
keystore_backend_binary :: proc(b: Secrets_Backend) -> string {
	when WAYU_TEST_KEYSTORE {
		env_name := "WAYU_TEST_SECURITY_BIN" if b == .KEYCHAIN else "WAYU_TEST_SECRET_TOOL_BIN"
		if fake := os.get_env(env_name, context.temp_allocator); len(fake) > 0 {
			return fake
		}
	}
	#partial switch b {
	case .KEYCHAIN:
		return KEYSTORE_SECURITY_BIN if keystore_is_executable(KEYSTORE_SECURITY_BIN) else ""
	case .SECRET_SERVICE:
		for dir in KEYSTORE_SECRET_TOOL_DIRS {
			path := fmt.tprintf("%s/secret-tool", dir)
			if keystore_is_executable(path) {
				return path
			}
		}
	}
	return ""
}

// Where keystore_backend_binary looks, for messages (temp-allocated).
keystore_backend_binary_hint :: proc(b: Secrets_Backend) -> string {
	if b == .KEYCHAIN {
		return KEYSTORE_SECURITY_BIN
	}
	return fmt.tprintf(
		"secret-tool in %s",
		strings.join(KEYSTORE_SECRET_TOOL_DIRS[:], ", ", context.temp_allocator),
	)
}

@(private = "file")
keystore_is_executable :: proc(path: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	st: posix.stat_t
	if posix.stat(cpath, &st) != .OK || !posix.S_ISREG(st.st_mode) {
		return false
	}
	return posix.access(cpath, {.X_OK}) == .OK
}

// ---------------------------------------------------------------------------
// argv construction (unit-tested; never run against the real keychain in tests)
// ---------------------------------------------------------------------------

// Account of the master key in the keychain / Secret Service: "wayu-<id>",
// <id> = secrets_cache_id() (FNV-1a 64 of the data dir path, 16 hex
// digits). Each data dir (a second profile, a test HOME) has its own key;
// none can read another's. Temp-allocated.
keystore_account :: proc() -> string {
	return fmt.tprintf("%s-%s", KEYCHAIN_ACCOUNT_PREFIX, secrets_cache_id())
}

// Human-readable label of the stored item: names the data dir it is for.
@(private = "file")
keystore_label :: proc() -> string {
	return fmt.tprintf("wayu master key (%s)", wayu.data)
}

// `security -i`: the store command comes on stdin (keychain_store_line),
// so the key never appears on argv, where `ps` shows it to every user.
keychain_store_argv :: proc() -> []string {
	return slice_temp({"security", "-i"})
}

// The `security -i` line that stores the key:
// `add-generic-password -U -a "wayu-<id>" -s "wayu-master-key"
// -l "wayu master key (<data>)" -w "<hex>"` and a newline. -U updates an
// existing item (rekey). Each word goes through keychain_quote.
// Temp-allocated; the caller wipes it.
keychain_store_line :: proc(key_hex: string) -> string {
	return keychain_store_line_item(keystore_account(), keystore_label(), key_hex, true)
}

// The `security -i` line that stores `secret` under `account` (same
// service). `update` adds -U (replace an existing item); without it an
// existing item makes `security` fail, so nothing is overwritten.
// Temp-allocated; the caller wipes it.
keychain_store_line_item :: proc(account, label, secret: string, update: bool) -> string {
	return fmt.tprintf(
		"add-generic-password%s -a %s -s %s -l %s -w %s\n",
		" -U" if update else "",
		keychain_quote(account),
		keychain_quote(KEYCHAIN_SERVICE),
		keychain_quote(label),
		keychain_quote(secret),
	)
}

// One word for `security -i`'s line parser: double-quoted, with `\` and
// `"` backslash-escaped. A control character (a newline would end the
// command) becomes `?`: only the informational label can hold one.
// Temp-allocated.
keychain_quote :: proc(word: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for i in 0 ..< len(word) {
		c := word[i]
		switch {
		case c == '"' || c == '\\':
			strings.write_byte(&b, '\\')
			strings.write_byte(&b, c)
		case c < 0x20 || c == 0x7f:
			strings.write_byte(&b, '?')
		case:
			strings.write_byte(&b, c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// `security find-generic-password -a wayu-<id> -s wayu-master-key -w`
// (prints the key).
keychain_load_argv :: proc(account := "") -> []string {
	return slice_temp(
		{
			"security",
			"find-generic-password",
			"-a",
			account if len(account) > 0 else keystore_account(),
			"-s",
			KEYCHAIN_SERVICE,
			"-w",
		},
	)
}

// `secret-tool store --label='wayu master key (<data>)' service wayu
// account wayu-<id>` (the key is written to stdin).
secret_service_store_argv :: proc(account := "", label := "") -> []string {
	return slice_temp(
		{
			"secret-tool",
			"store",
			fmt.tprintf("--label=%s", label if len(label) > 0 else keystore_label()),
			"service",
			SECRET_SERVICE_SERVICE,
			"account",
			account if len(account) > 0 else keystore_account(),
		},
	)
}

// `secret-tool lookup service wayu account wayu-<id>` (prints the key).
secret_service_load_argv :: proc(account := "") -> []string {
	return slice_temp(
		{
			"secret-tool",
			"lookup",
			"service",
			SECRET_SERVICE_SERVICE,
			"account",
			account if len(account) > 0 else keystore_account(),
		},
	)
}

// Where wayu 6.0 kept the key: one item shared by every data dir (keychain
// account "wayu", Secret Service "service wayu account master"). Read only
// to move the key to the per-data-dir item (secrets_key_load).
KEYCHAIN_LEGACY_ACCOUNT :: "wayu"
SECRET_SERVICE_LEGACY_ACCOUNT :: "master"

// `security find-generic-password -a wayu -s wayu-master-key -w`.
keychain_legacy_load_argv :: proc() -> []string {
	return slice_temp(
		{
			"security",
			"find-generic-password",
			"-a",
			KEYCHAIN_LEGACY_ACCOUNT,
			"-s",
			KEYCHAIN_SERVICE,
			"-w",
		},
	)
}

// `secret-tool lookup service wayu account master`.
secret_service_legacy_load_argv :: proc() -> []string {
	return slice_temp(
		{
			"secret-tool",
			"lookup",
			"service",
			SECRET_SERVICE_SERVICE,
			"account",
			SECRET_SERVICE_LEGACY_ACCOUNT,
		},
	)
}

// The command that deletes the 6.0 item (shown to the user, never run:
// other data dirs may still need it). Temp-allocated.
keystore_legacy_delete_hint :: proc(b: Secrets_Backend) -> string {
	if b == .SECRET_SERVICE {
		return fmt.tprintf(
			"secret-tool clear service %s account %s",
			SECRET_SERVICE_SERVICE,
			SECRET_SERVICE_LEGACY_ACCOUNT,
		)
	}
	return fmt.tprintf(
		"security delete-generic-password -a %s -s %s",
		KEYCHAIN_LEGACY_ACCOUNT,
		KEYCHAIN_SERVICE,
	)
}

// Load the 6.0 key (keychain / Secret Service only; .MISSING otherwise).
keystore_load_legacy :: proc(
	b: Secrets_Backend,
) -> (
	key: [SECRETS_KEY_SIZE]byte,
	status: Key_Status,
	msg: string,
) {
	#partial switch secrets_backend_resolve(b) {
	case .KEYCHAIN:
		return keystore_load_command(
			keychain_legacy_load_argv(),
			"macOS keychain",
			KEYCHAIN_NOT_FOUND_EXIT,
		)
	case .SECRET_SERVICE:
		return keystore_load_command(secret_service_legacy_load_argv(), "Secret Service", 1)
	}
	return key, .MISSING, ""
}

@(private = "file")
slice_temp :: proc(items: []string) -> []string {
	out := make([]string, len(items), context.temp_allocator)
	copy(out, items)
	return out
}

// argv with argv[0] (a program name) replaced by `bin`, the backend's
// absolute path (temp-allocated).
@(private = "file")
keystore_argv_resolved :: proc(argv: []string, bin: string) -> []string {
	out := slice_temp(argv)
	out[0] = bin
	return out
}

// <config>/secret.key (temp-allocated).
secret_key_file_path :: proc() -> string {
	return fmt.tprintf("%s/%s", wayu.config, SECRET_KEY_FILE)
}

// ---------------------------------------------------------------------------
// Load / save
// ---------------------------------------------------------------------------

// Decode a stored hex key. Surrounding whitespace is ignored.
keystore_decode_hex :: proc(text: string) -> (key: [SECRETS_KEY_SIZE]byte, ok: bool) {
	t := strings.trim_space(text)
	if len(t) != 2 * SECRETS_KEY_SIZE {
		return
	}
	raw, dec_ok := hex.decode(transmute([]byte)t, context.temp_allocator)
	if !dec_ok || len(raw) != SECRETS_KEY_SIZE {
		return
	}
	copy(key[:], raw)
	crypto.zero_explicit(raw_data(raw), len(raw))
	return key, true
}

// Hex text of a key (lowercase, temp-allocated). Caller wipes it.
keystore_encode_hex :: proc(key: [SECRETS_KEY_SIZE]byte) -> []byte {
	k := key
	return hex.encode(k[:], context.temp_allocator)
}

// Load the master key. `msg` explains a non-OK status (temp-allocated).
keystore_load :: proc(
	b: Secrets_Backend,
) -> (
	key: [SECRETS_KEY_SIZE]byte,
	status: Key_Status,
	msg: string,
) {
	secrets_disable_core_dumps() // the key is in memory from here on
	#partial switch secrets_backend_resolve(b) {
	case .KEYCHAIN:
		return keystore_load_command(
			keychain_load_argv(),
			"macOS keychain",
			KEYCHAIN_NOT_FOUND_EXIT,
		)
	case .SECRET_SERVICE:
		return keystore_load_command(secret_service_load_argv(), "Secret Service", 1)
	}
	return keystore_load_file(secret_key_file_path())
}

// Store `key` (create, or replace on rekey). `msg` explains a failure.
keystore_save :: proc(
	b: Secrets_Backend,
	key: [SECRETS_KEY_SIZE]byte,
	replace: bool,
) -> (
	ok: bool,
	msg: string,
) {
	secrets_disable_core_dumps() // the key is in memory from here on
	key_hex := keystore_encode_hex(key)
	defer crypto.zero_explicit(raw_data(key_hex), len(key_hex))

	#partial switch secrets_backend_resolve(b) {
	case .KEYCHAIN:
		bin := keystore_backend_binary(.KEYCHAIN)
		if len(bin) == 0 {
			return false, fmt.tprintf("%s not found", KEYSTORE_SECURITY_BIN)
		}
		line := keychain_store_line(string(key_hex))
		defer crypto.zero_explicit(raw_data(line), len(line))
		res := run_command_timeout(
			keystore_argv_resolved(keychain_store_argv(), bin),
			KEYSTORE_TIMEOUT_MS,
			stdin_data = line,
		)
		defer command_result_destroy(&res)
		if res.timed_out {
			return false,
				"could not store the key in the macOS keychain: security did not answer in time"
		}
		if !res.ok {
			return false, fmt.tprintf(
				"could not store the key in the macOS keychain (security exited %d)",
				res.exit_code,
			)
		}
		return true, ""
	case .SECRET_SERVICE:
		bin := keystore_backend_binary(.SECRET_SERVICE)
		if len(bin) == 0 {
			return false, fmt.tprintf(
				"%s: not found",
				keystore_backend_binary_hint(.SECRET_SERVICE),
			)
		}
		res := run_command_timeout(
			keystore_argv_resolved(secret_service_store_argv(), bin),
			KEYSTORE_TIMEOUT_MS,
			stdin_data = string(key_hex),
		)
		defer command_result_destroy(&res)
		if res.timed_out {
			return false, "could not store the key with secret-tool: it did not answer in time"
		}
		if !res.ok {
			return false, fmt.tprintf(
				"could not store the key with secret-tool (exited %d)",
				res.exit_code,
			)
		}
		return true, ""
	}
	return keystore_save_file(secret_key_file_path(), key_hex, replace)
}

// Keychain / Secret Service lookup. A non-zero exit equal to `not_found_exit`
// with no stderr output means "no such item" (MISSING); anything else is
// UNAVAILABLE so a key we merely could not read is never replaced.
@(private = "file")
keystore_load_command :: proc(
	argv: []string,
	label: string,
	not_found_exit: int,
) -> (
	key: [SECRETS_KEY_SIZE]byte,
	status: Key_Status,
	msg: string,
) {
	text: []byte
	text, status, msg = keystore_load_command_text(argv, label, not_found_exit, "master key")
	defer keystore_text_destroy(text)
	if status != .OK {
		return
	}
	k, ok := keystore_decode_hex(string(text))
	if !ok {
		return key, .INVALID, fmt.tprintf(
			"the wayu master key in the %s is not 64 hex characters",
			label,
		)
	}
	return k, .OK, ""
}

// Wipe and free a secret read by keystore_load_command_text /
// keystore_read_private_file.
keystore_text_destroy :: proc(text: []byte) {
	if len(text) > 0 {
		crypto.zero_explicit(raw_data(text), len(text))
	}
	delete(text)
}

// Run a keychain / Secret Service lookup and return what it printed
// (heap; free with keystore_text_destroy). `what` names the item in
// messages ("master key", "identity"); argv[3] / argv[5] is the account.
keystore_load_command_text :: proc(
	argv: []string,
	label: string,
	not_found_exit: int,
	what: string,
) -> (
	text: []byte,
	status: Key_Status,
	msg: string,
) {
	backend: Secrets_Backend = .KEYCHAIN if argv[0] == "security" else .SECRET_SERVICE
	account := argv[3] if backend == .KEYCHAIN else argv[5]
	bin := keystore_backend_binary(backend)
	if len(bin) == 0 {
		return nil, .UNAVAILABLE, fmt.tprintf(
			"%s: %s not found",
			label,
			keystore_backend_binary_hint(backend),
		)
	}
	res := run_command_timeout(keystore_argv_resolved(argv, bin), KEYSTORE_TIMEOUT_MS)
	defer {
		crypto.zero_explicit(raw_data(res.stdout), len(res.stdout))
		command_result_destroy(&res)
	}
	if !res.ok {
		if res.exit_code == not_found_exit &&
		   len(res.stdout) == 0 &&
		   (not_found_exit == KEYCHAIN_NOT_FOUND_EXIT || len(res.stderr) == 0) {
			return nil, .MISSING, fmt.tprintf(
				"no wayu %s in the %s (account %s)",
				what,
				label,
				account,
			)
		}
		if res.timed_out {
			return nil, .UNAVAILABLE, fmt.tprintf("%s did not answer in time", label)
		}
		return nil, .UNAVAILABLE, fmt.tprintf(
			"could not read the wayu %s from the %s (%s exited %d)",
			what,
			label,
			argv[0],
			res.exit_code,
		)
	}
	out := make([]byte, len(res.stdout))
	copy(out, res.stdout)
	return out, .OK, ""
}

// File backend load: regular file owned by us, no group/other bits.
keystore_load_file :: proc(
	path: string,
) -> (
	key: [SECRETS_KEY_SIZE]byte,
	status: Key_Status,
	msg: string,
) {
	data: []byte
	data, status, msg = keystore_read_private_file(path)
	defer keystore_text_destroy(data)
	if status != .OK {
		return
	}
	k, ok := keystore_decode_hex(string(data))
	if !ok {
		return key, .INVALID, fmt.tprintf("%s is not 64 hex characters", path)
	}
	return k, .OK, ""
}

// Read a key file: a regular file owned by us with no group/other bits
// (heap; free with keystore_text_destroy).
keystore_read_private_file :: proc(
	path: string,
) -> (
	data: []byte,
	status: Key_Status,
	msg: string,
) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	st: posix.stat_t
	if posix.lstat(cpath, &st) != .OK {
		if posix.errno() == .ENOENT {
			return nil, .MISSING, fmt.tprintf("%s does not exist", path)
		}
		return nil, .UNAVAILABLE, fmt.tprintf(
			"cannot stat %s: %s",
			path,
			posix.strerror(posix.errno()),
		)
	}
	if !posix.S_ISREG(st.st_mode) {
		return nil, .INVALID, fmt.tprintf("%s is not a regular file", path)
	}
	if st.st_uid != posix.getuid() {
		return nil, .INVALID, fmt.tprintf("%s is not owned by you", path)
	}
	if st.st_mode & (posix.S_IRWXG | posix.S_IRWXO) != {} {
		return nil, .INVALID, fmt.tprintf("%s is readable by group/other: chmod 600 it", path)
	}
	d, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return nil, .UNAVAILABLE, fmt.tprintf("cannot read %s: %v", path, err)
	}
	return d, .OK, ""
}

// File backend save. A new key file is created with O_EXCL (never over an
// existing one); `replace` (rekey) swaps it atomically, keeping 0600.
keystore_save_file :: proc(
	path: string,
	key_hex: []byte,
	replace: bool,
) -> (
	ok: bool,
	msg: string,
) {
	line := make([]byte, len(key_hex) + 1, context.temp_allocator)
	copy(line, key_hex)
	line[len(key_hex)] = '\n'
	defer crypto.zero_explicit(raw_data(line), len(line))
	return keystore_write_private_file(path, line, replace, "a master key")
}

// Write a key file (0600). A new file is created with O_EXCL (never over an
// existing one: "<path> already exists: refusing to overwrite <what>");
// `replace` swaps an existing file atomically.
keystore_write_private_file :: proc(
	path: string,
	line: []byte,
	replace: bool,
	what: string,
) -> (
	ok: bool,
	msg: string,
) {
	if replace && os.exists(path) {
		if err := write_file_atomic(path, line); err != nil {
			return false, fmt.tprintf("cannot write %s: %v", path, err)
		}
		_ = os.chmod(path, SECRET_FILE_PERMS)
		return true, ""
	}

	// A config dir created here is 0700 (it holds secret.key).
	dir, _ := os.split_path(path)
	if len(dir) > 0 {
		if dok, derr := private_dir_make(dir); !dok {
			return false, derr
		}
	}
	f, err := os.open(path, {.Write, .Create, .Excl}, SECRET_FILE_PERMS)
	if err != nil {
		if err == os.General_Error.Exist {
			return false, fmt.tprintf("%s already exists: refusing to overwrite %s", path, what)
		}
		return false, fmt.tprintf("cannot create %s: %v", path, err)
	}
	defer os.close(f)
	if _, werr := os.write(f, line); werr != nil {
		os.remove(path)
		return false, fmt.tprintf("cannot write %s: %v", path, werr)
	}
	_ = os.fchmod(f, SECRET_FILE_PERMS) // umask may have stripped nothing, but be explicit
	if serr := os.sync(f); serr != nil {
		return false, fmt.tprintf("cannot sync %s: %v", path, serr)
	}
	return true, ""
}

// ---------------------------------------------------------------------------
// This machine's age identity (multi-machine secrets, OKAMI-370)
// ---------------------------------------------------------------------------
//
//   keychain / secret-service   account "wayu-<id>-identity" (same service
//                               as the master key), value AGE-SECRET-KEY-1…
//   file                        <config>/identity.key in age's identity-file
//                               layout (`# public key: age1…` comment), so
//                               `age -i` reads it; 0600, created with O_EXCL.
//
// Created once (`wayu secrets identity`, or the first `recipient add`) and
// never replaced by wayu.

IDENTITY_KEY_FILE :: "identity.key"

// Account of the identity item: "wayu-<id>-identity" (temp-allocated).
keystore_identity_account :: proc() -> string {
	return fmt.tprintf("%s-identity", keystore_account())
}

// <config>/identity.key (temp-allocated).
identity_key_file_path :: proc() -> string {
	return fmt.tprintf("%s/%s", wayu.config, IDENTITY_KEY_FILE)
}

// The AGE-SECRET-KEY-1… line of an identity file or keystore item: the one
// non-comment, non-blank line. ok = false for none, several, or a bad key.
keystore_identity_parse :: proc(text: string) -> (secret: [AGE_KEY_SIZE]byte, ok: bool) {
	rest := text
	found := false
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if len(l) == 0 || l[0] == '#' {
			continue
		}
		if found {
			crypto.zero_explicit(&secret, size_of(secret))
			return secret, false
		}
		secret, ok = age_identity_decode(l)
		if !ok {
			return
		}
		found = true
	}
	return secret, found
}

// Load this machine's identity (`msg` explains a non-OK status).
keystore_identity_load :: proc(
	b: Secrets_Backend,
) -> (
	secret: [AGE_KEY_SIZE]byte,
	status: Key_Status,
	msg: string,
) {
	secrets_disable_core_dumps()
	text: []byte
	where_: string
	#partial switch secrets_backend_resolve(b) {
	case .KEYCHAIN:
		where_ = "macOS keychain"
		text, status, msg = keystore_load_command_text(
			keychain_load_argv(keystore_identity_account()),
			where_,
			KEYCHAIN_NOT_FOUND_EXIT,
			"identity",
		)
	case .SECRET_SERVICE:
		where_ = "Secret Service"
		text, status, msg = keystore_load_command_text(
			secret_service_load_argv(keystore_identity_account()),
			where_,
			1,
			"identity",
		)
	case:
		where_ = identity_key_file_path()
		text, status, msg = keystore_read_private_file(identity_key_file_path())
	}
	defer keystore_text_destroy(text)
	if status != .OK {
		return
	}
	s, ok := keystore_identity_parse(string(text))
	if !ok {
		return secret, .INVALID, fmt.tprintf(
			"the wayu identity in the %s is not one AGE-SECRET-KEY-1… line",
			where_,
		)
	}
	return s, .OK, ""
}

// Store a new identity. Never replaces one: the file is created with
// O_EXCL, the keychain item without -U.
keystore_identity_save :: proc(
	b: Secrets_Backend,
	secret: [AGE_KEY_SIZE]byte,
) -> (
	ok: bool,
	msg: string,
) {
	secrets_disable_core_dumps()
	id_text := age_identity_encode(secret)
	defer crypto.zero_explicit(raw_data(id_text), len(id_text))
	label := fmt.tprintf("wayu identity (%s)", wayu.data)

	#partial switch secrets_backend_resolve(b) {
	case .KEYCHAIN:
		bin := keystore_backend_binary(.KEYCHAIN)
		if len(bin) == 0 {
			return false, fmt.tprintf("%s not found", KEYSTORE_SECURITY_BIN)
		}
		line := keychain_store_line_item(keystore_identity_account(), label, id_text, false)
		defer crypto.zero_explicit(raw_data(line), len(line))
		res := run_command_timeout(
			keystore_argv_resolved(keychain_store_argv(), bin),
			KEYSTORE_TIMEOUT_MS,
			stdin_data = line,
		)
		defer command_result_destroy(&res)
		if !res.ok {
			return false, fmt.tprintf(
				"could not store the identity in the macOS keychain (security exited %d)",
				res.exit_code,
			)
		}
		return true, ""
	case .SECRET_SERVICE:
		bin := keystore_backend_binary(.SECRET_SERVICE)
		if len(bin) == 0 {
			return false, fmt.tprintf(
				"%s: not found",
				keystore_backend_binary_hint(.SECRET_SERVICE),
			)
		}
		res := run_command_timeout(
			keystore_argv_resolved(
				secret_service_store_argv(keystore_identity_account(), label),
				bin,
			),
			KEYSTORE_TIMEOUT_MS,
			stdin_data = id_text,
		)
		defer command_result_destroy(&res)
		if !res.ok {
			return false, fmt.tprintf(
				"could not store the identity with secret-tool (exited %d)",
				res.exit_code,
			)
		}
		return true, ""
	}
	created, _ := time.time_to_rfc3339(
		time.now(),
		include_nanos = false,
		allocator = context.temp_allocator,
	)
	content := fmt.tprintf(
		"# created: %s\n# public key: %s\n%s\n",
		created,
		age_recipient_encode(age_identity_public(secret)),
		id_text,
	)
	defer crypto.zero_explicit(raw_data(content), len(content))
	return keystore_write_private_file(
		identity_key_file_path(),
		transmute([]byte)content,
		false,
		"an identity",
	)
}
