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

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

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

// Create `dir` owner-only: missing parents with the default mode, the leaf
// with mkdir 0700 plus an explicit chmod (the umask never widens it, but a
// pre-set umask such as 0 must not matter either). An existing dir is left
// as it is (see private_dir_tighten). err is temp-allocated.
private_dir_make :: proc(dir: string) -> (ok: bool, err: string) {
	if os.exists(dir) {
		return true, ""
	}
	parent, _ := os.split_path(dir)
	if len(parent) > 0 && !os.exists(parent) {
		if e := os.make_directory_all(parent); e != nil {
			return false, fmt.tprintf("cannot create %s: %v", parent, e)
		}
	}
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	if posix.mkdir(cdir, posix.S_IRWXU) != .OK {
		if posix.errno() != .EEXIST {
			return false, fmt.tprintf("cannot create %s: %s", dir, posix.strerror(posix.errno()))
		}
		return true, "" // created concurrently: not ours to chmod
	}
	if posix.chmod(cdir, posix.S_IRWXU) != .OK {
		return false, fmt.tprintf("cannot chmod %s: %s", dir, posix.strerror(posix.errno()))
	}
	return true, ""
}

// Create `dir` (private_dir_make) or make an existing one private: it must
// be a real directory (not a symlink) owned by us, and loses any group/other
// permission bits. Opened with O_NOFOLLOW and changed with fchmod, so a
// swapped-in symlink is never followed. err is temp-allocated.
private_dir_ensure :: proc(dir: string) -> (ok: bool, err: string) {
	if mok, merr := private_dir_make(dir); !mok {
		return false, merr
	}
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	fd := posix.open(cdir, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if fd < 0 {
		return false, fmt.tprintf(
			"%s is not a directory we can open (symlink?): %s",
			dir,
			posix.strerror(posix.errno()),
		)
	}
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK {
		return false, fmt.tprintf("cannot stat %s: %s", dir, posix.strerror(posix.errno()))
	}
	if st.st_uid != posix.getuid() {
		return false, fmt.tprintf("%s is owned by another user", dir)
	}
	if st.st_mode & (posix.S_IRWXG | posix.S_IRWXO) != {} {
		if posix.fchmod(fd, posix.S_IRWXU) != .OK {
			return false, fmt.tprintf("cannot chmod %s: %s", dir, posix.strerror(posix.errno()))
		}
	}
	return true, ""
}

// Is `path` a regular file (lstat: a symlink is not)?
is_regular_file_nofollow :: proc(path: string) -> bool {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK {
		return false
	}
	return posix.S_ISREG(st.st_mode)
}

// Is `path` itself a symlink (lstat)?
is_symlink_nofollow :: proc(path: string) -> bool {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK {
		return false
	}
	return posix.S_ISLNK(st.st_mode)
}
