# TOML Configuration System

This document describes the TOML configuration system implemented for wayu.

## Overview

The TOML configuration system provides a modern, structured way to configure wayu using TOML syntax instead of shell scripts. It supports:

- Full TOML parsing and serialization
- Profile-based configuration switching
- Validation of configuration values
- Migration from existing shell configs

## Files Added/Modified

### New Files

- `src/config_toml.odin` - TOML parser, validator, and serializer (~1100 lines)
- `tests/unit/test_toml.odin` - Comprehensive unit tests (~650 lines)
- `examples/wayu.toml` - Example configuration file with all features
- `docs/TOML_CONFIG.md` - This documentation

### Modified Files

- `src/interfaces.odin` - Fixed type definitions and removed conflicting function declarations
- `src/static_gen.odin` - Fixed `defer` -> `defer_load` field name
- `src/hot_reload.odin` - Fixed syntax errors in foreign function declarations

## Usage

### Create TOML Config

```bash
wayu init --toml
```

This creates a new `wayu.toml` file in `~/.config/wayu/`.

### Validate Config

```bash
wayu validate
```

Validates the TOML syntax and configuration values.

### Use Profile

```bash
wayu --profile work
```

Activates the specified profile, merging it with the base configuration.

### Convert Existing Config

```bash
wayu convert --to-toml
```

Migrates existing shell-based configuration to TOML format.

## Configuration Format

### Basic Structure

```toml
version = "1.0"
shell = "zsh"
wayu_version = "3.4.0"

[path]
entries = ["/usr/local/bin", "$HOME/.local/bin"]
dedup = true
clean = false

[[aliases]]
name = "ll"
command = "ls -la"
description = "List all files"

[[constants]]
name = "EDITOR"
value = "nvim"
export = true
secret = false

[[plugins]]
name = "zsh-autosuggestions"
source = "github:zsh-users/zsh-autosuggestions"
defer = true
priority = 50

[settings]
auto_backup = true
fuzzy_fallback = true
dry_run_default = false
```

### Profiles

Profiles allow environment-specific configurations:

```toml
[profile.work]
condition = "test -f /work/.env"

[profile.work.path]
entries = ["/work/tools/bin"]

[[profile.work.aliases]]
name = "deploy"
command = "make deploy"

[[profile.work.constants]]
name = "WORK_ENV"
value = "production"
```

Activate a profile with: `wayu --profile work`

## API Reference

### TOML Operations

```odin
// Parse TOML content into config
toml_parse :: proc(content: string) -> (TomlConfig, bool)

// Validate configuration
toml_validate :: proc(config: TomlConfig) -> ValidationResult

// Serialize config to TOML string
toml_to_string :: proc(config: TomlConfig) -> string

// Merge profile into base config
toml_merge_profiles :: proc(base: TomlConfig, profile: string) -> TomlConfig

// Get active profile based on conditions
toml_get_active_profile :: proc(config: TomlConfig) -> string
```

### File Operations

```odin
// Read config from file
toml_read_file :: proc(path: string) -> (TomlConfig, bool)

// Write config to file
toml_write_file :: proc(path: string, config: TomlConfig) -> bool

// Get default config path
toml_get_config_path :: proc() -> string

// Create default config
toml_create_default :: proc() -> TomlConfig
```

## Data Types

### TomlConfig

```odin
TomlConfig :: struct {
    version:      string,
    shell:        string,
    wayu_version: string,
    path:         TomlPathConfig,
    aliases:      []TomlAlias,
    constants:    []TomlConstant,
    plugins:      []TomlPlugin,
    profiles:     map[string]ProfileConfig,
    settings:     WayuSettings,
}
```

### TomlPathConfig

```odin
TomlPathConfig :: struct {
    entries: []string,
    dedup:   bool,
    clean:   bool,
}
```

### TomlAlias

```odin
TomlAlias :: struct {
    name:        string,
    command:     string,
    description: string,
}
```

### TomlConstant

```odin
TomlConstant :: struct {
    name:        string,
    value:       string,
    export:      bool,
    secret:      bool,
    description: string,
}
```

### TomlPlugin

```odin
TomlPlugin :: struct {
    name:        string,
    source:      string,
    version:     string,
    defer_load:  bool,
    priority:    int,
    condition:   string,
    use:         []string,
    description: string,
}
```

### ProfileConfig

```odin
ProfileConfig :: struct {
    path:      ^TomlPathConfig,
    aliases:   []TomlAlias,
    constants: []TomlConstant,
    plugins:   []TomlPlugin,
    condition: string,
}
```

### WayuSettings

```odin
WayuSettings :: struct {
    auto_backup:     bool,
    fuzzy_fallback:  bool,
    dry_run_default: bool,
}
```

## Testing

Run TOML-specific tests:

```bash
odin test tests/unit/test_toml.odin -file
```

Or run all tests:

```bash
task test
```

## Known Issues

1. The repository has pre-existing issues in other files:
   - `output.odin` - Uses `typeinfo` package which doesn't exist in Odin
   - `lock.odin` - Has append syntax issues
   - `hot_reload.odin` - Had syntax errors (partially fixed)
   - `test_static_gen.odin` - Has string escaping issues

2. These issues are outside the scope of WS2 (Config System) and should be addressed by other workstreams or a general cleanup task.

## Future Enhancements

- [ ] Full migration from existing shell configs
- [ ] TOML schema validation with detailed error messages
- [ ] Support for inline tables in profiles
- [ ] Array of tables for profile-specific plugins
- [ ] TOML config editing commands
- [ ] Import/include support for modular configs

## References

- [TOML Spec](https://toml.io/en/v1.0.0)
- [wayu README](../README.md)
- [Example Config](../examples/wayu.toml)
