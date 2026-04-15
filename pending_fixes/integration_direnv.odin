package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// ============================================================================
// Direnv Integration for wayu
// ============================================================================

// Direnv configuration structure
DirenvConfig :: struct {
    enabled:     bool,
    auto_allow:  bool,
    aliases:     []string,
}

// ============================================================================
// Detection
// ============================================================================

// Detect if direnv is installed and available
integration_direnv_detect :: proc() -> bool {
    return command_exists("direnv")
}

// Get direnv version
integration_direnv_get_version :: proc() -> string {
    version_output := capture_command([]string{"direnv", "version"})
    if len(version_output) > 0 {
        return version_output
    }
    return "unknown"
}

// Check if current directory has a .envrc file
integration_direnv_has_envrc :: proc() -> bool {
    cwd := os.get_current_directory(context.temp_allocator)
    envrc_path := fmt.aprintf("%s/.envrc", cwd)
    defer delete(envrc_path)
    return os.exists(envrc_path)
}

// Check if .envrc is allowed
integration_direnv_is_allowed :: proc() -> bool {
    cwd := os.get_current_directory(context.temp_allocator)
    return run_command([]string{"direnv", "status"})
}

// ============================================================================
// Initialization
// ============================================================================

// Initialize direnv in current directory (creates .envrc)
integration_direnv_init :: proc() -> bool {
    cwd := os.get_current_directory(context.temp_allocator)
    envrc_path := fmt.aprintf("%s/.envrc", cwd)
    defer delete(envrc_path)

    // Check if direnv is installed
    if !integration_direnv_detect() {
        print_error_simple("direnv is not installed. Please install it first.")
        return false
    }

    // Check if .envrc already exists
    if os.exists(envrc_path) {
        print_info(".envrc already exists at %s", envrc_path)
        if !YES_FLAG {
            confirm := prompt_confirmation("Do you want to modify it?")
            if !confirm {
                print_info("Aborted.")
                return false
            }
        }
    }

    if DRY_RUN {
        fmt.printfln("[DRY-RUN] Would create/modify .envrc at: %s", envrc_path)
        return true
    }

    // Load current config
    config := load_config_or_default()
    defer destroy_toml_config(&config)

    // Generate .envrc content
    envrc_content := integration_direnv_generate_envrc(config)
    defer delete(envrc_content)

    // Backup existing .envrc if present
    if os.exists(envrc_path) {
        backup_path, ok := create_backup(envrc_path)
        defer if ok do delete(backup_path)
        if ok {
            print_success("Created backup: %s", backup_path)
        }
    }

    // Write .envrc
    err := os.write_entire_file(envrc_path, transmute([]byte)envrc_content)
    if err != nil {
        print_error_simple("Failed to write .envrc: %v", err)
        return false
    }

    print_success("Created .envrc at: %s", envrc_path)
    print_info("Run 'wayu direnv allow' to activate it")

    return true
}

// Allow the .envrc in current directory
integration_direnv_allow :: proc() -> bool {
    cwd := os.get_current_directory(context.temp_allocator)
    envrc_path := fmt.aprintf("%s/.envrc", cwd)
    defer delete(envrc_path)

    // Check if .envrc exists
    if !os.exists(envrc_path) {
        print_error_simple("No .envrc found at %s", cwd)
        print_info("Run 'wayu direnv init' to create one")
        return false
    }

    // Check if direnv is installed
    if !integration_direnv_detect() {
        print_error_simple("direnv is not installed. Please install it first.")
        return false
    }

    if DRY_RUN {
        fmt.printfln("[DRY-RUN] Would run: direnv allow %s", cwd)
        return true
    }

    // Run direnv allow
    success := run_command([]string{"direnv", "allow", cwd})
    if success {
        print_success("Allowed .envrc in %s", cwd)
        // Show direnv status
        status := capture_command([]string{"direnv", "status"})
        defer if len(status) > 0 do delete(status)
        if len(status) > 0 {
            fmt.println("")
            fmt.println("Direnv status:")
            fmt.println(status)
        }
    } else {
        print_error_simple("Failed to allow .envrc")
    }

    return success
}

// Revoke (deny) the .envrc in current directory
integration_direnv_deny :: proc() -> bool {
    cwd := os.get_current_directory(context.temp_allocator)

    if !integration_direnv_detect() {
        print_error_simple("direnv is not installed")
        return false
    }

    if DRY_RUN {
        fmt.printfln("[DRY-RUN] Would run: direnv deny %s", cwd)
        return true
    }

    success := run_command([]string{"direnv", "deny", cwd})
    if success {
        print_success("Revoked .envrc in %s", cwd)
    } else {
        print_error_simple("Failed to revoke .envrc")
    }

    return success
}

// ============================================================================
// .envrc Generation
// ============================================================================

// Generate .envrc content from TomlConfig
integration_direnv_generate_envrc :: proc(config: TomlConfig) -> string {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    // Header
    fmt.println(&sb, "# .envrc - Generated by wayu")
    fmt.println(&sb, "# This file exports wayu constants to direnv")
    fmt.println(&sb, "")

    // Add wayu integration marker
    fmt.println(&sb, "# wayu:direnv:v1")
    fmt.println(&sb, "")

    // Export constants
    if len(config.constants) > 0 {
        fmt.println(&sb, "# Exported constants from wayu")
        for constant in config.constants {
            if constant.export {
                // Handle secret values
                if constant.secret {
                    fmt.printf(&sb, "# export %s=*** (secret value hidden)\n", constant.name)
                } else {
                    // Escape value for shell
                    escaped := escape_shell_value(constant.value)
                    fmt.printf(&sb, "export %s=%s\n", constant.name, escaped)
                    delete(escaped)
                }
            }
        }
        fmt.println(&sb, "")
    }

    // PATH modifications
    if len(config.path.entries) > 0 {
        fmt.println(&sb, "# PATH entries from wayu")
        for entry in config.path.entries {
            // Use PATH_add if available (direnv helper), otherwise manual
            escaped := escape_shell_value(entry)
            fmt.printf(&sb, "PATH_add %s\n", escaped)
            delete(escaped)
        }
        fmt.println(&sb, "")
    }

    // Aliases (as functions for direnv)
    if len(config.aliases) > 0 {
        fmt.println(&sb, "# Aliases from wayu (as shell functions)")
        for alias in config.aliases {
            escaped_command := escape_shell_value(alias.command)
            fmt.printf(&sb, "%s() { %s \"$@\"; }\n", alias.name, escaped_command)
            delete(escaped_command)
        }
        fmt.println(&sb, "")
    }

    // Add watch for wayu config changes
    fmt.println(&sb, "# Watch wayu config for changes")
    fmt.println(&sb, "watch_file ~/.config/wayu/constants.*")
    fmt.println(&sb, "watch_file ~/.config/wayu/path.*")
    fmt.println(&sb, "watch_file ~/.config/wayu/aliases.*")

    return strings.to_string(sb)
}

// ============================================================================
// Helper Functions
// ============================================================================

// Escape a value for shell export in .envrc
escape_shell_value :: proc(value: string) -> string {
    // Simple escaping - wrap in quotes if contains special chars
    if strings.contains_any(value, " \\t\n\"'$&;|<>()[]{}") {
        // Use single quotes, escaping any single quotes
        sb := strings.builder_make()
        defer strings.builder_destroy(&sb)

        strings.write_byte(&sb, "'")
        for ch in value {
            if ch == "'" {
                // Close quote, add escaped quote, reopen
                strings.write_string(&sb, "'\"'\"'")
            } else {
                strings.write_byte(&sb, byte(ch))
            }
        }
        strings.write_byte(&sb, "'")

        return strings.to_string(sb)
    }

    // No special chars, return as-is
    return strings.clone(value)
}

// Load TOML config or return default
load_config_or_default :: proc() -> TomlConfig {
    // Try to load from wayu config directory
    config_path := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG)
    defer delete(config_path)

    if os.exists(config_path) {
        content_bytes, err := os.read_entire_file_from_filename(config_path)
        if err == nil {
            defer delete(content_bytes)
            content := string(content_bytes)
            config, ok := parse_toml(content)
            if ok {
                return config
            }
        }
    }

    // Return default empty config
    return TomlConfig{
        version = "1.0",
        shell = "zsh",
        wayu_version = VERSION,
    }
}

// Clean up TOML config resources
destroy_toml_config :: proc(config: ^TomlConfig) {
    delete(config.path.entries)

    for alias in config.aliases {
        delete(alias.name)
        delete(alias.command)
        delete(alias.description)
    }
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
        delete(profile.condition)
    }
    delete(config.profiles)
}

// Helper to prompt for confirmation
prompt_confirmation :: proc(message: string) -> bool {
    fmt.printf("%s [y/N] ", message)

    // Read input
    buf: [256]byte
    n, _ := os.read(os.stdin, buf[:])
    if n <= 0 {
        return false
    }

    response := strings.trim_space(string(buf[:n]))
    return response == "y" || response == "Y" || response == "yes"
}
