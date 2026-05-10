// test_toml.odin - Unit tests for TOML configuration module

package test_wayu

import "core:testing"
import "core:strings"
import "core:fmt"
import wayu "../../src"

// ============================================================================
// TOML PARSING TESTS
// ============================================================================

@(test)
test_toml_parse_basic :: proc(t: ^testing.T) {
    content := `
version = "1.0"
shell = "zsh"
wayu_version = "3.4.0"
`
    config, ok := wayu.toml_parse(content)
    defer wayu.cleanup_toml_config(&config)
    
    testing.expect(t, ok, "Basic TOML parsing should succeed")
    testing.expect(t, config.version == "1.0", "Version should be 1.0")
    testing.expect(t, config.shell == "zsh", "Shell should be zsh")
}

@(test)
test_toml_parse_path_config :: proc(t: ^testing.T) {
    content := `
[paths]
local_bin = "/usr/local/bin"
cargo_bin = "$HOME/.cargo/bin"
`
    config, ok := wayu.toml_parse(content)
    defer wayu.cleanup_toml_config(&config)

    testing.expect(t, ok, "Path config parsing should succeed")
    testing.expect(t, len(config.path.entries) == 2, "Should have 2 path entries")
}

@(test)
test_toml_parse_aliases :: proc(t: ^testing.T) {
    content := `
[aliases]
ll  = "ls -la"
gcm = "git commit -m"
`
    config, ok := wayu.toml_parse(content)
    defer wayu.cleanup_toml_config(&config)

    testing.expect(t, ok, "Alias parsing should succeed")
    testing.expect(t, len(config.aliases) == 2, "Should have 2 aliases")
    // Map iteration order isn't guaranteed; check by name search.
    found_ll := false
    for a in config.aliases {
        if a.name == "ll" && a.command == "ls -la" { found_ll = true; break }
    }
    testing.expect(t, found_ll, `Should contain ll = "ls -la"`)
}

@(test)
test_toml_parse_constants :: proc(t: ^testing.T) {
    content := `
[env]
EDITOR  = "nvim"
API_KEY = "secret123"
`
    config, ok := wayu.toml_parse(content)
    defer wayu.cleanup_toml_config(&config)

    testing.expect(t, ok, "Env parsing should succeed")
    testing.expect(t, len(config.constants) == 2, "Should have 2 env entries")
    found_editor := false
    for c in config.constants {
        if c.name == "EDITOR" && c.value == "nvim" && c.export {
            found_editor = true; break
        }
    }
    testing.expect(t, found_editor, `Should contain EDITOR = "nvim" (exported)`)
}

@(test)
test_toml_parse_plugins :: proc(t: ^testing.T) {
    content := `
[[plugins]]
name = "zsh-autosuggestions"
source = "github:zsh-users/zsh-autosuggestions"
version = "v0.7.0"
defer = true
priority = 50

[[plugins]]
name = "fast-syntax-highlighting"
source = "github:zdharma-continuum/fast-syntax-highlighting"
`
    config, ok := wayu.toml_parse(content)
    defer wayu.cleanup_toml_config(&config)
    
    testing.expect(t, ok, "Plugin parsing should succeed")
    testing.expect(t, len(config.plugins) == 2, "Should have 2 plugins")
    testing.expect(t, config.plugins[0].name == "zsh-autosuggestions", "First plugin name should match")
    testing.expect(t, config.plugins[0].defer_load == true, "First plugin should be deferred")
    testing.expect(t, config.plugins[0].priority == 50, "First plugin priority should be 50")
}

@(test)
test_toml_parse_profile :: proc(t: ^testing.T) {
    content := `
[profile.work]
condition = "test $WORK_ENV = production"

[profile.work.path]
entries = ["/work/tools/bin"]

[[profile.work.aliases]]
name = "work"
command = "cd /work"

[[profile.work.constants]]
name = "WORK_ENV"
value = "production"
`
    config, ok := wayu.toml_parse(content)
    defer wayu.cleanup_toml_config(&config)
    
    testing.expect(t, ok, "Profile parsing should succeed")
    testing.expect(t, len(config.profiles) == 1, "Should have 1 profile")
    
    profile, found := config.profiles["work"]
    testing.expect(t, found, "Should find 'work' profile")
    testing.expect(t, profile.condition == "test $WORK_ENV = production", "Profile condition should match")
}

@(test)
test_toml_parse_settings :: proc(t: ^testing.T) {
    content := `
[settings]
auto_backup = true
fuzzy_fallback = true
dry_run_default = false
`
    config, ok := wayu.toml_parse(content)
    defer wayu.cleanup_toml_config(&config)
    
    testing.expect(t, ok, "Settings parsing should succeed")
    testing.expect(t, config.settings.auto_backup == true, "auto_backup should be true")
    testing.expect(t, config.settings.fuzzy_fallback == true, "fuzzy_fallback should be true")
    testing.expect(t, config.settings.dry_run_default == false, "dry_run_default should be false")
}

// ============================================================================
// TOML VALIDATION TESTS
// ============================================================================

@(test)
test_toml_validate_valid_config :: proc(t: ^testing.T) {
    content := `
version = "1.0"
shell = "zsh"

[aliases]
ll = "ls -la"
`
    config, ok := wayu.toml_parse(content)
    defer wayu.cleanup_toml_config(&config)
    
    testing.expect(t, ok, "Parsing should succeed")
    
    result := wayu.toml_validate(config)
    defer if result.error_message != "" do delete(result.error_message)
    
    testing.expect(t, result.valid, "Valid config should pass validation")
}

@(test)
test_toml_validate_invalid_shell :: proc(t: ^testing.T) {
    content := `
version = "1.0"
shell = "invalid_shell"
`
    config, ok := wayu.toml_parse(content)
    defer wayu.cleanup_toml_config(&config)
    
    testing.expect(t, ok, "Parsing should succeed even with invalid shell")
    
    result := wayu.toml_validate(config)
    defer if result.error_message != "" do delete(result.error_message)
    
    testing.expect(t, !result.valid, "Invalid shell should fail validation")
}

@(test)
test_toml_validate_invalid_alias :: proc(t: ^testing.T) {
    content := `
version = "1.0"

[aliases]
if = "echo test"
`
    config, ok := wayu.toml_parse(content)
    defer wayu.cleanup_toml_config(&config)
    
    testing.expect(t, ok, "Parsing should succeed")
    
    result := wayu.toml_validate(config)
    defer if result.error_message != "" do delete(result.error_message)
    
    testing.expect(t, !result.valid, "Reserved word alias should fail validation")
}

@(test)
test_toml_parse_empty :: proc(t: ^testing.T) {
    config, ok := wayu.toml_parse("")
    defer wayu.cleanup_toml_config(&config)
    
    testing.expect(t, ok, "Empty TOML parsing should succeed")
}

@(test)
test_toml_parse_comments :: proc(t: ^testing.T) {
    content := `
# This is a comment
version = "1.0"  # inline comment

# Another comment
shell = "bash"
`
    config, ok := wayu.toml_parse(content)
    defer wayu.cleanup_toml_config(&config)
    
    testing.expect(t, ok, "TOML with comments should parse")
    testing.expect(t, config.version == "1.0", "Version should be 1.0")
    testing.expect(t, config.shell == "bash", "Shell should be bash")
}
