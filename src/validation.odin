// validation.odin - Input validation and sanitization for shell configurations

package wayu

import "core:strings"
import "core:unicode"
import "core:fmt"

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

	// Check remaining characters (alphanumeric or underscore only)
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

// Sanitize shell command value (escape dangerous characters)
sanitize_shell_value :: proc(value: string) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	for r in value {
		switch r {
		case '"':
			// Escape double quotes
			strings.write_string(&builder, "\\\"")
		case '`':
			// Escape backticks (command substitution)
			strings.write_string(&builder, "\\`")
		case '$':
			// Escape dollar sign (variable expansion)
			strings.write_string(&builder, "\\$")
		case '\\':
			// Escape backslash
			strings.write_string(&builder, "\\\\")
		case '\n':
			// Escape newlines
			strings.write_string(&builder, "\\n")
		case:
			strings.write_rune(&builder, r)
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
