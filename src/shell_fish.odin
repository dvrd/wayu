package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// ============================================================================
// Fish Shell Support for wayu
// ============================================================================

// Detect if Fish shell is installed and available
shell_fish_detect :: proc() -> bool {
    // Check if fish is in PATH
    return command_exists("fish")
}

// Get Fish shell version
shell_fish_get_version :: proc() -> string {
    version_output := capture_command([]string{"fish", "--version"})
    if len(version_output) > 0 {
        return version_output
    }
    return "unknown"
}

// ============================================================================
// Fish Config Generation
// ============================================================================

// Generate complete Fish init script from TomlConfig
shell_fish_generate_init :: proc(config: TomlConfig) -> string {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    // Header
    fmt.println(&sb, "#!/usr/bin/env fish")
    fmt.println(&sb, "")
    fmt.println(&sb, "# Wayu Shell Initialization - Auto-generated for Fish")
    fmt.println(&sb, "# Version: %s", config.wayu_version)
    fmt.println(&sb, "")

    // Constants first
    constants_section := shell_fish_generate_constants(config.constants)
    fmt.println(&sb, constants_section)
    delete(constants_section)

    // PATH
    path_section := shell_fish_generate_path(config.path.entries)
    fmt.println(&sb, path_section)
    delete(path_section)

    // Aliases
    aliases_section := shell_fish_generate_aliases(config.aliases)
    fmt.println(&sb, aliases_section)
    delete(aliases_section)

    // Plugins placeholder
    fmt.println(&sb, "# Plugins loaded from ~/.config/wayu/plugins.fish")
    fmt.println(&sb, "if test -f \"$HOME/.config/wayu/plugins.fish\"")
    fmt.println(&sb, "    source \"$HOME/.config/wayu/plugins.fish\"")
    fmt.println(&sb, "end")

    return strings.to_string(sb)
}

// Generate Fish-compatible PATH configuration
shell_fish_generate_path :: proc(entries: []string) -> string {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    fmt.println(&sb, "# PATH Configuration")
    fmt.println(&sb, "set -gx WAYU_PATHS")
    fmt.println(&sb, "")

    // Add each entry to WAYU_PATHS array
    for entry in entries {
        escaped := escape_fish_string(entry)
        fmt.sbprintf(&sb, "set -a WAYU_PATHS %s\n", escaped)
        delete(escaped)
    }

    if len(entries) > 0 {
        fmt.println(&sb, "")
    }

    // PATH deduplication and export logic
    fmt.println(&sb, "# Build PATH from registry with deduplication")
    fmt.println(&sb, "for dir in $WAYU_PATHS")
    fmt.println(&sb, "    if not test -d \"$dir\"")
    fmt.println(&sb, "        continue")
    fmt.println(&sb, "    end")
    fmt.println(&sb, "    if contains \"$dir\" $PATH")
    fmt.println(&sb, "        continue")
    fmt.println(&sb, "    end")
    fmt.println(&sb, "    set -gx PATH \"$dir\" $PATH")
    fmt.println(&sb, "end")
    fmt.println(&sb, "")

    return strings.to_string(sb)
}

// Generate Fish-compatible aliases
shell_fish_generate_aliases :: proc(aliases: []TomlAlias) -> string {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    fmt.println(&sb, "# Aliases Configuration")

    for alias in aliases {
        escaped_command := escape_fish_string(alias.command)
        fmt.sbprintf(&sb, "alias %s '%s'\n", alias.name, escaped_command)
        delete(escaped_command)
    }

    fmt.println(&sb, "")
    return strings.to_string(sb)
}

// Generate Fish-compatible constants (environment variables)
shell_fish_generate_constants :: proc(constants: []TomlConstant) -> string {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    fmt.println(&sb, "# Environment Constants")

    for constant in constants {
        if constant.export {
            escaped_value := escape_fish_string(constant.value)
            fmt.sbprintf(&sb, "set -gx %s %s\n", constant.name, escaped_value)
            delete(escaped_value)
        } else {
            escaped_value := escape_fish_string(constant.value)
            fmt.sbprintf(&sb, "set -g %s %s\n", constant.name, escaped_value)
            delete(escaped_value)
        }
    }

    fmt.println(&sb, "")
    return strings.to_string(sb)
}

// ============================================================================
// Utility Functions
// ============================================================================

// Escape a string for safe use in Fish shell
escape_fish_string :: proc(s: string) -> string {
    // Fish uses single quotes for literal strings
    // To include a single quote, we need to escape it or use different approach

    // Check if string contains single quotes
    if !strings.contains(s, "'") {
        return fmt.aprintf("'%s'", s)
    }

    // Contains single quotes - use double quotes and escape special chars
    // In Fish, \ only escapes $, *, \, and " inside double quotes
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    strings.write_byte(&sb, '"')
    for ch in s {
        switch ch {
        case '$', '*', '\\', '"':
            strings.write_byte(&sb, '\\')
            strings.write_byte(&sb, byte(ch))
        case:
            strings.write_byte(&sb, byte(ch))
        }
    }
    strings.write_byte(&sb, '"')

    return strings.to_string(sb)
}

// Check if a command exists in PATH
command_exists :: proc(cmd: string) -> bool {
    output := capture_command([]string{"which", cmd})
    defer if len(output) > 0 do delete(output)
    return len(output) > 0 && !strings.contains(output, "not found")
}

// ============================================================================
// Fish Config File Operations
// ============================================================================

// Write Fish config to file
shell_fish_write_config :: proc(file_path: string, content: string) -> bool {
    if DRY_RUN {
        fmt.printfln("[DRY-RUN] Would write Fish config to: %s", file_path)
        return true
    }

    // Create backup before writing
    backup_path, ok := create_backup(file_path)
    defer if ok do delete(backup_path)

    err := os.write_entire_file(file_path, transmute([]byte)content)
    return err == nil
}

// Read and parse Fish config file
shell_fish_read_config :: proc(file_path: string) -> (TomlConfig, bool) {
    config := TomlConfig{}

    if !os.exists(file_path) {
        return config, false
    }

    content_bytes, err := os.read_entire_file_from_path(file_path, context.allocator)
    if err != nil {
        return config, false
    }
    defer delete(content_bytes)

    content := string(content_bytes)

    // Use temp dynamic arrays for building up the config
    constants_dyn := make([dynamic]TomlConstant)
    aliases_dyn := make([dynamic]TomlAlias)
    path_entries_dyn := make([dynamic]string)

    // Parse Fish set statements for constants
    lines := strings.split(content, "\n")
    defer delete(lines)

    for line in lines {
        line_trimmed := strings.trim_space(line)

        // Parse: set -gx NAME value
        if strings.has_prefix(line_trimmed, "set -gx ") {
            parts := strings.split(line_trimmed, " ")
            defer delete(parts)
            if len(parts) >= 4 {
                name := parts[2]
                value := strings.join(parts[3:], " ")
                defer delete(value)

                // Remove quotes if present
                if strings.has_prefix(value, "'") && strings.has_suffix(value, "'") {
                    value = value[1:len(value)-1]
                } else if strings.has_prefix(value, "\"") && strings.has_suffix(value, "\"") {
                    value = value[1:len(value)-1]
                }

                append(&constants_dyn, TomlConstant{
                    name = strings.clone(name),
                    value = strings.clone(value),
                    export = true,
                })
            }
        }

        // Parse: alias name 'command'
        if strings.has_prefix(line_trimmed, "alias ") {
            // Extract alias name and command
            // Format: alias name 'command' or alias name "command"
            alias_rest := strings.trim_prefix(line_trimmed, "alias ")

            // Find first space or quote
            space_idx := strings.index_byte(alias_rest, ' ')
            if space_idx > 0 {
                name := alias_rest[:space_idx]
                command := strings.trim_space(alias_rest[space_idx:])

                // Remove surrounding quotes
                if (strings.has_prefix(command, "'") && strings.has_suffix(command, "'")) ||
                   (strings.has_prefix(command, "\"") && strings.has_suffix(command, "\"")) {
                    command = command[1:len(command)-1]
                }

                append(&aliases_dyn, TomlAlias{
                    name = strings.clone(name),
                    command = strings.clone(command),
                })
            }
        }

        // Parse: set -a WAYU_PATHS value (or set -gx WAYU_PATHS entries)
        if strings.contains(line_trimmed, "WAYU_PATHS") {
            // Extract PATH entries
            if strings.has_prefix(line_trimmed, "set -a WAYU_PATHS ") {
                entry := strings.trim_prefix(line_trimmed, "set -a WAYU_PATHS ")
                entry = strings.trim_space(entry)
                // Remove quotes
                if (strings.has_prefix(entry, "'") && strings.has_suffix(entry, "'")) ||
                   (strings.has_prefix(entry, "\"") && strings.has_suffix(entry, "\"")) {
                    entry = entry[1:len(entry)-1]
                }
                append(&path_entries_dyn, strings.clone(entry))
            }
        }
    }

    // Convert dynamic arrays to slices for the config struct
    config.constants = constants_dyn[:]
    config.aliases = aliases_dyn[:]
    config.path.entries = path_entries_dyn[:]

    return config, true
}
