// secrets.odin - Single source of truth for secret handling:
//   * file modes for files that may contain [env] values (wayu.toml,
//     backups, generated core/lazy/login/helpers scripts);
//   * the "looks secret" heuristic and value masking used by every preview
//     and list output (dry-run, search, export --dry-run, `const list`,
//     `toml show`, the TUI constants view).
//
// `wayu const get NAME` (exact) deliberately prints the real value — that is
// its purpose. List views mask unless the user asks with `--reveal` (CLI) or
// the reveal key (TUI).

package wayu

import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"

// 0600 / 0700: owner-only. Anything holding [env] values is created with
// these; never wider than what the user chose for wayu.toml.
SECRET_FILE_PERMS :: os.Permissions{.Read_User, .Write_User}
SECRET_DIR_PERMS  :: os.Permissions{.Read_User, .Write_User, .Execute_User}

// Fixed-width mask: never reveals length or prefix of the real value.
SECRET_MASK :: "********"

// Upper-cased name fragments that mark an entry as secret-bearing.
@(private = "file")
SECRET_NAME_MARKERS := [?]string{
	"KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASS",
	"API", "CREDENTIAL", "AUTH", "PRIVATE", "SESSION", "COOKIE",
	"SIGNATURE", "CERT", "DSN",
}

// Well-known credential value prefixes (vendor token formats).
@(private = "file")
SECRET_VALUE_PREFIXES := [?]string{
	"sk-", "sk_", "pk_live_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_",
	"ghr_", "github_pat_", "glpat-", "xoxb-", "xoxp-", "xoxa-", "xapp-",
	"AKIA", "ASIA", "AIza", "ya29.", "eyJ", "npm_", "hf_", "-----BEGIN",
}

// True when an entry NAME suggests its value is a credential.
// Case-insensitive substring match against SECRET_NAME_MARKERS.
looks_secret_name :: proc(name: string) -> bool {
	upper := strings.to_upper(name, context.temp_allocator)
	for marker in SECRET_NAME_MARKERS {
		if strings.contains(upper, marker) { return true }
	}
	return false
}

// True when a VALUE itself looks like a credential: a known token prefix,
// or a URL carrying a password in its userinfo (scheme://user:pass@host).
looks_secret_value :: proc(value: string) -> bool {
	for prefix in SECRET_VALUE_PREFIXES {
		if strings.has_prefix(value, prefix) { return true }
	}
	if scheme_end := strings.index(value, "://"); scheme_end > 0 {
		rest := value[scheme_end + 3:]
		if at := strings.index_byte(rest, '@'); at > 0 {
			slash := strings.index_byte(rest, '/')
			if slash < 0 || at < slash {
				if strings.index_byte(rest[:at], ':') >= 0 { return true }
			}
		}
	}
	return false
}

looks_secret :: proc(name, value: string) -> bool {
	return looks_secret_name(name) || looks_secret_value(value)
}

// Value safe to show in a preview. Returns `value` itself (not a copy) when
// it is not secret, else the constant SECRET_MASK. Never allocates.
mask_secret_value :: proc(name, value: string) -> string {
	if len(value) > 0 && looks_secret(name, value) { return SECRET_MASK }
	return value
}

// Value to show in a list view: the real value when `reveal` (`--reveal`,
// TUI reveal key), else masked like a preview. Never allocates.
list_display_value :: proc(name, value: string, reveal: bool) -> string {
	if reveal { return value }
	return mask_secret_value(name, value)
}

// Best-effort: tighten an existing file to 0600. Used for generated files
// whose pre-existing mode may predate this policy (O_CREAT ignores the
// mode argument for files that already exist).
restrict_file_mode :: proc(path: string) {
	if err := os.chmod(path, SECRET_FILE_PERMS); err != nil {
		debug("chmod 0600 failed for %s: %v", path, err)
	}
}

// Copy of a wayu.toml document with secret-looking [env] values replaced by
// SECRET_MASK, for previews that show a whole rewritten file (e.g. schema
// migration --dry-run). Other lines are kept verbatim. Caller deletes.
mask_toml_env_section :: proc(content: string, allocator := context.allocator) -> string {
	// Same parser as every reader, so the preview masks exactly the entries
	// `const list` would show (quoted keys, multi-line values, CRLF, BOM).
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil { return strings.clone(SECRET_MASK, allocator) }
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

	doc, _ := toml_doc_parse_alloc(content, scratch)
	lines := strings.split(content, "\n", scratch)
	replace := make([]string, len(lines), scratch) // "" = keep the line
	drop := make([]bool, len(lines), scratch)

	mask_lines :: proc(replace: []string, drop: []bool, key: string, first, last: int, alloc: mem.Allocator) {
		replace[first] = strings.concatenate({key, ` = "`, SECRET_MASK, `"`}, alloc)
		for i in first + 1 ..= last { drop[i] = true }
	}

	for e in doc.entries {
		if !toml_entry_in_section(&doc, e, "env") { continue }
		name := toml_entry_name(e, scratch)
		secret := false
		if text, ok := toml_value_text(e.value); ok {
			// Multi-line strings ("""…""" / '''…''') can't be judged from
			// one line (PEM blocks, certs): always mask them in previews.
			multiline := e.vstart >= 0 && (strings.has_prefix(content[e.vstart:], `"""`) || strings.has_prefix(content[e.vstart:], "'''"))
			secret = multiline || (len(text) > 0 && looks_secret(name, text))
		} else {
			secret = looks_secret_name(name) // arrays / inline tables: by name
		}
		if secret {
			mask_lines(replace, drop, toml_format_key(name, scratch), e.first, e.last, scratch)
		}
	}

	// A broken multi-line value in [env] has no known end: mask its line and
	// drop everything up to the next table header.
	for err in doc.errors {
		if !err.multiline { continue }
		in_env := false
		next := len(lines)
		for h in doc.headers {
			if h.line < err.stmt_line {
				in_env = !h.invalid && !h.array && len(h.path) == 1 && h.path[0] == "env"
			} else if h.line > err.stmt_line {
				next = h.line
				break
			}
		}
		if !in_env { continue }
		line := lines[err.stmt_line]
		key := strings.trim_space(line[:max(strings.index_byte(line, '='), 0)])
		mask_lines(replace, drop, key, err.stmt_line, next - 1, scratch)
	}

	b := strings.builder_make(0, len(content), allocator)
	first := true
	for line, i in lines {
		if drop[i] { continue }
		if !first { strings.write_byte(&b, '\n') }
		first = false
		strings.write_string(&b, replace[i] if len(replace[i]) > 0 else line)
	}
	return strings.to_string(b)
}
