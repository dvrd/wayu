// secrets.odin - Single source of truth for secret handling:
//   * file modes for files that may contain [env] values (wayu.toml,
//     backups, generated core/lazy/login/helpers scripts);
//   * the "looks secret" heuristic and value masking used by every preview
//     output (dry-run, search, export --dry-run).
//
// `wayu const get NAME` (exact) and `wayu const list` deliberately print
// values — that is their purpose — and do not go through masking.

package wayu

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
	b := strings.builder_make(0, len(content), allocator)
	it := make_line_iter(content)
	in_env := false
	first := true
	open_multiline := "" // closing delimiter of a masked multi-line string
	for line in line_iter_next(&it) {
		if len(open_multiline) > 0 {
			// Body of a masked multi-line value: drop it entirely.
			if strings.contains(line, open_multiline) { open_multiline = "" }
			continue
		}
		if !first { strings.write_byte(&b, '\n') }
		first = false

		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "[") { in_env = toml_line_is_section(trimmed, "env") }
		if in_env {
			// Multi-line strings ("""…""" / '''…''') can't be judged from one
			// line (PEM blocks, certs): always mask them in previews.
			if eq := strings.index_byte(trimmed, '='); eq > 0 {
				raw := strings.trim_space(trimmed[eq + 1:])
				for delim in ([]string{`"""`, `'''`}) {
					if strings.has_prefix(raw, delim) && !strings.contains(raw[3:], delim) {
						open_multiline = delim
						break
					}
				}
				if len(open_multiline) > 0 {
					strings.write_string(&b, strings.trim_space(trimmed[:eq]))
					strings.write_string(&b, " = \"" + SECRET_MASK + "\"")
					continue
				}
			}
			key, value, ok := toml_parse_kv_line(trimmed)
			if ok {
				secret := len(value) > 0 && looks_secret(key, value)
				delete(value)
				if secret {
					strings.write_string(&b, key)
					strings.write_string(&b, " = \"" + SECRET_MASK + "\"")
					continue
				}
			}
		}
		strings.write_string(&b, line)
	}
	return strings.to_string(b)
}
