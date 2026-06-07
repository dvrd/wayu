package wayu
import "core:os"
import "core:strings"
import "core:fmt"
import "core:strconv"
import "core:c"
// Shell types supported by wayu
ShellType :: enum {
    BASH,
    ZSH,
    FISH,
    UNKNOWN,
}

// Detect the user's current shell from environment variables.
// Zero-allocation: uses case-insensitive contains instead of to_lower.
detect_shell :: proc() -> ShellType {
    shell_env := os.get_env("SHELL", context.temp_allocator)
    if len(shell_env) == 0 {
        shell_env = os.get_env("0", context.temp_allocator)
        if len(shell_env) == 0 {
            return .UNKNOWN
        }
    }

    // Check suffix after last '/' for common paths like /bin/zsh, /usr/bin/bash
    name := shell_env
    if last_slash := strings.last_index_byte(shell_env, '/'); last_slash >= 0 {
        name = shell_env[last_slash + 1:]
    }
    if strings.equal_fold(name, "zsh")  { return .ZSH  }
    if strings.equal_fold(name, "bash") { return .BASH }
    if strings.equal_fold(name, "fish") { return .FISH }

    // Fallback: scan full path for substring
    if strings.contains(shell_env, "zsh")  { return .ZSH  }
    if strings.contains(shell_env, "bash") { return .BASH }
    if strings.contains(shell_env, "fish") { return .FISH }

    return .UNKNOWN
}

// Get shell-specific file extension for config files
get_shell_extension :: proc(shell: ShellType) -> string {
    switch shell {
    case .BASH:
        return "bash"
    case .ZSH:
        return "zsh"
    case .FISH:
        return "fish"
    case .UNKNOWN:
        return "sh" // Fallback to POSIX shell
    }
    return "sh"
}

// Get shell-specific RC file path for initialization
get_rc_file_path :: proc(shell: ShellType) -> string {
    home := os.get_env("HOME", context.temp_allocator)

    switch shell {
    case .BASH:
        // Check for .bash_profile first (macOS), then .bashrc (Linux)
        bash_profile := fmt.aprintf("%s/.bash_profile", home)
        if os.exists(bash_profile) {
            return bash_profile
        }
        return fmt.aprintf("%s/.bashrc", home)
    case .ZSH:
        return fmt.aprintf("%s/.zshrc", home)
    case .FISH:
        return fmt.aprintf("%s/.config/fish/config.fish", home)
    case .UNKNOWN:
        return fmt.aprintf("%s/.profile", home)
    }
    return ""
}

// Get shell-specific shebang for config files
get_shebang :: proc(shell: ShellType) -> string {
    switch shell {
    case .BASH:
        return "#!/usr/bin/env bash"
    case .ZSH:
        return "#!/usr/bin/env zsh"
    case .FISH:
        return "#!/usr/bin/env fish"
    case .UNKNOWN:
        return "#!/bin/sh"
    }
    return "#!/bin/sh"
}

// Get shell name as string for display purposes
get_shell_name :: proc(shell: ShellType) -> string {
    switch shell {
    case .BASH:
        return "Bash"
    case .ZSH:
        return "ZSH"
    case .FISH:
        return "Fish"
    case .UNKNOWN:
        return "Unknown"
    }
    return "Unknown"
}

// Check if shell supports specific features
shell_supports_arrays :: proc(shell: ShellType) -> bool {
    return shell == .BASH || shell == .ZSH || shell == .FISH
}

shell_supports_completion :: proc(shell: ShellType) -> bool {
    return shell == .BASH || shell == .ZSH || shell == .FISH
}

shell_supports_functions :: proc(shell: ShellType) -> bool {
    // All shells support functions, but with different syntax
    return true
}

// Parse shell type from string (for CLI flags)
parse_shell_type :: proc(shell_str: string) -> ShellType {
    shell_lower := strings.to_lower(shell_str)
    defer delete(shell_lower)

    if shell_lower == "bash" {
        return .BASH
    } else if shell_lower == "zsh" {
        return .ZSH
    } else if shell_lower == "fish" {
        return .FISH
    }
    return .UNKNOWN
}

// Get config file path with fallback for backward compatibility
get_config_file_with_fallback :: proc(base_name: string, shell: ShellType) -> string {
	ext := get_shell_extension(shell)

	// Try shell-specific extension first
	preferred_file := fmt.aprintf("%s/%s.%s", wayu.data, base_name, ext)
	if os.exists(preferred_file) {
		return preferred_file
	}

	// Fall back to .zsh for backward compatibility
	zsh_file := fmt.aprintf("%s/%s.zsh", wayu.data, base_name)
	if os.exists(zsh_file) {
		delete(preferred_file)
		return zsh_file
	}

	// Return preferred even if it doesn't exist (for creation)
	delete(zsh_file)
	return preferred_file
}

// Validate shell compatibility
validate_shell_compatibility :: proc(shell: ShellType) -> (valid: bool, message: string) {
    switch shell {
    case .BASH, .ZSH, .FISH:
        return true, ""
    case .UNKNOWN:
        return false, "Unable to detect shell type. Please specify --shell bash, --shell zsh, or --shell fish"
    }
    return false, "Unsupported shell type"
}

// Get the terminal width for CLI output.
// Tries: COLUMNS env var → stty size → fallback of 80.
get_cli_terminal_width :: proc() -> int {
    // Method 1: COLUMNS env var (set by most shells)
    cols_env := os.get_env("COLUMNS", context.temp_allocator)
    if len(cols_env) > 0 {
        cols, ok := strconv.parse_int(cols_env)
        if ok && cols > 0 {
            return cols
        }
    }

    // Method 2: ioctl TIOCGWINSZ (direct syscall, no subprocess)
    ws: winsize
    // Try stdout (fd 1), then stderr (fd 2), then stdin (fd 0)
    for fd in ([3]c.int{1, 2, 0}) {
        if ioctl(fd, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 {
            return int(ws.ws_col)
        }
    }

    return 80
}
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
    fmt.sbprintln(&sb, "#!/usr/bin/env fish")
    fmt.sbprintln(&sb, "")
    fmt.sbprintln(&sb, "# Wayu Shell Initialization - Auto-generated for Fish")
    fmt.sbprintfln(&sb, "# Version: %s", config.wayu_version)
    fmt.sbprintln(&sb, "")

    // Constants first
    constants_section := shell_fish_generate_constants(config.constants)
    fmt.sbprintln(&sb, constants_section)
    delete(constants_section)

    // PATH
    path_section := shell_fish_generate_path(config.path.entries)
    fmt.sbprintln(&sb, path_section)
    delete(path_section)

    // Aliases
    aliases_section := shell_fish_generate_aliases(config.aliases)
    fmt.sbprintln(&sb, aliases_section)
    delete(aliases_section)

    // Plugins (sources the generated fish plugin loader if present)
    fmt.sbprintln(&sb, "# Plugins loaded from ~/.local/share/wayu/plugins.fish")
    fmt.sbprintln(&sb, "if test -f \"$HOME/.local/share/wayu/plugins.fish\"")
    fmt.sbprintln(&sb, "    source \"$HOME/.local/share/wayu/plugins.fish\"")
    fmt.sbprintln(&sb, "end")

    return strings.clone(strings.to_string(sb))
}

// Generate Fish-compatible PATH configuration
shell_fish_generate_path :: proc(entries: []string) -> string {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    fmt.sbprintln(&sb, "# PATH Configuration")
    fmt.sbprintln(&sb, "set -gx WAYU_PATHS")
    fmt.sbprintln(&sb, "")

    // Add each entry to WAYU_PATHS array
    for entry in entries {
        escaped := escape_fish_string(entry)
        fmt.sbprintf(&sb, "set -a WAYU_PATHS %s\n", escaped)
        delete(escaped)
    }

    if len(entries) > 0 {
        fmt.sbprintln(&sb, "")
    }

    // PATH deduplication and export logic
    fmt.sbprintln(&sb, "# Build PATH from registry with deduplication")
    fmt.sbprintln(&sb, "for dir in $WAYU_PATHS")
    fmt.sbprintln(&sb, "    if not test -d \"$dir\"")
    fmt.sbprintln(&sb, "        continue")
    fmt.sbprintln(&sb, "    end")
    fmt.sbprintln(&sb, "    if contains \"$dir\" $PATH")
    fmt.sbprintln(&sb, "        continue")
    fmt.sbprintln(&sb, "    end")
    fmt.sbprintln(&sb, "    set -gx PATH \"$dir\" $PATH")
    fmt.sbprintln(&sb, "end")
    fmt.sbprintln(&sb, "")

    return strings.clone(strings.to_string(sb))
}

// Generate Fish-compatible aliases
shell_fish_generate_aliases :: proc(aliases: []TomlAlias) -> string {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    fmt.sbprintln(&sb, "# Aliases Configuration")

    for alias in aliases {
        escaped_command := escape_fish_string(alias.command)
        fmt.sbprintf(&sb, "alias %s %s\n", alias.name, escaped_command)
        delete(escaped_command)
    }

    fmt.sbprintln(&sb, "")
    return strings.clone(strings.to_string(sb))
}

// Generate Fish-compatible constants (environment variables)
shell_fish_generate_constants :: proc(constants: []TomlConstant) -> string {
    sb := strings.builder_make()
    defer strings.builder_destroy(&sb)

    fmt.sbprintln(&sb, "# Environment Constants")

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

    fmt.sbprintln(&sb, "")
    return strings.clone(strings.to_string(sb))
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

    return strings.clone(strings.to_string(sb))
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
    if wayu.dry_run {
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
