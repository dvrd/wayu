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

	// Check remaining characters (alphanumeric, underscore, or hyphen allowed)
	for r, i in name {
		if !unicode.is_alpha(r) && !unicode.is_digit(r) && r != '_' && r != '-' {
			return ValidationResult {
				valid = false,
				error_message = fmt.aprintf(
					"%s name contains invalid character '%c' at position %d. Only letters, digits, underscores, and hyphens allowed.",
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
