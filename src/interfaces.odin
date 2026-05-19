// interfaces.odin - Shared types and interfaces for all workstreams
// This file is the contract between all parallel workstreams
//
// NOTE: This file contains ONLY type definitions. Function implementations
// are in other files to avoid redeclaration errors.

package wayu
import "core:log"
import "core:strings"
// ============================================================================
// VERSION
// ============================================================================

INTERFACES_VERSION :: "1.0.0"

// ============================================================================
// LOCK FILE SYSTEM
// ============================================================================

LockFile :: struct {
    version:      string,           // "1.0.0"
    generated_at: string,           // RFC3339 timestamp
    entries:      []LockEntry,
}

LockEntry :: struct {
    type:        ConfigType,
    name:        string,
    value:       string,           // For constants/aliases
    hash:        string,           // SHA256 of normalized content
    source:      string,           // URL, path, or "manual"
    added_at:    string,           // RFC3339
    modified_at: string,           // RFC3339
    metadata:    map[string]string, // Extensible metadata
}

ConfigType :: enum {
    PATH,
    ALIAS,
    CONSTANT,
    PLUGIN,
    COMPLETION,
}

// Note: Lock file operations (lock_read, lock_write, etc.) implemented in lock.odin

// ============================================================================
// TOML CONFIGURATION SYSTEM
// ============================================================================

TomlConfig :: struct {
    version:   string,                      // "1.0"
    shell:     string,                      // "zsh", "bash", "fish"
    wayu_version: string,                   // wayu version that created this

    // Core configuration
    path:      TomlPathConfig,
    aliases:   []TomlAlias,
    constants: []TomlConstant,
    plugins:   []TomlPlugin,

    // Advanced features
    profiles:  map[string]ProfileConfig,
    settings:  WayuSettings,
}

TomlPathConfig :: struct {
    entries:   []string,           // PATH entries
    dedup:     bool,               // Auto deduplicate
    clean:     bool,               // Auto clean missing
}

TomlAlias :: struct {
    name:        string,
    command:     string,
    description: string,           // Optional
}

TomlConstant :: struct {
    name:        string,
    value:       string,
    export:      bool,             // true = export, false = local
    secret:      bool,             // true = mask in logs
    description: string,
}

TomlPlugin :: struct {
    name:        string,
    source:      string,           // "github:user/repo", "local:/path", "https://..."
    version:     string,           // commit/tag/branch

    // Loading options
    defer_load:  bool,              // Load after prompt
    priority:    int,               // Lower = earlier (default 100)
    condition:   string,            // Conditional loading expression

    // Paths within plugin
    use:         []string,          // Files to source (default ["*.plugin.zsh"])

    // Metadata
    description: string,
}

ProfileConfig :: struct {
    // Overrides for this profile
    path:      ^TomlPathConfig,     // nil = inherit from base
    aliases:   []TomlAlias,         // Additional aliases
    constants: []TomlConstant,       // Additional constants
    plugins:   []TomlPlugin,         // Additional plugins

    // Activation condition
    condition: string,              // When to activate this profile
}

WayuSettings :: struct {
    auto_backup:      bool,           // Create backup on modify
    fuzzy_fallback: bool,            // Enable fuzzy matching on GET
    dry_run_default: bool,          // Default --dry-run for safety
    autosuggestions_accept_keys: []string, // ZLE sequences that accept autosuggestions
}

// Note: TOML operations (toml_parse, toml_validate, etc.) implemented in toml.odin

// ============================================================================
// OUTPUT FORMATS
// ============================================================================

OutputFormat :: enum {
    Plain,
    JSON,
    YAML,
}

// Note: Output operations implemented in output.odin

// ============================================================================
// STATIC GENERATION
// ============================================================================

StaticConfig :: struct {
    generated_at: string,
    wayu_version: string,
    shell:        string,
    content:      string,           // Generated shell script
}

// Note: Static generation operations implemented in static_gen.odin

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

EXIT_SUCCESS      :: 0   // Successful termination
EXIT_GENERAL      :: 1   // General unspecified error
EXIT_FAILURE      :: 1   // General error (alias for compatibility)
EXIT_USAGE        :: 64  // Command line usage error
EXIT_DATAERR      :: 65  // Data format error
EXIT_NOINPUT      :: 66  // Cannot open input
EXIT_UNAVAILABLE  :: 69  // Service unavailable
EXIT_SOFTWARE     :: 70  // Internal software error
EXIT_OSERR        :: 71  // System error (can't fork)
EXIT_OSFILE       :: 72  // Critical OS file missing
EXIT_CANTCREAT    :: 73  // Can't create output file
EXIT_IOERR        :: 74  // Input/output error
EXIT_NOPERM       :: 77  // Permission denied
EXIT_CONFIG       :: 78  // Configuration error
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
	if len(it.remaining) == 0 { return "", false }
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
