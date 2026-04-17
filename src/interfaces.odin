// interfaces.odin - Shared types and interfaces for all workstreams
// This file is the contract between all parallel workstreams
// VERSION: 1.0.0 - DO NOT MODIFY WITHOUT COORDINATION
//
// NOTE: This file contains ONLY type definitions. Function implementations
// are in other files to avoid redeclaration errors.

package wayu

import "core:time"

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

// Note: TOML operations (toml_parse, toml_validate, etc.) implemented in config_toml.odin

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
// PLUGIN SYSTEM ENHANCED
// ============================================================================

PluginSource :: enum {
    GitHub,
    GitLab,
    Bitbucket,
    Local,
    Remote,      // Direct URL
    Git,         // Generic git repo
}

PluginLoadMode :: enum {
    Immediate,   // Load now
    Deferred,    // Load after first prompt
    Lazy,        // Load on first use
    Conditional, // Load if condition met
}

PluginStatus :: enum {
    NotInstalled,
    Installed,
    Enabled,
    Disabled,
    Error,
}

EnhancedPlugin :: struct {
    name:        string,
    source:      PluginSource,
    source_url:  string,           // Full URL or path
    
    // Version management
    version:     string,           // Current version (commit/tag)
    wanted_version: string,        // Desired version
    
    // Loading configuration
    load_mode:   PluginLoadMode,
    priority:    int,               // Loading order
    condition:   string,            // Conditional expression
    
    // Installation
    install_path: string,          // Where it's installed
    use_files:   []string,          // Which files to source
    
    // Status
    status:      PluginStatus,
    last_update: string,           // RFC3339
    
    // Metadata
    description: string,
    author:      string,
    homepage:    string,
}

// Note: Plugin operations implemented in plugin files

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
// THEMES AND PROMPTS
// ============================================================================

ThemeType :: enum {
    Minimal,
    Powerline,
    Starship,      // External
    Custom,
}

ThemeConfig :: struct {
    name:        string,
    type:        ThemeType,
    starship_config: string,       // Path to starship.toml if applicable
    custom_prompt: string,         // For custom themes
    colors:      map[string]string, // Color definitions
}

// Note: Theme operations to be implemented

// ============================================================================
// SHELL SUPPORT
// ============================================================================

// Note: ShellType defined in shell.odin (BASH, ZSH, UNKNOWN)
// Note: ValidationResult defined in validation.odin

ShellInfo :: struct {
    type:       ShellType,
    version:    string,
    config_file: string,           // ~/.zshrc, ~/.bashrc, etc.
    wayu_init_file: string,        // Where to source wayu
}

// Note: Fish shell operations to be implemented

// ============================================================================
// INTEGRATIONS
// ============================================================================

DirenvConfig :: struct {
    enabled:     bool,
    auto_allow:  bool,
    aliases:     []string,          // Allow aliases in .envrc
}

MiseConfig :: struct {
    enabled:     bool,
    auto_sync:   bool,
    tools:       map[string]string, // tool -> version
}

// Note: Integration operations to be implemented

// ============================================================================
// BENCHMARKING
// ============================================================================

BenchmarkResult :: struct {
    name:        string,
    duration_ms: f64,
    iterations:  int,
    avg_ms:      f64,
    min_ms:      f64,
    max_ms:      f64,
}

BenchmarkSuite :: struct {
    timestamp: string,
    wayu_version: string,
    system_info: string,
    results: []BenchmarkResult,
}

// Note: Benchmark operations to be implemented

// ============================================================================
// UTILITY FUNCTIONS (Shared)
// ============================================================================

// Note: Utility functions implemented in their respective modules
