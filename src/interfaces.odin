// interfaces.odin - Shared types and interfaces for all workstreams
// This file is the contract between all parallel workstreams
//
// NOTE: This file contains ONLY type definitions. Function implementations
// are in other files to avoid redeclaration errors.

package wayu
@(require) import "core:log"
import "core:strings" // used by debug() under ODIN_DEBUG only
// ============================================================================
// TOML CONFIGURATION SYSTEM
// ============================================================================

// wayu.toml (hand-edited settings). PATH entries, aliases and constants are
// not here: they live in the entry store (entries.odin).
TomlConfig :: struct {
	version:  string, // "1.0"
	shell:    string, // "zsh", "bash", "fish"
	settings: WayuSettings,
}

WayuSettings :: struct {
	autosuggestions_accept_keys: []string, // ZLE sequences that accept autosuggestions
}

// Note: TOML operations (toml_parse, toml_validate, etc.) implemented in toml.odin

// ============================================================================
// HOT RELOAD
// ============================================================================

FileWatcherEvent :: enum {
	Created,
	Modified,
	Deleted,
}

FileWatcherCallback :: proc(event: FileWatcherEvent, path: string)

// Note: Hot reload operations implemented in hot_reload.odin

// ============================================================================
// Exit codes (BSD sysexits.h compatible)
// Used for proper scripting and CI/CD integration

EXIT_SUCCESS :: 0 // Successful termination
EXIT_GENERAL :: 1 // General unspecified error
EXIT_FAILURE :: 1 // General error (alias for compatibility)
EXIT_USAGE :: 64 // Command line usage error
EXIT_DATAERR :: 65 // Data format error
EXIT_NOINPUT :: 66 // Cannot open input
EXIT_UNAVAILABLE :: 69 // Service unavailable
EXIT_SOFTWARE :: 70 // Internal software error
EXIT_OSERR :: 71 // System error (can't fork)
EXIT_OSFILE :: 72 // Critical OS file missing
EXIT_CANTCREAT :: 73 // Can't create output file
EXIT_IOERR :: 74 // Input/output error
EXIT_NOPERM :: 77 // Permission denied
EXIT_CONFIG :: 78 // Configuration error
// `wayu secrets run`: CMD could not be executed (shell convention).
EXIT_EXEC_NOT_RUNNABLE :: 126 // found but not executable
EXIT_EXEC_NOT_FOUND :: 127 // not found on PATH
// Debug logging that only activates when built with -define:DEBUG=true
debug :: proc(msg: string, args: ..any) {
	when ODIN_DEBUG {
		log.debugf(msg, ..args)
	}
}

// ============================================================================
// ZERO-ALLOCATION LINE ITERATOR
// ============================================================================

// LineIterator walks a string line-by-line without allocating a []string.
// Usage:
//   it := make_line_iter(content)
//   for line in line_iter_next(&it) { ... }
LineIterator :: struct {
	remaining: string,
}

make_line_iter :: proc(s: string) -> LineIterator {
	return LineIterator{remaining = s}
}

line_iter_next :: proc(it: ^LineIterator) -> (line: string, ok: bool) {
	if len(it.remaining) == 0 {
		return "", false
	}
	nl := strings.index_byte(it.remaining, '\n')
	if nl < 0 {
		line = it.remaining
		it.remaining = ""
	} else {
		line = it.remaining[:nl]
		it.remaining = it.remaining[nl + 1:]
	}
	return line, true
}
