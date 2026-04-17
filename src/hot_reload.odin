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
		g_watcher.pid_file = fmt.aprintf("%s/%s", WAYU_CONFIG, WATCHER_PID_FILE)
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

	// Write PID file
	write_watcher_pid()

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

	print_success("Hot reload watcher stopped")
}

// Check if watcher is currently running
hot_reload_is_running :: proc() -> bool {
	sync.mutex_lock(&g_watcher.mutex)
	defer sync.mutex_unlock(&g_watcher.mutex)
	return g_watcher.watching
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
			fmt.println("Use 'wayu watch --stop' to stop it first")
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
	fmt.println("Usage: wayu watch [action] [options]")
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
	fmt.println("  wayu watch --stop       # Stop watching")
	fmt.println("  wayu watch status       # Check status")
	fmt.println()
	fmt.println("The watcher monitors:")
	fmt.println("  • wayu.toml configuration file")
	fmt.println("  • Path entries file")
	fmt.println("  • Aliases file")
	fmt.println("  • Constants file")
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

		// Sleep to avoid busy-waiting
		time.sleep(100 * time.Millisecond)
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

// Regenerate static configuration
regenerate_static :: proc() {
	print_info("Regenerating static configuration...")

	// Read TOML config
	toml_path := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG)
	defer delete(toml_path)

	config: TomlConfig
	config_ok := false

	if os.exists(toml_path) {
		content, read_ok := safe_read_file(toml_path)
		if read_ok {
			defer delete(content)
			config, config_ok = toml_parse(string(content))
		}
	}

	if !config_ok {
		config = static_config_from_files()
	}
	defer static_cleanup_config(&config)

	// Read lock file
	lock_path := fmt.aprintf("%s/wayu.lock", WAYU_CONFIG)
	defer delete(lock_path)

	lock: LockFile
	lock_ok := false

	if os.exists(lock_path) {
		lock, lock_ok = lock_read(lock_path)
	}

	// Generate static config
	static_config := static_generate(config, lock)
	defer static_cleanup_static_config(&static_config)

	// Write to file
	output_path := fmt.aprintf("%s/wayu_static.%s", WAYU_CONFIG, SHELL_EXT)
	defer delete(output_path)

	if static_write(output_path, static_config) {
		print_success("Static configuration regenerated")
		fmt.printfln("  File: %s", output_path)
		fmt.printfln("  Size: %d bytes", len(static_config.content))
	} else {
		print_error("Failed to regenerate static configuration")
	}
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
		g_watcher.pid_file = fmt.aprintf("%s/%s", WAYU_CONFIG, WATCHER_PID_FILE)
	}

	err := os.write_entire_file(g_watcher.pid_file, transmute([]byte)pid_str)
	if err != nil {
		print_warning("Could not write PID file: %s", g_watcher.pid_file)
	}
}

// Remove watcher PID file
remove_watcher_pid :: proc() {
	if g_watcher.pid_file == "" {
		return
	}

	if os.exists(g_watcher.pid_file) {
		os.remove(g_watcher.pid_file)
	}
}

// Read watcher PID from file
read_watcher_pid :: proc() -> int {
	pid_file := fmt.aprintf("%s/%s", WAYU_CONFIG, WATCHER_PID_FILE)
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

// Check if watcher is running (by PID file and process check)
is_watcher_running :: proc() -> bool {
	pid := read_watcher_pid()
	if pid <= 0 {
		return false
	}

	// Check if process exists
	proc_path := fmt.aprintf("/proc/%d", pid, allocator = context.temp_allocator)
	return os.exists(proc_path)
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
	toml_path := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG)
	if os.exists(toml_path) {
		append(&paths, toml_path)
	} else {
		delete(toml_path)
	}

	// Individual config files
	path_file := get_config_file_with_fallback("path", DETECTED_SHELL)
	if os.exists(path_file) {
		append(&paths, path_file)
	}
	delete(path_file)

	alias_file := get_config_file_with_fallback("aliases", DETECTED_SHELL)
	if os.exists(alias_file) {
		append(&paths, alias_file)
	}
	delete(alias_file)

	constants_file := get_config_file_with_fallback("constants", DETECTED_SHELL)
	if os.exists(constants_file) {
		append(&paths, constants_file)
	}
	delete(constants_file)

	result := make([]string, len(paths))
	for i := 0; i < len(paths); i += 1 {
		result[i] = paths[i]
	}
	return result
}
