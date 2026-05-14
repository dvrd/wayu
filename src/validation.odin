// validation.odin - Input validation and sanitization for shell configurations

package wayu
import "core:strings"
import "core:unicode"
import "core:fmt"
import "core:os"
// Validation result with detailed error message and optional warning
ValidationResult :: struct {
	valid:         bool,
	error_message: string,
	warning:       string, // Non-empty when valid but a convention is violated; caller is responsible for printing and freeing
}

// Shell reserved words that cannot be used as identifiers
SHELL_RESERVED_WORDS :: []string {
	// POSIX reserved words
	"if",
	"then",
	"else",
	"elif",
	"fi",
	"case",
	"esac",
	"for",
	"while",
	"until",
	"do",
	"done",
	"in",
	"function",
	"time",
	"select",
	// Bash/ZSH specific
	"coproc",
	"declare",
	"typeset",
	"local",
	"export",
	"readonly",
	"unset",
	"return",
	"exit",
	// Common commands that shouldn't be aliased
	"cd",
	"pwd",
	"echo",
	"test",
	"true",
	"false",
}

// Validate shell identifier (alias/constant name)
validate_identifier :: proc(name: string, identifier_type: string) -> ValidationResult {
	// Check for empty
	if len(name) == 0 {
		return ValidationResult {
			valid = false,
			error_message = fmt.aprintf("%s name cannot be empty", identifier_type),
		}
	}

	// Check first character (must be letter or underscore)
	first_rune := rune(name[0])
	if !unicode.is_alpha(first_rune) && first_rune != '_' {
		return ValidationResult {
			valid = false,
			error_message = fmt.aprintf(
				"%s name must start with a letter or underscore, got '%c'",
				identifier_type,
				first_rune,
			),
		}
	}

	// Check remaining characters (alphanumeric or underscore — matches
	// POSIX identifier rules; hyphens are invalid in env var names and
	// problematic for shell parsing).
	for r, i in name {
		if !unicode.is_alpha(r) && !unicode.is_digit(r) && r != '_' {
			return ValidationResult {
				valid = false,
				error_message = fmt.aprintf(
					"%s name contains invalid character '%c' at position %d. Only letters, digits, and underscores allowed.",
					identifier_type,
					r,
					i,
				),
			}
		}
	}

	// Check for shell reserved words
	for reserved_word in SHELL_RESERVED_WORDS {
		if name == reserved_word {
			return ValidationResult {
				valid = false,
				error_message = fmt.aprintf(
					"Cannot use shell reserved word '%s' as %s name",
					name,
					identifier_type,
				),
			}
		}
	}

	// Check length (reasonable limit)
	if len(name) > 255 {
		return ValidationResult {
			valid = false,
			error_message = fmt.aprintf(
				"%s name too long (%d characters). Maximum 255 characters allowed.",
				identifier_type,
				len(name),
			),
		}
	}

	return ValidationResult{valid = true, error_message = ""}
}

// Sanitize shell command value for double-quoted emission (e.g., alias x="VALUE")
// CRITICAL: This function MUST be idempotent and called exactly once per emission.
// The input is the raw TOML-parsed value (already unescaped by TOML parser).
// Emitted format: alias x="VALUE" where VALUE escapes only the minimal set needed to
// prevent breakout and code injection inside the double-quoted string.
//
// Escape rules for double-quoted strings ("..."):
// - " → \" (prevents breaking out of the double-quoted string)
// - ` → \` (prevents command substitution)
// - $(...) → \$(...) (prevents command substitution via $(...))
// - \ → leave alone (shell treats \\ inside "..." as literal \, and \$ suppresses expansion)
// - $VAR → leave alone (allows variable expansion, e.g., $HOME, $HERMOD_TOKEN)
// - ; & | < > ( ) { } newline → leave alone (literal inside "...", execute when alias is invoked)
//
// This preserves user intent: $HOME expands, but "foo"; evil_command; :" does NOT inject
// because the inner " is escaped (it was the attacker's only lever).
sanitize_shell_value :: proc(value: string) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	i := 0
	for i < len(value) {
		ch := value[i]
		switch ch {
		case '"':
			// Escape double quotes to prevent breakout
			strings.write_string(&builder, "\\\"")
			i += 1
		case '`':
			// Escape backticks (command substitution inside double quotes)
			strings.write_string(&builder, "\\`")
			i += 1
		case '$':
			// Check for $(...) pattern and escape it
			if i + 1 < len(value) && value[i + 1] == '(' {
				strings.write_string(&builder, "\\$(")
				i += 2
			} else {
				// Plain $ or $VAR: allow expansion
				strings.write_rune(&builder, rune(ch))
				i += 1
			}
		case:
			// All other characters (including \, ;, &, |, etc.) are literal in double quotes
			strings.write_rune(&builder, rune(ch))
			i += 1
		}
	}

	return strings.clone(strings.to_string(builder))
}

// Reverse of sanitize_shell_value — used by `get` to return the original user value
unescape_shell_value :: proc(value: string) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	i := 0
	for i < len(value) {
		if value[i] == '\\' && i + 1 < len(value) {
			switch value[i + 1] {
			case '"':  strings.write_rune(&builder, '"');  i += 2
			case '`':  strings.write_rune(&builder, '`');  i += 2
			case '$':  strings.write_rune(&builder, '$');  i += 2
			case '\\': strings.write_rune(&builder, '\\'); i += 2
			case 'n':  strings.write_rune(&builder, '\n'); i += 2
			case:      strings.write_byte(&builder, value[i]); i += 1
			}
		} else {
			strings.write_byte(&builder, value[i])
			i += 1
		}
	}

	return strings.clone(strings.to_string(builder))
}

// Validate alias-specific rules
validate_alias :: proc(name: string, command: string) -> ValidationResult {
	// First validate the identifier
	result := validate_identifier(name, "Alias")
	if !result.valid {
		return result
	}

	// Check command is not empty
	if len(strings.trim_space(command)) == 0 {
		return ValidationResult{valid = false, error_message = fmt.aprintf("Alias command cannot be empty")}
	}

	return ValidationResult{valid = true, error_message = ""}
}

// Validate constant-specific rules
validate_constant :: proc(name: string, value: string) -> ValidationResult {
	// First validate the identifier
	result := validate_identifier(name, "Constant")
	if !result.valid {
		return result
	}

	// Convention: constants should be uppercase (warning, not error).
	// The caller is responsible for printing result.warning and freeing it.
	has_lowercase := false
	for r in name {
		if unicode.is_lower(r) {
			has_lowercase = true
			break
		}
	}

	if has_lowercase {
		return ValidationResult{
			valid         = true,
			error_message = "",
			warning       = fmt.aprintf(
				"Constant name '%s' contains lowercase letters. Convention is UPPER_CASE.",
				name,
			),
		}
	}

	return ValidationResult{valid = true, error_message = "", warning = ""}
}

// Validate that a string is safe to use as a shell command argument
// Rejects strings containing shell metacharacters that could enable injection
is_safe_shell_arg :: proc(arg: string) -> bool {
	for r in arg {
		switch r {
		case '"', '`', '$', ';', '|', '&', '(', ')', '>', '<', '\'', '\n', '\r':
			return false
		}
	}
	return true
}

// Validate path
validate_path :: proc(path: string) -> ValidationResult {
	if len(strings.trim_space(path)) == 0 {
		return ValidationResult{valid = false, error_message = fmt.aprintf("Path cannot be empty")}
	}

	// Check for null bytes (security)
	if strings.contains(path, "\x00") {
		return ValidationResult{valid = false, error_message = fmt.aprintf("Path contains null bytes")}
	}

	return ValidationResult{valid = true, error_message = ""}
}
// Error types for better categorization
ErrorType :: enum {
	FILE_NOT_FOUND,
	PERMISSION_DENIED,
	FILE_READ_ERROR,
	FILE_WRITE_ERROR,
	INVALID_INPUT,
	CONFIG_NOT_INITIALIZED,
	DIRECTORY_NOT_FOUND,
}

// Enhanced error message with context and suggestions
print_error_with_context :: proc(
	error_type: ErrorType,
	resource: string,
	context_msg: string = "",
) {
	fmt.eprintf("%s%sERROR:%s ", BOLD, ERROR, RESET)

	switch error_type {
	case .FILE_NOT_FOUND:
		fmt.eprintfln("File not found: %s%s%s", BRIGHT_YELLOW, resource, RESET)

		if strings.contains(resource, ".config/wayu") {
			fmt.eprintfln("\n%sSuggestion:%s Run %swayu init%s to create configuration files",
				BRIGHT_CYAN, RESET, BOLD, RESET)
			fmt.eprintfln("            This will set up all required configuration files in ~/.config/wayu and ~/.local/share/wayu/")
		} else {
			fmt.eprintfln("\n%sSuggestion:%s Check the file path and try again",
				BRIGHT_CYAN, RESET)
		}

	case .PERMISSION_DENIED:
		fmt.eprintfln("Permission denied: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		fmt.eprintfln("\n%sSuggestion:%s Check file permissions with:", BRIGHT_CYAN, RESET)
		fmt.eprintfln("            %sls -la %s%s", MUTED, resource, RESET)
		fmt.eprintfln("            You may need to run:")
		fmt.eprintfln("            %schmod 644 %s%s", MUTED, resource, RESET)

	case .FILE_READ_ERROR:
		fmt.eprintfln("Failed to read file: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		if len(context_msg) > 0 {
			fmt.eprintfln("Details: %s", context_msg)
		}
		fmt.eprintfln("\n%sSuggestion:%s Ensure the file is not corrupted or locked by another process",
			BRIGHT_CYAN, RESET)
		fmt.eprintfln("            Try closing other applications that may be using this file")

	case .FILE_WRITE_ERROR:
		fmt.eprintfln("Failed to write file: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		if len(context_msg) > 0 {
			fmt.eprintfln("Details: %s", context_msg)
		}
		fmt.eprintfln("\n%sSuggestion:%s Check disk space and file permissions:", BRIGHT_CYAN, RESET)
		fmt.eprintfln("            %sdf -h%s  # Check disk space", MUTED, RESET)
		fmt.eprintfln("            %sls -la %s%s  # Check permissions", MUTED, resource, RESET)

	case .INVALID_INPUT:
		fmt.eprintfln("Invalid input: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		if len(context_msg) > 0 {
			fmt.eprintfln("Reason: %s", context_msg)
		}
		// Determine command type from resource
		if strings.contains(resource, "alias") {
			fmt.eprintfln("\n%sSuggestion:%s Use %swayu alias help%s for usage information",
				BRIGHT_CYAN, RESET, MUTED, RESET)
		} else if strings.contains(resource, "constant") {
			fmt.eprintfln("\n%sSuggestion:%s Use %swayu constants help%s for usage information",
				BRIGHT_CYAN, RESET, MUTED, RESET)
		} else if strings.contains(resource, "path") {
			fmt.eprintfln("\n%sSuggestion:%s Use %swayu path help%s for usage information",
				BRIGHT_CYAN, RESET, MUTED, RESET)
		} else {
			fmt.eprintfln("\n%sSuggestion:%s Use %swayu help%s for usage information",
				BRIGHT_CYAN, RESET, MUTED, RESET)
		}

	case .CONFIG_NOT_INITIALIZED:
		fmt.eprintfln("Wayu configuration not found in: %s%s%s",
			BRIGHT_YELLOW, resource, RESET)
		fmt.eprintfln("\n%sFirst time using wayu?%s Run the following command:",
			BRIGHT_CYAN, RESET)
		fmt.eprintfln("  %swayu init%s", BOLD, RESET)
		fmt.eprintfln("\nThis will:")
		fmt.eprintfln("  • Create ~/.config/wayu/ and ~/.local/share/wayu/ directories")
		fmt.eprintfln("  • Initialize all configuration files")
		fmt.eprintfln("  • Set up shell integration")

	case .DIRECTORY_NOT_FOUND:
		fmt.eprintfln("Directory not found: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		if len(context_msg) > 0 {
			fmt.eprintfln("Details: %s", context_msg)
		}
		fmt.eprintfln("\n%sSuggestion:%s Verify the directory exists or create it:", BRIGHT_CYAN, RESET)
		fmt.eprintfln("            %smkdir -p %s%s", MUTED, resource, RESET)
	}

	fmt.eprintln()
}

// Check if file exists and is readable
check_file_access :: proc(file_path: string) -> (ok: bool, error_type: ErrorType) {
	if !os.exists(file_path) {
		return false, .FILE_NOT_FOUND
	}

	// Try to open for reading
	handle, err := os.open(file_path, os.O_RDONLY)
	if err != nil {
		return false, .PERMISSION_DENIED
	}
	os.close(handle)

	return true, .FILE_NOT_FOUND // Won't be used when ok=true
}

// Safe file read with detailed error reporting
safe_read_file :: proc(file_path: string) -> (content: []byte, ok: bool) {
	// Check access first
	access_ok, error_type := check_file_access(file_path)
	if !access_ok {
		print_error_with_context(error_type, file_path)
		return nil, false
	}

	// Attempt read
	data, read_err := os.read_entire_file(file_path, context.allocator)
	if read_err != nil {
		print_error_with_context(.FILE_READ_ERROR, file_path)
		return nil, false
	}

	return data, true
}

// Safe file write with detailed error reporting
safe_write_file :: proc(file_path: string, content: []byte) -> bool {
	write_err := os.write_entire_file(file_path, content)
	if write_err != nil {
		// Check specific failure reason
		dir_path := get_directory(file_path)
		defer delete(dir_path)

		if !os.exists(dir_path) {
			print_error_with_context(.DIRECTORY_NOT_FOUND, dir_path,
				"Parent directory does not exist")
		} else {
			// Check disk space
			print_error_with_context(.FILE_WRITE_ERROR, file_path)
		}
		return false
	}
	return true
}

// Helper to get directory from file path
get_directory :: proc(file_path: string) -> string {
	last_slash := -1
	for char, i in file_path {
		if char == '/' {
			last_slash = i
		}
	}

	if last_slash == -1 {
		return "."
	}

	return strings.clone(file_path[:last_slash])
}

// Print formatted error (simple version for backwards compatibility)
print_error_simple :: proc(format: string, args: ..any) {
	fmt.eprintf("%s%sERROR:%s ", BOLD, ERROR, RESET)
	fmt.eprintfln(format, ..args)
}

// Check if wayu is initialized
check_wayu_initialized :: proc() -> bool {
	if !os.exists(wayu.config) {
		print_error_with_context(.CONFIG_NOT_INITIALIZED, wayu.config)
		return false
	}

	// Post-migration: wayu.toml is the single source of truth.
	// The legacy per-type files (path.zsh, aliases.zsh, etc.) are no longer
	// required — they've been superseded by wayu.toml + core.<ext>.
	toml_path := fmt.aprintf("%s/wayu.toml", wayu.config)
	defer delete(toml_path)
	if !os.exists(toml_path) {
		print_error_with_context(.FILE_NOT_FOUND, toml_path)
		return false
	}

	return true
}
