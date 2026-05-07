// path_keys.odin - Derive TOML keys from filesystem paths.
//
// `[paths]` in wayu.toml is now a single table where each key labels a
// directory entry. The CLI accepts either an explicit `name=path` form or
// just `path`, in which case we derive a key from the basename. When the
// basename is too generic to stand alone (`bin`, `lib`, ...) we prepend the
// parent dir so `/usr/local/bin` and `/opt/homebrew/bin` become
// `local_bin` and `homebrew_bin` instead of colliding on `bin`.

package wayu

import "core:fmt"
import "core:strings"

// Basenames that almost never carry meaning on their own. When we see one,
// we prefix with the parent directory to keep keys self-describing.
COMMON_PATH_BASENAMES :: []string{
	"bin", "sbin",
	"lib", "lib64",
	"share", "etc", "var",
	"src", "dist", "build", "target", "out",
	"node_modules", "vendor",
	"current", "default", "latest",
}

// Lowercase + replace anything outside [a-z0-9_] with `_`. Returns "" when
// the input has no usable characters so callers can fall back.
//
// Special case: a leading dot is rendered as a literal `hidden_` prefix so
// dotfile dirs round-trip to a self-describing key:
//   `.local`  → `hidden_local`
//   `.cargo`  → `hidden_cargo`
//   `.config` → `hidden_config`
sanitize_path_key :: proc(s: string) -> string {
	if len(s) == 0 { return "" }

	hidden := s[0] == '.'

	// Worst case: every char becomes `_` plus the optional `hidden_` prefix.
	buf := make([]byte, len(s) + 7)
	defer delete(buf)
	n := 0
	prefix_len := 0
	if hidden {
		copy(buf[:7], "hidden_")
		n = 7
		prefix_len = 7
	}

	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z':
			buf[n] = c + ('a' - 'A')
			n += 1
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '_':
			buf[n] = c
			n += 1
		case:
			// Skip the leading dot (already encoded as `hidden_`) and any
			// leading garbage. Collapse internal runs to a single `_`.
			if n > prefix_len && buf[n-1] != '_' {
				buf[n] = '_'
				n += 1
			}
		}
	}
	// Trim trailing `_`.
	for n > 0 && buf[n-1] == '_' { n -= 1 }
	// `""` if nothing remains — including bare-prefix cases like "." → "hidden"
	// would be misleading, so we treat them as empty and let the caller fall back.
	if n == 0 || n == prefix_len - 1 /* trimmed prefix tail `_` */ { return "" }
	return strings.clone(string(buf[:n]))
}

is_common_path_basename :: proc(s: string) -> bool {
	for c in COMMON_PATH_BASENAMES {
		if s == c { return true }
	}
	return false
}

// Split a cleaned path into (parent_dir_basename, basename). Either may be
// empty (e.g. when the path is "/" or just "foo"). Caller does not own the
// returned strings — they're slices into `path`.
split_path_tail :: proc(path: string) -> (parent: string, base: string) {
	cleaned := strings.trim_right(path, "/")
	if len(cleaned) == 0 { return "", path }
	last := strings.last_index_byte(cleaned, '/')
	if last < 0 { return "", cleaned }
	base = cleaned[last+1:]
	rest := cleaned[:last]
	prev := strings.last_index_byte(rest, '/')
	if prev < 0 {
		parent = rest
	} else {
		parent = rest[prev+1:]
	}
	return
}

// Pick a unique TOML key for `path` given the set of `taken` keys.
//   /Users/me/dev/oss/Odin    → "odin"
//   /usr/local/bin            → "local_bin"   (bin is common)
//   /opt/homebrew/bin         → "homebrew_bin"
//   /Users/me/.cargo/bin      → "cargo_bin"
//   collisions                → "<base>_2", "<base>_3", ...
//
// Caller owns the returned string.
derive_path_key :: proc(path: string, taken: map[string]bool) -> string {
	parent, base := split_path_tail(path)

	// `base_key` is always heap-owned; fallback to a cloned literal when the
	// basename is unparseable (e.g. "." or pure punctuation) so we can free
	// it uniformly below.
	base_key := sanitize_path_key(base)
	if len(base_key) == 0 { base_key = strings.clone("path") }
	defer delete(base_key)

	key: string
	if is_common_path_basename(base_key) {
		parent_key := sanitize_path_key(parent)
		if len(parent_key) > 0 {
			key = fmt.aprintf("%s_%s", parent_key, base_key)
			delete(parent_key)
		} else {
			key = strings.clone(base_key)
		}
	} else {
		key = strings.clone(base_key)
	}

	if !(key in taken) { return key }

	// Collision — append "_2", "_3", ...
	stem := key
	defer delete(stem)
	for i := 2; ; i += 1 {
		candidate := fmt.aprintf("%s_%d", stem, i)
		if !(candidate in taken) { return candidate }
		delete(candidate)
	}
}

// Parse a CLI path argument that may be either:
//   "/usr/local/bin"           → (name="", path="/usr/local/bin", explicit=false)
//   "local_bin=/usr/local/bin" → (name="local_bin", path="/usr/local/bin", explicit=true)
//
// The `name=path` form is recognised only when the LHS is a non-empty
// identifier (alphanum + underscore, no slash). Anything else is treated
// as a bare path so users can still add paths with `=` in them.
//
// Returned strings are slices of `arg` — caller does not own them.
parse_path_arg :: proc(arg: string) -> (name, path: string, explicit: bool) {
	eq := strings.index_byte(arg, '=')
	if eq <= 0 { return "", arg, false }

	lhs := arg[:eq]
	rhs := arg[eq+1:]
	if len(rhs) == 0 { return "", arg, false }

	for i := 0; i < len(lhs); i += 1 {
		c := lhs[i]
		ok := (c >= 'a' && c <= 'z') ||
		      (c >= 'A' && c <= 'Z') ||
		      (c >= '0' && c <= '9') ||
		      c == '_' || c == '-'
		if !ok { return "", arg, false }
	}
	return lhs, rhs, true
}
