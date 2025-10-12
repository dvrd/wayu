package wayu

import "core:os"
import "core:strings"
import "core:fmt"

// Shell types supported by wayu
ShellType :: enum {
    BASH,
    ZSH,
    UNKNOWN,
}

// Detect the user's current shell from environment variables
detect_shell :: proc() -> ShellType {
    // Check SHELL environment variable first
    shell_env := os.get_env("SHELL")
    if len(shell_env) == 0 {
        // Fallback to checking 0 command (current shell process)
        shell_env = os.get_env("0")
        if len(shell_env) == 0 {
            return .UNKNOWN
        }
    }

    // Extract shell name from path
    shell_lower := strings.to_lower(shell_env)
    defer delete(shell_lower)

    if strings.contains(shell_lower, "zsh") {
        return .ZSH
    } else if strings.contains(shell_lower, "bash") {
        return .BASH
    }

    return .UNKNOWN
}

// Get shell-specific file extension for config files
get_shell_extension :: proc(shell: ShellType) -> string {
    switch shell {
    case .BASH:
        return "bash"
    case .ZSH:
        return "zsh"
    case .UNKNOWN:
        return "sh" // Fallback to POSIX shell
    }
    return "sh"
}

// Get shell-specific RC file path for initialization
get_rc_file_path :: proc(shell: ShellType) -> string {
    home := os.get_env("HOME")
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
    case .UNKNOWN:
        return "Unknown"
    }
    return "Unknown"
}

// Check if shell supports specific features
shell_supports_arrays :: proc(shell: ShellType) -> bool {
    return shell == .BASH || shell == .ZSH
}

shell_supports_completion :: proc(shell: ShellType) -> bool {
    return shell == .BASH || shell == .ZSH
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
    }
    return .UNKNOWN
}

// Get config file path with fallback for backward compatibility
get_config_file_with_fallback :: proc(base_name: string, shell: ShellType) -> string {
    ext := get_shell_extension(shell)

    // Try shell-specific extension first
    preferred_file := fmt.aprintf("%s/%s.%s", WAYU_CONFIG, base_name, ext)
    if os.exists(preferred_file) {
        return preferred_file
    }

    // Fall back to .zsh for backward compatibility
    zsh_file := fmt.aprintf("%s/%s.zsh", WAYU_CONFIG, base_name)
    if os.exists(zsh_file) {
        return zsh_file
    }

    // Return preferred even if it doesn't exist (for creation)
    return preferred_file
}

// Validate shell compatibility
validate_shell_compatibility :: proc(shell: ShellType) -> (valid: bool, message: string) {
    switch shell {
    case .BASH, .ZSH:
        return true, ""
    case .UNKNOWN:
        return false, "Unable to detect shell type. Please specify --shell bash or --shell zsh"
    }
    return false, "Unsupported shell type"
}