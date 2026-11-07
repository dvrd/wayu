// secrets.odin - Single source of truth for secret handling:
//   * file modes for files that may contain [env] values (wayu.toml,
//     backups, generated core/lazy/login/helpers scripts).

package wayu

import "core:os"

// 0600 / 0700: owner-only. Anything holding [env] values is created with
// these; never wider than what the user chose for wayu.toml.
SECRET_FILE_PERMS :: os.Permissions{.Read_User, .Write_User}
SECRET_DIR_PERMS  :: os.Permissions{.Read_User, .Write_User, .Execute_User}

// Best-effort: tighten an existing file to 0600. Used for generated files
// whose pre-existing mode may predate this policy (O_CREAT ignores the
// mode argument for files that already exist).
restrict_file_mode :: proc(path: string) {
	if err := os.chmod(path, SECRET_FILE_PERMS); err != nil {
		debug("chmod 0600 failed for %s: %v", path, err)
	}
}
