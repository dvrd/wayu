// hot_reload.odin - File watcher with debounced auto-regeneration
//
// This module provides hot reload functionality for wayu configuration,
// automatically regenerating static files when source files change.

package wayu

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

// ============================================================================
// Types and State
// ============================================================================

WatcherState :: struct {
	watching:      bool,
	watched_paths: []string,
	callback:      FileWatcherCallback,
	debounce_ms:   int,
	last_modified: map[string]time.Time,
	thread:        ^thread.Thread,
	mutex:         sync.Mutex,
	stop_signal:   bool,
	pid_file:      string,
	// The first poll only records mtimes; after it, a watched file that
	// appears or disappears is a change too (secrets.json is created by the
	// first secret and may arrive by sync).
	primed:        bool,
}

// Global watcher state
g_watcher: WatcherState

// PID file for coordinating multiple watch instances
WATCHER_PID_FILE :: "watcher.pid"

// The running watcher holds a lockf lock on <data>/watcher.lock for its whole
// life (OKAMI-316). The kernel drops it when the watcher dies, so the lock,
// not the PID file, says whether a watcher runs: a PID file left by a dead
// watcher may name a reused PID that `stop` must never signal.
WATCHER_LOCK_FILE :: "watcher.lock"

// The lock file, open for the life of the watcher process (closing any
// descriptor of it would drop the lock).
@(private = "file")
_watcher_lock: ^os.File

// ============================================================================
// Core Watcher Functions
// ============================================================================

// Initialize file watcher with paths to watch
hot_reload_init :: proc(watch_paths: []string, callback: FileWatcherCallback) {
	sync.mutex_lock(&g_watcher.mutex)
	defer sync.mutex_unlock(&g_watcher.mutex)

	// Clean up any existing paths (the map's keys are those strings)
	clear(&g_watcher.last_modified)
	g_watcher.primed = false
	if g_watcher.watched_paths != nil {
		for path in g_watcher.watched_paths {
			delete(path)
		}
		delete(g_watcher.watched_paths)
	}

	// Store paths (clone them)
	g_watcher.watched_paths = make([]string, len(watch_paths))
	for i := 0; i < len(watch_paths); i += 1 {
		g_watcher.watched_paths[i] = strings.clone(watch_paths[i])
	}

	g_watcher.callback = callback
	g_watcher.debounce_ms = 500 // Default 500ms debounce
	g_watcher.stop_signal = false

	// Initialize last_modified map
	if g_watcher.last_modified == nil {
		g_watcher.last_modified = make(map[string]time.Time)
	}

	// Set up PID file path
	if g_watcher.pid_file == "" {
		g_watcher.pid_file = fmt.aprintf("%s/%s", wayu.data, WATCHER_PID_FILE)
	}
}

// Free the watched paths and mtimes (tests; the watcher process exits).
hot_reload_reset :: proc() {
	sync.mutex_lock(&g_watcher.mutex)
	defer sync.mutex_unlock(&g_watcher.mutex)
	delete(g_watcher.last_modified)
	g_watcher.last_modified = nil
	for path in g_watcher.watched_paths {delete(path)}
	delete(g_watcher.watched_paths)
	g_watcher.watched_paths = nil
	g_watcher.primed = false
	delete(g_watcher.pid_file)
	g_watcher.pid_file = ""
}

// Start the file watcher
hot_reload_start :: proc() {
	sync.mutex_lock(&g_watcher.mutex)
	defer sync.mutex_unlock(&g_watcher.mutex)

	if g_watcher.watching {
		print_warning("Watcher is already running")
		return
	}

	if len(g_watcher.watched_paths) == 0 {
		print_error("No paths configured for watching. Run hot_reload_init first.")
		return
	}

	// Write PID file; a SIGINT/SIGTERM/SIGHUP kill removes it again.
	write_watcher_pid()
	watcher_install_signal_handlers()

	// Reset stop signal
	g_watcher.stop_signal = false
	g_watcher.watching = true

	// Start watcher thread
	g_watcher.thread = thread.create_and_start(watcher_thread_proc)

	print_success("Hot reload watcher started")
	fmt.println("Watching paths:")
	for path in g_watcher.watched_paths {
		fmt.printfln("  • %s", path)
	}
	fmt.println()
	fmt.printfln("Debounce: %dms", g_watcher.debounce_ms)
	fmt.println("Press Ctrl+C to stop")
}

// Stop the file watcher
hot_reload_stop :: proc() {
	sync.mutex_lock(&g_watcher.mutex)
	defer sync.mutex_unlock(&g_watcher.mutex)

	if !g_watcher.watching {
		return
	}

	// Signal stop
	g_watcher.stop_signal = true
	g_watcher.watching = false

	// Wait for thread to finish (briefly)
	if g_watcher.thread != nil {
		tthread := g_watcher.thread
		g_watcher.thread = nil
		sync.mutex_unlock(&g_watcher.mutex)
		thread.join(tthread)
		thread.destroy(tthread)
		sync.mutex_lock(&g_watcher.mutex)
	}

	// Remove PID file
	remove_watcher_pid()
	watcher_uninstall_signal_handlers()

	print_success("Hot reload watcher stopped")
}

// Trigger manual regeneration
hot_reload_regenerate :: proc() {
	regenerate_static()
}

// ============================================================================
// CLI Commands
// ============================================================================

// Handle watch command
handle_watch_command :: proc(action: string, args: []string) {
	// Check for help flag early
	if action == "--help" || action == "-h" || action == "help" {
		print_watch_help()
		return
	}

	// Check if wayu is initialized
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	switch action {
	case "", "start":
		// Take the watcher lock first: it is the one "already running" check.
		if !watcher_lock_take() {
			print_warning("Watcher is already running")
			pid := read_watcher_pid()
			if pid > 0 {
				fmt.printfln("PID: %d", pid)
			}
			fmt.println("Use 'wayu watch stop' to stop it first")
			return
		}

		// Initialize and start
		paths := get_default_watch_paths()
		defer {
			for path in paths {
				delete(path)
			}
			delete(paths)
		}

		hot_reload_init(paths, default_file_change_callback)
		hot_reload_start()

		// Run indefinitely until interrupted
		keep_running := true
		for keep_running {
			time.sleep(100 * time.Millisecond)

			sync.mutex_lock(&g_watcher.mutex)
			keep_running = g_watcher.watching && !g_watcher.stop_signal
			sync.mutex_unlock(&g_watcher.mutex)
		}

		// Clean up on exit
		hot_reload_stop()

	case "stop":
		if !is_watcher_running() {
			print_warning("Watcher is not running")
			return
		}

		// Try to stop existing watcher
		pid := read_watcher_pid()
		if pid <= 0 {
			print_warning(
				"A watcher holds %s/%s but its PID file is missing",
				wayu.data,
				WATCHER_LOCK_FILE,
			)
			os.exit(EXIT_FAILURE)
		}
		stop_existing_watcher(pid)

		print_success("Watcher stopped")

	case "status":
		if is_watcher_running() {
			pid := read_watcher_pid()
			print_success("Watcher is running")
			if pid > 0 {
				fmt.printfln("PID: %d", pid)
			}
		} else {
			print_info("Watcher is not running")
		}

	case "regenerate", "regen":
		hot_reload_regenerate()

	case "help", "-h", "--help":
		print_watch_help()

	case:
		print_error("Unknown watch action: %s", action)
		print_watch_help()
		os.exit(EXIT_USAGE)
	}
}

// Print watch command help
print_watch_help :: proc() {
	print_header("Watch Command Help", "👁")
	fmt.println()
	fmt.println("Usage: wayu watch [start|stop|status|regenerate]   (alias: wayu reload)")
	fmt.println()
	fmt.println("Actions:")
	fmt.println("  start           Start watching for changes (default)")
	fmt.println("  stop            Stop the watcher")
	fmt.println("  status          Check if watcher is running")
	fmt.println("  regenerate      Manually trigger regeneration")
	fmt.println()
	fmt.println("Examples:")
	fmt.println("  wayu watch              # Start watching")
	fmt.println("  wayu watch start        # Start watching")
	fmt.println("  wayu watch stop         # Stop a watcher running elsewhere")
	fmt.println("  wayu watch status       # Check status")
	fmt.println()
	fmt.println("The watcher monitors:")
	fmt.println("  • wayu.toml")
	fmt.println("  • entries.json (PATH entries, aliases, constants)")
	fmt.println("  • secrets.json (encrypted constants)")
	fmt.println()
	fmt.println("Changes are debounced (500ms) before triggering regeneration.")
}

// ============================================================================
// Watcher Thread
// ============================================================================

// Thread procedure for file watching
watcher_thread_proc :: proc() {
	debounce_timer: time.Time
	pending_regen := false
	pending_secrets := false

	for {
		// Check stop signal
		sync.mutex_lock(&g_watcher.mutex)
		should_stop := g_watcher.stop_signal
		sync.mutex_unlock(&g_watcher.mutex)

		if should_stop {
			break
		}

		// Check for file changes
		changed_files := check_file_changes()
		defer {
			for file in changed_files {
				delete(file)
			}
			delete(changed_files)
		}

		if len(changed_files) > 0 {
			// Files changed - start/reset debounce timer
			debounce_timer = time.now()
			pending_regen = true

			for file in changed_files {
				print_info("Change detected: %s", file)
				if watch_path_is_secrets(file) do pending_secrets = true
			}
		}

		// Check if debounce period elapsed
		if pending_regen {
			elapsed := time.diff(debounce_timer, time.now())
			if elapsed >= time.Duration(g_watcher.debounce_ms) * time.Millisecond {
				// New values: drop the session cache so shells re-decrypt.
				if pending_secrets do secrets_cache_invalidate()
				regenerate_static()
				pending_regen = false
				pending_secrets = false
			}
		}

		// This thread polls forever: os.stat and regeneration allocate from
		// the (thread-local) temp allocator, which nothing else frees here.
		free_all(context.temp_allocator)

		// Sleep to avoid busy-waiting
		time.sleep(100 * time.Millisecond)
	}
}

// ============================================================================
// Signal handling
// ============================================================================

// PID file path as a C string, set before the handlers are installed so the
// handler only does async-signal-safe work (unlink + re-raise).
@(private = "file")
g_watcher_pid_cpath: cstring

@(private = "file")
WATCHER_SIGNALS :: [?]posix.Signal{.SIGINT, .SIGTERM, .SIGHUP}

@(private = "file")
watcher_signal_handler :: proc "c" (sig: posix.Signal) {
	if g_watcher_pid_cpath != nil {
		posix.unlink(g_watcher_pid_cpath)
	}
	// Default disposition so the exit status still reflects the signal.
	posix.signal(sig, auto_cast posix.SIG_DFL)
	posix.raise(sig)
}

watcher_install_signal_handlers :: proc() {
	if g_watcher.pid_file == "" {
		return
	}
	if g_watcher_pid_cpath != nil {
		delete(g_watcher_pid_cpath)
	}
	g_watcher_pid_cpath = strings.clone_to_cstring(g_watcher.pid_file)
	for sig in WATCHER_SIGNALS {
		posix.signal(sig, watcher_signal_handler)
	}
}

watcher_uninstall_signal_handlers :: proc() {
	for sig in WATCHER_SIGNALS {
		posix.signal(sig, auto_cast posix.SIG_DFL)
	}
	if g_watcher_pid_cpath != nil {
		delete(g_watcher_pid_cpath)
		g_watcher_pid_cpath = nil
	}
}

// Check all watched files for modifications
check_file_changes :: proc() -> []string {
	changed := make([dynamic]string)

	sync.mutex_lock(&g_watcher.mutex)
	defer sync.mutex_unlock(&g_watcher.mutex)

	for path in g_watcher.watched_paths {
		last_mod, seen := g_watcher.last_modified[path]
		file_info, err := os.stat(path, context.temp_allocator)
		if err != nil {
			// Gone (or unreadable): a change when it was there before.
			if seen {
				delete_key(&g_watcher.last_modified, path)
				append(&changed, strings.clone(path))
			}
			continue
		}
		if !seen || time.diff(last_mod, file_info.modification_time) > 0 {
			g_watcher.last_modified[path] = file_info.modification_time
			// New since the first poll, or modified.
			if seen || g_watcher.primed {
				append(&changed, strings.clone(path))
			}
		}
	}
	g_watcher.primed = true

	defer delete(changed)
	result := make([]string, len(changed))
	for i := 0; i < len(changed); i += 1 {
		result[i] = changed[i]
	}
	return result
}

// ============================================================================
// Regeneration
// ============================================================================

// Regenerate the shell init files (core + path_sync + plugin runtime)
// from wayu.toml and entries.json. These are the files init.<ext> actually
// sources, so a hot reload is picked up by the next shell (or by sourcing
// <data>/init.<ext> again).
// The old implementation wrote an orphaned wayu_static.<ext> that nothing
// sourced and crashed on missing/malformed TOML.
regenerate_static :: proc() {
	print_info("Regenerating shell init files...")

	toml_path := fmt.aprintf("%s/wayu.toml", wayu.config)
	defer delete(toml_path)
	if !os.exists(toml_path) {
		print_warning("No wayu.toml found at %s - nothing to regenerate", toml_path)
		return
	}

	// Scripts first: a first built script puts <data>/bin on PATH.
	if built, failed := scripts_build_stale(quiet = true); built > 0 || failed > 0 {
		print_info("Scripts rebuilt: %d, failed: %d", built, failed)
	}
	regenerate_init_core_silently()

	core_path := fmt.aprintf("%s/core.%s", wayu.data, get_shell_extension(wayu.shell))
	defer delete(core_path)
	print_success("Shell init files regenerated")
	fmt.printfln("  File: %s", core_path)
}

// Default callback for file changes
default_file_change_callback :: proc(event: FileWatcherEvent, path: string) {
	// This is called from the debounced handler
	// The actual regeneration happens in watcher_thread_proc
	#partial switch event {
	case .Created:
		print_info("File created: %s", path)
	case .Modified:
		print_info("File modified: %s", path)
	case .Deleted:
		print_info("File deleted: %s", path)
	}
}

// ============================================================================
// PID File Management
// ============================================================================

// Write watcher PID file
write_watcher_pid :: proc() {
	pid := os.get_pid()
	pid_str := fmt.aprintf("%d", pid)
	defer delete(pid_str)

	if g_watcher.pid_file == "" {
		g_watcher.pid_file = fmt.aprintf("%s/%s", wayu.data, WATCHER_PID_FILE)
	}

	err := os.write_entire_file(g_watcher.pid_file, transmute([]byte)pid_str)
	if err != nil {
		print_warning("Could not write PID file: %s", g_watcher.pid_file)
	}
}

// Remove watcher PID file.
//
// Falls back to the canonical path when g_watcher.pid_file is empty, which
// happens when `stop` / `status` run in a different process than `start`
// (globals aren't shared across processes).
remove_watcher_pid :: proc() {
	path := g_watcher.pid_file
	ownership := false
	if path == "" {
		path = fmt.aprintf("%s/%s", wayu.data, WATCHER_PID_FILE)
		ownership = true
	}
	defer if ownership do delete(path)

	if os.exists(path) {
		os.remove(path)
	}
}

// Read watcher PID from file
read_watcher_pid :: proc() -> int {
	pid_file := fmt.aprintf("%s/%s", wayu.data, WATCHER_PID_FILE)
	defer delete(pid_file)

	if !os.exists(pid_file) {
		return 0
	}

	content, read_err := os.read_entire_file(pid_file, context.temp_allocator)
	if read_err != nil {
		return 0
	}

	pid_str := strings.trim_space(string(content))
	pid, _ := strconv.parse_int(pid_str)
	return pid
}

// Take the watcher lock for the life of this process. False when another
// process holds it (a watcher runs); exits EXIT_IOERR when the lock file
// cannot be opened.
watcher_lock_take :: proc() -> bool {
	if _watcher_lock != nil {
		return true
	}
	if !os.is_dir(wayu.data) {
		_ = make_directory_all(wayu.data)
	}
	path := fmt.tprintf("%s/%s", wayu.data, WATCHER_LOCK_FILE)
	f, err := os.open(path, {.Read, .Write, .Create}, os.perm_number(0o600))
	if err != nil {
		print_error("Cannot open %s: %v", path, err)
		os.exit(EXIT_IOERR)
	}
	if posix.lockf(posix.FD(os.fd(f)), .TLOCK, 0) != .OK {
		os.close(f)
		return false
	}
	_watcher_lock = f
	return true
}

// Is a watcher running: does another process hold <data>/watcher.lock?
// The PID file alone is no proof (OKAMI-316). When no watcher holds the
// lock, a leftover PID file is removed.
is_watcher_running :: proc() -> bool {
	if _watcher_lock != nil {
		return true // this process is the watcher
	}
	path := fmt.tprintf("%s/%s", wayu.data, WATCHER_LOCK_FILE)
	held := false
	if f, err := os.open(path, {.Read, .Write}); err == nil {
		fd := posix.FD(os.fd(f))
		if posix.lockf(fd, .TLOCK, 0) == .OK {
			_ = posix.lockf(fd, .ULOCK, 0)
		} else {
			held = true
		}
		os.close(f)
	}
	if !held {
		remove_watcher_pid()
	}
	return held
}

// Stop the watcher `pid` (read from the PID file while the watcher lock was
// held): SIGTERM, then SIGKILL if it still holds the lock after 2 s.
stop_existing_watcher :: proc(pid: int) {
	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		posix.kill(posix.pid_t(pid), posix.Signal.SIGTERM)
		for _ in 0 ..< 40 {
			time.sleep(50 * time.Millisecond)
			if !is_watcher_running() {
				return
			}
		}
		posix.kill(posix.pid_t(pid), posix.Signal.SIGKILL)
		time.sleep(100 * time.Millisecond)
	}
	remove_watcher_pid()
}

// ============================================================================
// Helper Functions
// ============================================================================

// Is `path` the encrypted store (<data>/secrets.json)?
watch_path_is_secrets :: proc(path: string) -> bool {
	return path == secrets_store_path()
}

// Get default paths to watch
get_default_watch_paths :: proc() -> []string {
	paths := make([dynamic]string)

	// Main TOML config + the entry store
	for p in ([]string {
			fmt.aprintf("%s/wayu.toml", wayu.config),
			entries_file_path(context.allocator),
		}) {
		if os.exists(p) {
			append(&paths, p)
		} else {
			delete(p)
		}
	}

	// secrets.json, also before the first secret creates it: new values
	// invalidate the session cache, and an empty/non-empty store changes
	// core's Secrets section (OKAMI-361).
	append(&paths, strings.clone(secrets_store_path()))

	// Script sources: an edit rebuilds the script (regenerate_static).
	script_watch_paths(&paths)

	defer delete(paths)
	result := make([]string, len(paths))
	for i := 0; i < len(paths); i += 1 {
		result[i] = paths[i]
	}
	return result
}
