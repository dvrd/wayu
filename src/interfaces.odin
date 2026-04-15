// interfaces.odin - Shared types and interfaces for all workstreams
// This file is the contract between all parallel workstreams
// VERSION: 1.0.0 - DO NOT MODIFY WITHOUT COORDINATION

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

// Lock file operations - to be implemented by WS1 (Core Infrastructure)
lock_read :: proc(path: string) -> (LockFile, bool)
lock_write :: proc(path: string, lock: LockFile) -> bool
lock_generate_hash :: proc(entry: ConfigEntry) -> string
lock_add_entry :: proc(lock: ^LockFile, entry: LockEntry) -> bool
lock_remove_entry :: proc(lock: ^LockFile, name: string, type: ConfigType) -> bool
lock_find_entry :: proc(lock: LockFile, name: string, type: ConfigType) -> (LockEntry, bool)

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
    defer:       bool,              // Load after prompt
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
}

// TOML operations - to be implemented by WS2 (Config System)
toml_parse :: proc(content: string) -> (TomlConfig, bool)
toml_validate :: proc(config: TomlConfig) -> ValidationResult
toml_to_string :: proc(config: TomlConfig) -> string
toml_merge_profiles :: proc(base: TomlConfig, profile: string) -> TomlConfig
toml_get_active_profile :: proc(config: TomlConfig) -> string

// ============================================================================
// OUTPUT FORMATS
// ============================================================================

OutputFormat :: enum {
    Plain,
    JSON,
    YAML,
}

// Output operations - to be implemented by WS1 (Core Infrastructure)
output_format_set :: proc(format: OutputFormat)
output_get_current_format :: proc() -> OutputFormat

// JSON serialization
output_to_json :: proc(data: any) -> string
output_to_json_pretty :: proc(data: any) -> string
output_from_json :: proc(json_str: string, target: ^any) -> bool

// YAML serialization  
output_to_yaml :: proc(data: any) -> string

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

// Plugin operations - to be implemented by WS3 (Plugin System)
plugin_enhanced_install :: proc(plugin: EnhancedPlugin) -> bool
plugin_enhanced_remove :: proc(name: string) -> bool
plugin_enhanced_load :: proc(plugin: EnhancedPlugin) -> bool
plugin_enhanced_deferred_load :: proc(plugins: []EnhancedPlugin)
plugin_evaluate_condition :: proc(condition: string) -> bool

// ============================================================================
// STATIC GENERATION
// ============================================================================

StaticConfig :: struct {
    generated_at: string,
    wayu_version: string,
    shell:        string,
    content:      string,           // Generated shell script
}

// Static generation operations - to be implemented by WS4 (Performance)
static_generate :: proc(config: TomlConfig, lock: LockFile) -> StaticConfig
static_generate_path :: proc(entries: []string) -> string
static_generate_aliases :: proc(aliases: []TomlAlias) -> string
static_generate_constants :: proc(constants: []TomlConstant) -> string
static_generate_plugins :: proc(plugins: []TomlPlugin) -> string
static_optimize :: proc(content: string) -> string
static_write :: proc(path: string, static_config: StaticConfig) -> bool

// ============================================================================
// HOT RELOAD
// ============================================================================

FileWatcherEvent :: enum {
    Created,
    Modified,
    Deleted,
}

FileWatcherCallback :: proc(event: FileWatcherEvent, path: string)

// Hot reload operations - to be implemented by WS4 (Performance)
hot_reload_init :: proc(watch_paths: []string, callback: FileWatcherCallback)
hot_reload_start :: proc()
hot_reload_stop :: proc()
hot_reload_regenerate :: proc()

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

// Theme operations - to be implemented by WS5 (UI)
theme_list_available :: proc() -> []ThemeConfig
theme_apply :: proc(name: string) -> bool
theme_detect_starship :: proc() -> bool
theme_generate_starship_config :: proc() -> string

// ============================================================================
// SHELL SUPPORT
// ============================================================================

ShellType :: enum {
    Zsh,
    Bash,
    Fish,
}

ShellInfo :: struct {
    type:       ShellType,
    version:    string,
    config_file: string,           // ~/.zshrc, ~/.bashrc, etc.
    wayu_init_file: string,        // Where to source wayu
}

// Shell operations - to be implemented by WS6 (Integrations)
shell_fish_detect :: proc() -> bool
shell_fish_get_version :: proc() -> string
shell_fish_generate_init :: proc(config: TomlConfig) -> string
shell_fish_template_path :: proc() -> string
shell_fish_template_alias :: proc() -> string
shell_fish_template_constant :: proc() -> string

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

// Integration operations - to be implemented by WS6 (Integrations)
direnv_detect :: proc() -> bool
direnv_init :: proc() -> bool
direnv_generate_envrc :: proc(config: TomlConfig) -> string

mise_detect :: proc() -> bool
mise_sync_versions :: proc(config: TomlConfig) -> bool
mise_generate_tool_versions :: proc(config: TomlConfig) -> string

// ============================================================================
// VALIDATION
// ============================================================================

ValidationResult :: struct {
    valid:         bool,
    error_message: string,
    warnings:      []string,
}

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

// Benchmark operations - to be implemented by WS7 (QA)
benchmark_startup :: proc() -> BenchmarkResult
benchmark_plugin_load :: proc() -> BenchmarkResult
benchmark_list_operation :: proc() -> BenchmarkResult
benchmark_generate_static :: proc() -> BenchmarkResult

// ============================================================================
// UTILITY FUNCTIONS (Shared)
// ============================================================================

// Hash generation
hash_sha256 :: proc(data: string) -> string
hash_file :: proc(path: string) -> (string, bool)

// Time formatting
time_now_rfc3339 :: proc() -> string
time_parse_rfc3339 :: proc(s: string) -> (time.Time, bool)

// Path utilities
path_expand :: proc(path: string) -> string
path_normalize :: proc(path: string) -> string

// String utilities  
string_is_valid_identifier :: proc(s: string) -> bool
string_to_upper_snake_case :: proc(s: string) -> string
