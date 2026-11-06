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
// Utility Functions
// ============================================================================

// Escape a string as a fully literal Fish word.
//
// Inside fish single quotes only `\\` and `\'` are escape sequences, so both
// backslash and single quote must be escaped; everything else (including `$`
// and `*`) is literal. Works byte-wise, so UTF-8 passes through untouched.
escape_fish_string :: proc(s: string, allocator := context.allocator) -> string {
    sb := strings.builder_make(allocator)
    strings.write_byte(&sb, '\'')
    for i in 0..<len(s) {
        c := s[i]
        if c == '\\' || c == '\'' {
            strings.write_byte(&sb, '\\')
        }
        strings.write_byte(&sb, c)
    }
    strings.write_byte(&sb, '\'')
    return strings.to_string(sb)
}

// ============================================================================
// Shell quoting helpers (shared by every generator that emits shell code)
// ============================================================================
//
// Policy for values written into generated scripts:
//
//   aliases       → single-quoted (shell_single_quote). The alias body is
//                   stored verbatim and `$VAR` expands when the alias *runs*,
//                   which is what users expect from `alias x='cd $HOME/y'`.
//   env values    → double-quoted (shell_double_quote_env). `$VAR` and
//                   `${VAR}` keep expanding at source time (GOPATH="$HOME/go"),
//                   but `"`, `\` and backtick are escaped, and command
//                   substitution `$(...)` / `$((...))` is neutralised to a
//                   literal `$(`. Rationale: values come from data files and
//                   are re-evaluated on every shell start; parameter expansion
//                   is the documented feature, executing arbitrary commands
//                   is not. Backticks and `$(` are treated the same way so the
//                   rule is simple: variables expand, commands never run.
//   literal paths → double-quoted with `$` escaped too
//                   (shell_double_quote_literal) — used for already-expanded
//                   absolute paths.
//
// All helpers operate byte-wise so non-ASCII (UTF-8) content is preserved.

// Wrap `s` in single quotes for zsh/bash, encoding embedded `'` as `'\''`.
shell_single_quote :: proc(s: string, allocator := context.allocator) -> string {
    sb := strings.builder_make(allocator)
    strings.write_byte(&sb, '\'')
    for i in 0..<len(s) {
        c := s[i]
        if c == '\'' {
            strings.write_string(&sb, `'\''`)
        } else {
            strings.write_byte(&sb, c)
        }
    }
    strings.write_byte(&sb, '\'')
    return strings.to_string(sb)
}

// Double-quote an env value for zsh/bash keeping `$VAR` / `${VAR}` expansion.
// See the policy comment above for what gets escaped and why.
shell_double_quote_env :: proc(s: string, allocator := context.allocator) -> string {
    sb := strings.builder_make(allocator)
    strings.write_byte(&sb, '"')
    for i in 0..<len(s) {
        c := s[i]
        switch c {
        case '"', '\\', '`':
            strings.write_byte(&sb, '\\')
            strings.write_byte(&sb, c)
        case '$':
            if i + 1 < len(s) && s[i+1] == '(' {
                strings.write_byte(&sb, '\\')
            }
            strings.write_byte(&sb, c)
        case:
            strings.write_byte(&sb, c)
        }
    }
    strings.write_byte(&sb, '"')
    return strings.to_string(sb)
}

// Double-quote a fully literal value for zsh/bash (no expansion of any kind).
shell_double_quote_literal :: proc(s: string, allocator := context.allocator) -> string {
    sb := strings.builder_make(allocator)
    strings.write_byte(&sb, '"')
    for i in 0..<len(s) {
        c := s[i]
        switch c {
        case '"', '\\', '`', '$':
            strings.write_byte(&sb, '\\')
        }
        strings.write_byte(&sb, c)
    }
    strings.write_byte(&sb, '"')
    return strings.to_string(sb)
}

// Double-quote an env value for fish keeping `$VAR` expansion. Inside fish
// double quotes only `\"`, `\$`, `\\` are escapes; `$(` is command
// substitution since fish 3.4, so it is neutralised like in bash/zsh.
fish_double_quote_env :: proc(s: string, allocator := context.allocator) -> string {
    sb := strings.builder_make(allocator)
    strings.write_byte(&sb, '"')
    for i in 0..<len(s) {
        c := s[i]
        switch c {
        case '"', '\\':
            strings.write_byte(&sb, '\\')
            strings.write_byte(&sb, c)
        case '$':
            if i + 1 < len(s) && s[i+1] == '(' {
                strings.write_byte(&sb, '\\')
            }
            strings.write_byte(&sb, c)
        case:
            strings.write_byte(&sb, c)
        }
    }
    strings.write_byte(&sb, '"')
    return strings.to_string(sb)
}

// Rewrite a leading `~` / `~/` into `$HOME` so env values like
// LEDGER_FILE = "~/x" expand (tilde is not expanded inside quotes).
// Returns a new string the caller owns.
expand_leading_tilde_to_home_var :: proc(s: string, allocator := context.allocator) -> string {
    if s == "~" {
        return strings.clone("$HOME", allocator)
    }
    if strings.has_prefix(s, "~/") {
        return strings.concatenate({"$HOME", s[1:]}, allocator)
    }
    return strings.clone(s, allocator)
}

// True when `s` is a portable shell variable name ([A-Za-z_][A-Za-z0-9_]*).
is_shell_identifier :: proc(s: string) -> bool {
    if len(s) == 0 { return false }
    for i in 0..<len(s) {
        c := s[i]
        alpha := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
        digit := c >= '0' && c <= '9'
        if !alpha && !(digit && i > 0) { return false }
    }
    return true
}

// True when `s` can be used verbatim as an alias name in zsh/bash/fish
// without quoting (rejects whitespace, quotes, `=`, and shell metachars).
is_safe_alias_name :: proc(s: string) -> bool {
    if len(s) == 0 { return false }
    for i in 0..<len(s) {
        c := s[i]
        switch c {
        case ' ', '\t', '\n', '\r', '\'', '"', '`', '$', '=', ';', '&', '|',
             '<', '>', '(', ')', '{', '}', '\\', '*', '?', '[', ']', '#', '~', '!':
            return false
        }
        if c < 0x20 { return false }
    }
    return true
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
