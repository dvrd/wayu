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
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        delete(config.aliases)
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
    testing.expect(t, ok, "Basic TOML parsing should succeed")
    testing.expect(t, config.version == "1.0", "Version should be 1.0")
    testing.expect(t, config.shell == "zsh", "Shell should be zsh")
}

@(test)
test_toml_parse_path_config :: proc(t: ^testing.T) {
    content := `
[path]
entries = ["/usr/local/bin", "$HOME/.cargo/bin"]
dedup = true
clean = false
`
    config, ok := wayu.toml_parse(content)
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        delete(config.aliases)
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
    testing.expect(t, ok, "Path config parsing should succeed")
    testing.expect(t, len(config.path.entries) == 2, "Should have 2 path entries")
    testing.expect(t, config.path.dedup == true, "Dedup should be true")
    testing.expect(t, config.path.clean == false, "Clean should be false")
}

@(test)
test_toml_parse_aliases :: proc(t: ^testing.T) {
    content := `
[[aliases]]
name = "ll"
command = "ls -la"
description = "List all files"

[[aliases]]
name = "gcm"
command = "git commit -m"
`
    config, ok := wayu.toml_parse(content)
    fmt.printfln("[DEBUG] Parsed %d aliases", len(config.aliases))
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        for alias in config.aliases {
            delete(alias.name)
            delete(alias.command)
            delete(alias.description)
        }
        delete(config.aliases)
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
    testing.expect(t, ok, "Alias parsing should succeed")
    testing.expect(t, len(config.aliases) == 2, "Should have 2 aliases")
    testing.expect(t, config.aliases[0].name == "ll", "First alias name should be 'll'")
    testing.expect(t, config.aliases[0].command == "ls -la", "First alias command should be 'ls -la'")
}

@(test)
test_toml_parse_constants :: proc(t: ^testing.T) {
    content := `
[[constants]]
name = "EDITOR"
value = "nvim"
export = true
secret = false

[[constants]]
name = "API_KEY"
value = "secret123"
secret = true
`
    config, ok := wayu.toml_parse(content)
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        delete(config.aliases)
        for constant in config.constants {
            delete(constant.name)
            delete(constant.value)
            delete(constant.description)
        }
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
    testing.expect(t, ok, "Constant parsing should succeed")
    testing.expect(t, len(config.constants) == 2, "Should have 2 constants")
    testing.expect(t, config.constants[0].name == "EDITOR", "First constant should be EDITOR")
    testing.expect(t, config.constants[0].export == true, "First constant should be exported")
    testing.expect(t, config.constants[1].secret == true, "Second constant should be secret")
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
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        delete(config.aliases)
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
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
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        delete(config.aliases)
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
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
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        delete(config.aliases)
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
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

[[aliases]]
name = "ll"
command = "ls -la"
`
    config, ok := wayu.toml_parse(content)
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        for alias in config.aliases {
            delete(alias.name)
            delete(alias.command)
            delete(alias.description)
        }
        delete(config.aliases)
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
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
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        delete(config.aliases)
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
    testing.expect(t, ok, "Parsing should succeed even with invalid shell")
    
    result := wayu.toml_validate(config)
    defer if result.error_message != "" do delete(result.error_message)
    
    testing.expect(t, !result.valid, "Invalid shell should fail validation")
}

@(test)
test_toml_validate_invalid_alias :: proc(t: ^testing.T) {
    content := `
version = "1.0"

[[aliases]]
name = "if"
command = "echo test"
`
    config, ok := wayu.toml_parse(content)
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        for alias in config.aliases {
            delete(alias.name)
            delete(alias.command)
            delete(alias.description)
        }
        delete(config.aliases)
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
    testing.expect(t, ok, "Parsing should succeed")
    
    result := wayu.toml_validate(config)
    defer if result.error_message != "" do delete(result.error_message)
    
    testing.expect(t, !result.valid, "Reserved word alias should fail validation")
}

// ============================================================================
// TOML SERIALIZATION TESTS
// ============================================================================

@(test)
test_toml_to_string_basic :: proc(t: ^testing.T) {
    content := `
version = "1.0"
shell = "zsh"

[path]
entries = ["/usr/local/bin"]
dedup = true
`
    config, ok := wayu.toml_parse(content)
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        delete(config.aliases)
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
    testing.expect(t, ok, "Parsing should succeed")
    
    output := wayu.toml_to_string(config)
    defer delete(output)
    
    testing.expect(t, len(output) > 0, "Output should not be empty")
    testing.expect(t, strings.contains(output, "version = \"1.0\""), "Output should contain version")
    testing.expect(t, strings.contains(output, "shell = \"zsh\""), "Output should contain shell")
    testing.expect(t, strings.contains(output, "[path]"), "Output should contain path section")
}

// ============================================================================
// PROFILE MERGING TESTS
// ============================================================================

@(test)
test_toml_merge_profiles :: proc(t: ^testing.T) {
    content := `
version = "1.0"

[path]
entries = ["/usr/local/bin"]

[[aliases]]
name = "ll"
command = "ls -la"

[profile.work]

[profile.work.path]
entries = ["/work/bin"]

[[profile.work.aliases]]
name = "deploy"
command = "make deploy"
`
    config, ok := wayu.toml_parse(content)
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        for alias in config.aliases {
            delete(alias.name)
            delete(alias.command)
            delete(alias.description)
        }
        delete(config.aliases)
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
    testing.expect(t, ok, "Parsing should succeed")
    testing.expect(t, len(config.profiles) == 1, "Should have work profile")
    
    merged := wayu.toml_merge_profiles(config, "work")
    defer {
        delete(merged.version)
        delete(merged.shell)
        delete(merged.wayu_version)
        delete(merged.path.entries)
        for alias in merged.aliases {
            delete(alias.name)
            delete(alias.command)
            delete(alias.description)
        }
        delete(merged.aliases)
        delete(merged.constants)
        for plugin in merged.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(merged.plugins)
        for _, profile in merged.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(merged.profiles)
    }
    
    // Should have base + profile aliases
    testing.expect(t, len(merged.aliases) == 2, "Merged should have 2 aliases (1 base + 1 profile)")
}

@(test)
test_toml_merge_nonexistent_profile :: proc(t: ^testing.T) {
    content := `
version = "1.0"

[path]
entries = ["/usr/local/bin"]
`
    config, ok := wayu.toml_parse(content)
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        delete(config.aliases)
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
    testing.expect(t, ok, "Parsing should succeed")
    
    merged := wayu.toml_merge_profiles(config, "nonexistent")
    defer {
        delete(merged.version)
        delete(merged.shell)
        delete(merged.wayu_version)
        delete(merged.path.entries)
        delete(merged.aliases)
        delete(merged.constants)
        for plugin in merged.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(merged.plugins)
        for _, profile in merged.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(merged.profiles)
    }
    
    // Should return original config unchanged
    testing.expect(t, len(merged.path.entries) == 1, "Should still have 1 path entry")
}

// ============================================================================
// EDGE CASE TESTS
// ============================================================================

@(test)
test_toml_parse_empty :: proc(t: ^testing.T) {
    config, ok := wayu.toml_parse("")
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        delete(config.aliases)
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
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
    defer {
        delete(config.version)
        delete(config.shell)
        delete(config.wayu_version)
        delete(config.path.entries)
        delete(config.aliases)
        delete(config.constants)
        for plugin in config.plugins {
            delete(plugin.name)
            delete(plugin.source)
            delete(plugin.version)
            delete(plugin.condition)
            delete(plugin.description)
            delete(plugin.use)
        }
        delete(config.plugins)
        for _, profile in config.profiles {
            delete(profile.aliases)
            delete(profile.constants)
            delete(profile.plugins)
            if profile.path != nil {
                delete(profile.path.entries)
                free(profile.path)
            }
            delete(profile.condition)
        }
        delete(config.profiles)
    }
    
    testing.expect(t, ok, "TOML with comments should parse")
    testing.expect(t, config.version == "1.0", "Version should be 1.0")
    testing.expect(t, config.shell == "bash", "Shell should be bash")
}
