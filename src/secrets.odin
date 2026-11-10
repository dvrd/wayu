// secrets.odin - Single source of truth for secret handling:
//   * file modes for files that may contain constant values (entries.json,
//     backups, generated core/path_sync scripts);
//   * the "looks secret" heuristic and value masking used by every preview
//     and list output (dry-run, search, export --dry-run, `const list`,
//     the TUI constants view).
//
// `wayu const get NAME` (exact) deliberately prints the real value — that is
// its purpose. List views mask unless the user asks with `--reveal` (CLI) or
// the reveal key (TUI).

package wayu

import "core:os"
import "core:strings"

// 0600 / 0700: owner-only. Anything holding constant values is created with
// these.
SECRET_FILE_PERMS :: os.Permissions{.Read_User, .Write_User}
SECRET_DIR_PERMS :: os.Permissions{.Read_User, .Write_User, .Execute_User}

// Fixed-width mask: never reveals length or prefix of the real value.
SECRET_MASK :: "********"

// Upper-cased name fragments that mark an entry as secret-bearing.
@(private = "file")
SECRET_NAME_MARKERS := [?]string {
	"KEY",
	"TOKEN",
	"SECRET",
	"PASSWORD",
	"PASSWD",
	"PASS",
	"API",
	"CREDENTIAL",
	"AUTH",
	"PRIVATE",
	"SESSION",
	"COOKIE",
	"SIGNATURE",
	"CERT",
	"DSN",
}

// Well-known credential value prefixes (vendor token formats).
@(private = "file")
SECRET_VALUE_PREFIXES := [?]string {
	"sk-",
	"sk_",
	"pk_live_",
	"rk_live_",
	"ghp_",
	"gho_",
	"ghu_",
	"ghs_",
	"ghr_",
	"github_pat_",
	"glpat-",
	"xoxb-",
	"xoxp-",
	"xoxa-",
	"xapp-",
	"AKIA",
	"ASIA",
	"AIza",
	"ya29.",
	"eyJ",
	"npm_",
	"hf_",
	"-----BEGIN",
}

// True when an entry NAME suggests its value is a credential.
// Case-insensitive substring match against SECRET_NAME_MARKERS.
looks_secret_name :: proc(name: string) -> bool {
	upper := strings.to_upper(name, context.temp_allocator)
	for marker in SECRET_NAME_MARKERS {
		if strings.contains(upper, marker) {
			return true
		}
	}
	return false
}

// True when a VALUE itself looks like a credential: a known token prefix,
// or a URL carrying a password in its userinfo (scheme://user:pass@host).
looks_secret_value :: proc(value: string) -> bool {
	for prefix in SECRET_VALUE_PREFIXES {
		if strings.has_prefix(value, prefix) {
			return true
		}
	}
	if scheme_end := strings.index(value, "://"); scheme_end > 0 {
		rest := value[scheme_end + 3:]
		if at := strings.index_byte(rest, '@'); at > 0 {
			slash := strings.index_byte(rest, '/')
			if slash < 0 || at < slash {
				if strings.index_byte(rest[:at], ':') >= 0 {
					return true
				}
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
	if len(value) > 0 && looks_secret(name, value) {
		return SECRET_MASK
	}
	return value
}

// Value to show in a list view: the real value when `reveal` (`--reveal`,
// TUI reveal key), else masked like a preview. Never allocates.
list_display_value :: proc(name, value: string, reveal: bool) -> string {
	if reveal {
		return value
	}
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
