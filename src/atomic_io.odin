// atomic_io.odin - Crash-safe file replacement and the inter-process config lock.
//
// Every persistent wayu write (wayu.toml, plugins.json, generated runtime
// files) goes through write_file_atomic so readers — other wayu processes,
// shells sourcing core.zsh, the reload watcher — only ever see the old or the
// new file, never a truncated one. Read-modify-write sequences additionally
// hold config_lock so concurrent `wayu ... add` runs serialise instead of
// dropping each other's entries.
package wayu

import "core:fmt"
import "core:io"
import "base:runtime"
import "core:math/rand"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

// Mode for files that do not exist yet (existing files keep their own mode).
// 0600: wayu.toml and the generated files can carry secrets (OKAMI-206).
ATOMIC_DEFAULT_MODE :: os.Permissions{.Read_User, .Write_User}

// Upper bound on symlink hops when resolving the real write target.
@(private = "file")
ATOMIC_MAX_SYMLINK_HOPS :: 16

// Upper bound on temp-name collisions before giving up.
@(private = "file")
ATOMIC_MAX_TMP_ATTEMPTS :: 8

// Replace `path` with `data` atomically: write a uniquely named temp file in
// the same directory (pid + random suffix, O_EXCL), fsync it, then rename it
// over the target. Symlinks are followed so a stow-style symlinked config
// keeps its link and the real file is replaced. An existing file keeps its
// permission bits; new files get ATOMIC_DEFAULT_MODE.
write_file_atomic :: proc(path: string, data: []byte) -> os.Error {
	// Private scratch arena: callers (e.g. the generators) may have exhausted
	// the CLI's fixed 256KB temp arena, which would turn every tprintf here
	// into "" and silently fail the write.
	scratch_arena: virtual.Arena
	if err := virtual.arena_init_growing(&scratch_arena); err != nil { return err }
	defer virtual.arena_destroy(&scratch_arena)
	scratch := virtual.arena_allocator(&scratch_arena)

	target, resolve_err := atomic_resolve_target(path, scratch)
	if resolve_err != nil { return resolve_err }

	mode := ATOMIC_DEFAULT_MODE
	if fi, err := os.stat(target, scratch); err == nil {
		mode = fi.mode
	}

	dir, base := os.split_path(target)
	if len(dir) == 0 { dir = "." }

	tmp_file: ^os.File
	tmp_path: string
	open_err: os.Error
	for attempt in 0..<ATOMIC_MAX_TMP_ATTEMPTS {
		suffix := rand.uint64() ~ u64(time.now()._nsec) ~ u64(attempt)
		tmp_path = fmt.aprintf("%s/.%s.tmp.%d.%x", dir, base, os.get_pid(), suffix, allocator = scratch)
		tmp_file, open_err = os.open(tmp_path, {.Write, .Create, .Excl}, mode)
		if open_err != os.General_Error.Exist { break }
	}
	if open_err != nil { return open_err }

	ok := false
	defer if !ok { os.remove(tmp_path) }

	{
		defer os.close(tmp_file)
		written := 0
		for written < len(data) {
			n, werr := os.write(tmp_file, data[written:])
			if werr != nil { return werr }
			if n <= 0 { return io.Error.Short_Write }
			written += n
		}
		// The umask may have stripped bits from `mode` at create time.
		if err := os.fchmod(tmp_file, mode); err != nil { return err }
		if err := os.sync(tmp_file); err != nil { return err }
	}

	if err := os.rename(tmp_path, target); err != nil { return err }
	ok = true

	// Best effort: persist the rename itself. Not all filesystems allow
	// fsync on a directory handle, so a failure here is not an error.
	if d, err := os.open(dir); err == nil {
		_ = os.sync(d)
		os.close(d)
	}
	return nil
}

// Follow symlinks from `path` to the file that should actually be replaced.
// A path that does not exist yet resolves to itself.
@(private = "file")
atomic_resolve_target :: proc(path: string, allocator: runtime.Allocator) -> (string, os.Error) {
	current := path
	for _ in 0..<ATOMIC_MAX_SYMLINK_HOPS {
		fi, err := os.lstat(current, allocator)
		if err != nil || fi.type != .Symlink { return current, nil }
		link, lerr := os.read_link(current, allocator)
		if lerr != nil { return "", lerr }
		if strings.has_prefix(link, "/") {
			current = link
		} else {
			dir, _ := os.split_path(current)
			current = fmt.aprintf("%s/%s", dir, link, allocator = allocator)
		}
	}
	return "", os.General_Error.Invalid_Path
}

// ---------------------------------------------------------------------------
// Inter-process config lock
// ---------------------------------------------------------------------------
//
// One advisory lock file (`<config>/.wayu.lock`) guards every
// read-modify-write of wayu.toml and plugins.json, plus the regeneration that
// follows, so a single lock order exists and deadlock is impossible.
//
// POSIX record locks (lockf) are per process and are dropped when ANY
// descriptor of the file is closed, so the lock is reference counted and the
// file is opened exactly once per process. Nested acquire/release pairs
// (e.g. `path clean` → regenerate) are therefore free.

CONFIG_LOCK_FILE :: ".wayu.lock"

@(private = "file")
_config_lock: struct {
	file:  ^os.File,
	depth: int,
}

// Block until this process holds the config lock. Returns false (after
// printing why) when the lock file cannot be opened or locked. Under
// --dry-run nothing is written, so no lock is taken. Pair every successful
// call with config_lock_release.
config_lock_acquire :: proc() -> bool {
	if _config_lock.depth > 0 || wayu.dry_run {
		_config_lock.depth += 1
		return true
	}

	dir := wayu.config
	if !os.is_dir(dir) { dir = wayu.data }
	if !os.is_dir(dir) {
		// Nothing on disk to protect yet (first run before init).
		_config_lock.depth += 1
		return true
	}

	lock_path := fmt.tprintf("%s/%s", dir, CONFIG_LOCK_FILE)
	f, err := os.open(lock_path, {.Read, .Write, .Create}, os.perm_number(0o600))
	if err != nil {
		print_error("Cannot open lock file %s: %v", lock_path, err)
		return false
	}

	fd := posix.FD(os.fd(f))
	for {
		if posix.lockf(fd, .LOCK, 0) == .OK { break }
		if posix.errno() == .EINTR { continue }
		print_error("Cannot lock %s: %s", lock_path, posix.strerror(posix.errno()))
		os.close(f)
		return false
	}

	_config_lock.file = f
	_config_lock.depth = 1
	return true
}

// Release one level of the config lock; the OS lock is dropped when the
// outermost holder releases.
config_lock_release :: proc() {
	assert(_config_lock.depth > 0, "config_lock_release without acquire")
	_config_lock.depth -= 1
	if _config_lock.depth > 0 || _config_lock.file == nil { return }

	_ = posix.lockf(posix.FD(os.fd(_config_lock.file)), .ULOCK, 0)
	os.close(_config_lock.file)
	_config_lock.file = nil
}

// CLI convenience: take the lock or exit with EXIT_IOERR. Callers still
// `defer config_lock_release()`.
config_lock_acquire_or_exit :: proc() {
	if !config_lock_acquire() { os.exit(EXIT_IOERR) }
}
