// hot_reload.odin - File watcher with debounced auto-regeneration
//
// This module provides hot reload functionality for wayu configuration,
// automatically regenerating static files when source files change.

package wayu

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:sync"
import "core:thread"
import "core:sys/posix"

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
}

// Global watcher state
g_watcher: WatcherState

// PID file for coordinating multiple watch instances
WATCHER_PID_FILE :: "watcher.pid"

// ============================================================================
// Core Watcher Functions
// ============================================================================

// Initialize file watcher with paths to watch
hot_reload_init :: proc(watch_paths: []string, callback: FileWatcherCallback) {
	sync.mutex_lock(&g_watcher.mutex)
	defer sync.mutex_unlock(&g_watcher.mutex)

	// Clean up any existing paths
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
		// Check if already running
		if is_watcher_running() {
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
		if pid > 0 {
			stop_existing_watcher(pid)
		}

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
			}
		}

		// Check if debounce period elapsed
		if pending_regen {
			elapsed := time.diff(debounce_timer, time.now())
			if elapsed >= time.Duration(g_watcher.debounce_ms) * time.Millisecond {
				regenerate_static()
				pending_regen = false
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
@(private="file")
g_watcher_pid_cpath: cstring

@(private="file")
WATCHER_SIGNALS :: [?]posix.Signal{.SIGINT, .SIGTERM, .SIGHUP}

@(private="file")
watcher_signal_handler :: proc "c" (sig: posix.Signal) {
	if g_watcher_pid_cpath != nil {
		posix.unlink(g_watcher_pid_cpath)
	}
	// Default disposition so the exit status still reflects the signal.
	posix.signal(sig, auto_cast posix.SIG_DFL)
	posix.raise(sig)
}

watcher_install_signal_handlers :: proc() {
	if g_watcher.pid_file == "" { return }
	if g_watcher_pid_cpath != nil { delete(g_watcher_pid_cpath) }
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
		if !os.exists(path) {
			continue
		}

		// Get file info
		file_info, err := os.stat(path, context.temp_allocator)
		if err != nil {
			continue
		}

		// Check modification time
		last_mod, exists := g_watcher.last_modified[path]
		if !exists || time.diff(last_mod, file_info.modification_time) > 0 {
			g_watcher.last_modified[path] = file_info.modification_time
			if exists {
				// File was modified (not first check)
				append(&changed, strings.clone(path))
			}
		}
	}

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
// from wayu.toml. These are the files init.<ext> actually sources, so a hot
// reload is picked up by the next shell (or `source ~/.config/wayu/init.<ext>`).
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

// Check if watcher is running (by PID file and process check).
//
// Uses the portable `kill(pid, 0)` probe: sends signal 0 (no-op, just permission
// check) and relies on the kernel to answer "no such process" via ESRCH when
// the PID is gone. /proc/<pid> only works on Linux, so we used to always
// return false on macOS/BSD.
is_watcher_running :: proc() -> bool {
	pid := read_watcher_pid()
	if pid <= 0 {
		return false
	}

	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		if posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK {
			return true
		}
		// errno == ESRCH: no such process → stale PID file, clean it up so
		// future status calls don't keep probing a ghost.
		if posix.errno() == .ESRCH {
			remove_watcher_pid()
			return false
		}
		// EPERM means the process exists but we can't signal it — still "running".
		return posix.errno() == .EPERM
	} else {
		return false
	}
}

// Stop existing watcher by sending signal
stop_existing_watcher :: proc(pid: int) {
	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		// Try graceful termination first (SIGTERM)
		posix.kill(posix.pid_t(pid), posix.Signal.SIGTERM)

		// Wait briefly for termination
		time.sleep(500 * time.Millisecond)

		// Check if still running
		if is_watcher_running() {
			// Force kill (SIGKILL)
			posix.kill(posix.pid_t(pid), posix.Signal.SIGKILL)
		}
	}

	// Clean up PID file
	remove_watcher_pid()
}

// ============================================================================
// Helper Functions
// ============================================================================

// Get default paths to watch
get_default_watch_paths :: proc() -> []string {
	paths := make([dynamic]string)

	// Main TOML config
	toml_path := fmt.aprintf("%s/wayu.toml", wayu.config)
	if os.exists(toml_path) {
		append(&paths, toml_path)
	} else {
		delete(toml_path)
	}

	result := make([]string, len(paths))
	for i := 0; i < len(paths); i += 1 {
		result[i] = paths[i]
	}
	return result
}
