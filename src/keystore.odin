// keystore.odin - Where the master key of the encrypted secrets store lives.
//
// One interface (keystore_load / keystore_save) over three backends, chosen
// by `[secrets] backend` in wayu.toml:
//
//   keychain        macOS login keychain via `security` (generic password,
//                   account "wayu", service "wayu-master-key"). Storing puts
//                   the hex key briefly on `security`'s argv: `security` has
//                   no stdin mode for -w.
//   secret-service  freedesktop Secret Service via `secret-tool` (the key is
//                   written to its stdin, never on argv).
//   file            <config>/secret.key: 64 hex chars, mode 0600, created
//                   with O_EXCL; refused when group/other can read it.
//   auto (default)  keychain on macOS; secret-service on Linux when
//                   `secret-tool` is on PATH; else file.
//
// Every external command runs through run_command_* (no shell). The key is
// never printed, logged or written anywhere else.

package wayu

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/posix"

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

KEYCHAIN_ACCOUNT :: "wayu"
KEYCHAIN_SERVICE :: "wayu-master-key"
SECRET_KEY_FILE :: "secret.key"

// `security find-generic-password` exit status for "item not found".
@(private = "file")
KEYCHAIN_NOT_FOUND_EXIT :: 44

// Keychain / Secret Service may show an unlock dialog: generous deadline.
@(private = "file")
KEYSTORE_TIMEOUT_MS :: 120_000

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
		if check_command_exists("secret-tool") {
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

// The program a backend runs ("" for file). Doctor checks it is on PATH.
keystore_backend_program :: proc(b: Secrets_Backend) -> string {
	#partial switch b {
	case .KEYCHAIN:
		return "security"
	case .SECRET_SERVICE:
		return "secret-tool"
	}
	return ""
}

// ---------------------------------------------------------------------------
// argv construction (unit-tested; never run against the real keychain in tests)
// ---------------------------------------------------------------------------

// `security add-generic-password -U -a wayu -s wayu-master-key -w <hex>`.
// -U updates an existing item (rekey). Slice is temp-allocated.
keychain_store_argv :: proc(key_hex: string) -> []string {
	return slice_temp(
		{
			"security",
			"add-generic-password",
			"-U",
			"-a",
			KEYCHAIN_ACCOUNT,
			"-s",
			KEYCHAIN_SERVICE,
			"-w",
			key_hex,
		},
	)
}

// `security find-generic-password -a wayu -s wayu-master-key -w` (prints the key).
keychain_load_argv :: proc() -> []string {
	return slice_temp(
		{
			"security",
			"find-generic-password",
			"-a",
			KEYCHAIN_ACCOUNT,
			"-s",
			KEYCHAIN_SERVICE,
			"-w",
		},
	)
}

// `secret-tool store --label='wayu master key' service wayu account master`
// (the key is written to stdin).
secret_service_store_argv :: proc() -> []string {
	return slice_temp(
		{
			"secret-tool",
			"store",
			"--label=wayu master key",
			"service",
			"wayu",
			"account",
			"master",
		},
	)
}

// `secret-tool lookup service wayu account master` (prints the key).
secret_service_load_argv :: proc() -> []string {
	return slice_temp({"secret-tool", "lookup", "service", "wayu", "account", "master"})
}

@(private = "file")
slice_temp :: proc(items: []string) -> []string {
	out := make([]string, len(items), context.temp_allocator)
	copy(out, items)
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
	key_hex := keystore_encode_hex(key)
	defer crypto.zero_explicit(raw_data(key_hex), len(key_hex))

	#partial switch secrets_backend_resolve(b) {
	case .KEYCHAIN:
		if !check_command_exists("security") {
			return false, "`security` not found on PATH"
		}
		res := run_command_timeout(keychain_store_argv(string(key_hex)), KEYSTORE_TIMEOUT_MS)
		defer command_result_destroy(&res)
		if !res.ok {
			return false, fmt.tprintf(
				"could not store the key in the macOS keychain (security exited %d)",
				res.exit_code,
			)
		}
		return true, ""
	case .SECRET_SERVICE:
		if !check_command_exists("secret-tool") {
			return false, "`secret-tool` not found on PATH"
		}
		res := run_command_timeout(
			secret_service_store_argv(),
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
	if !check_command_exists(argv[0]) {
		return key, .UNAVAILABLE, fmt.tprintf("%s: `%s` not found on PATH", label, argv[0])
	}
	res := run_command_timeout(argv, KEYSTORE_TIMEOUT_MS)
	defer {
		crypto.zero_explicit(raw_data(res.stdout), len(res.stdout))
		command_result_destroy(&res)
	}
	if !res.ok {
		if res.exit_code == not_found_exit &&
		   len(res.stdout) == 0 &&
		   (not_found_exit == KEYCHAIN_NOT_FOUND_EXIT || len(res.stderr) == 0) {
			return key, .MISSING, fmt.tprintf("no wayu master key in the %s", label)
		}
		if res.timed_out {
			return key, .UNAVAILABLE, fmt.tprintf("%s did not answer in time", label)
		}
		return key, .UNAVAILABLE, fmt.tprintf(
			"could not read the wayu master key from the %s (%s exited %d)",
			label,
			argv[0],
			res.exit_code,
		)
	}
	k, ok := keystore_decode_hex(res.stdout)
	if !ok {
		return key, .INVALID, fmt.tprintf(
			"the wayu master key in the %s is not 64 hex characters",
			label,
		)
	}
	return k, .OK, ""
}

// File backend load: regular file owned by us, no group/other bits.
keystore_load_file :: proc(
	path: string,
) -> (
	key: [SECRETS_KEY_SIZE]byte,
	status: Key_Status,
	msg: string,
) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	st: posix.stat_t
	if posix.lstat(cpath, &st) != .OK {
		if posix.errno() == .ENOENT {
			return key, .MISSING, fmt.tprintf("%s does not exist", path)
		}
		return key, .UNAVAILABLE, fmt.tprintf(
			"cannot stat %s: %s",
			path,
			posix.strerror(posix.errno()),
		)
	}
	if !posix.S_ISREG(st.st_mode) {
		return key, .INVALID, fmt.tprintf("%s is not a regular file", path)
	}
	if st.st_uid != posix.getuid() {
		return key, .INVALID, fmt.tprintf("%s is not owned by you", path)
	}
	if st.st_mode & (posix.S_IRWXG | posix.S_IRWXO) != {} {
		return key, .INVALID, fmt.tprintf("%s is readable by group/other: chmod 600 it", path)
	}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return key, .UNAVAILABLE, fmt.tprintf("cannot read %s: %v", path, err)
	}
	defer {
		crypto.zero_explicit(raw_data(data), len(data))
		delete(data)
	}
	k, ok := keystore_decode_hex(string(data))
	if !ok {
		return key, .INVALID, fmt.tprintf("%s is not 64 hex characters", path)
	}
	return k, .OK, ""
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

	if replace && os.exists(path) {
		if err := write_file_atomic(path, line); err != nil {
			return false, fmt.tprintf("cannot write %s: %v", path, err)
		}
		_ = os.chmod(path, SECRET_FILE_PERMS)
		return true, ""
	}

	dir, _ := os.split_path(path)
	if len(dir) > 0 && !os.exists(dir) {
		if err := os.make_directory_all(dir); err != nil {
			return false, fmt.tprintf("cannot create %s: %v", dir, err)
		}
	}
	f, err := os.open(path, {.Write, .Create, .Excl}, SECRET_FILE_PERMS)
	if err != nil {
		if err == os.General_Error.Exist {
			return false, fmt.tprintf(
				"%s already exists: refusing to overwrite a master key",
				path,
			)
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
