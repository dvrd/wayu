// validation.odin - Input validation and sanitization for shell configurations

package wayu
import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
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
	// Common commands that shouldn't be constant/function names
	"cd",
	"pwd",
	"echo",
	"test",
	"true",
	"false",
}

// Names an alias may not take: the shell grammar words and the declaration /
// flow builtins, whose aliases break every function or plugin parsed after
// them. Commands such as cd, ls or cat may be aliased (`alias cd=z`).
ALIAS_REFUSED_NAMES :: []string {
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
	"coproc",
	"declare",
	"typeset",
	"local",
	"export",
	"readonly",
	"unset",
	"return",
	"exit",
}

// Validate shell identifier (alias/constant name)
// allow_hyphen: aliases may contain `-` after the first character (zsh, bash
// and fish accept it, and TOML bare keys allow it); env var and function
// names may not.
validate_identifier :: proc(
	name: string,
	identifier_type: string,
	allow_hyphen := false,
) -> ValidationResult {
	// Check for empty
	if len(name) == 0 {
		return ValidationResult {
			valid = false,
			error_message = fmt.aprintf("%s name cannot be empty", identifier_type),
		}
	}

	// ASCII only: names become TOML bare keys and shell identifiers, and both
	// are restricted to [A-Za-z_][A-Za-z0-9_] (unicode.is_alpha would let
	// `café` through, producing an invalid wayu.toml and shell syntax errors).
	is_ascii_alpha :: proc(r: rune) -> bool {
		return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
	}
	is_ascii_digit :: proc(r: rune) -> bool {return r >= '0' && r <= '9'}

	// Check first character (must be letter or underscore)
	first_rune, _ := utf8.decode_rune_in_string(name)
	if !is_ascii_alpha(first_rune) && first_rune != '_' {
		return ValidationResult {
			valid = false,
			error_message = fmt.aprintf(
				"%s name must start with an ASCII letter or underscore, got '%c'",
				identifier_type,
				first_rune,
			),
		}
	}

	// Check remaining characters (alphanumeric or underscore — matches
	// POSIX identifier rules; hyphens are invalid in env var names and
	// problematic for shell parsing).
	for r, i in name {
		if !is_ascii_alpha(r) && !is_ascii_digit(r) && r != '_' && !(allow_hyphen && r == '-') {
			return ValidationResult {
				valid = false,
				error_message = fmt.aprintf(
					"%s name contains invalid character '%c' at position %d. Only ASCII letters, digits, %sand underscores allowed.",
					identifier_type,
					r,
					i,
					"hyphens (not first), " if allow_hyphen else "",
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

// Why `name` cannot be an alias name, "" when it can. The one alias name
// rule (OKAMI-366), used by `alias add`, the TUI, templates and the
// entries.json reader; the generator's is_safe_alias_name accepts every name
// this accepts. Allowed: printable ASCII except whitespace, quotes, shell
// metacharacters, glob characters, `=`, `/` (bash refuses it) and `^`
// (zsh extendedglob), not starting with `-`; so `..`, `g.st`, `1x`, `k8s-ctx`
// are fine, and so are command names (`cd`, `ls`). Shell grammar words and
// declaration builtins (ALIAS_REFUSED_NAMES) and `.` are refused.
// Temp-allocated.
alias_name_error :: proc(name: string) -> string {
	if len(name) == 0 {
		return "Alias name cannot be empty"
	}
	if len(name) > 255 {
		return fmt.tprintf(
			"Alias name too long (%d characters). Maximum 255 characters allowed.",
			len(name),
		)
	}
	if name[0] == '-' {
		return fmt.tprintf("Alias name cannot start with '-': %s", name)
	}
	for i in 0 ..< len(name) {
		c := name[i]
		if c <= 0x20 || c >= 0x7f || c == '/' || c == '^' || !is_safe_alias_name(name[i:i + 1]) {
			shown :=
				fmt.tprintf("'%c'", rune(c)) if \
					c > 0x20 && c < 0x7f else \
					fmt.tprintf("byte 0x%02x", c)
			return fmt.tprintf(
				"Alias name contains invalid character %s at position %d (not allowed: whitespace, quotes, $ ` \\ = / ^ ; & | < > ( ) {{ }} [ ] * ? # ~ !, non-ASCII)",
				shown,
				i,
			)
		}
	}
	if name == "." {
		return "Cannot use '.' (the source builtin) as Alias name"
	}
	for reserved_word in ALIAS_REFUSED_NAMES {
		if name == reserved_word {
			return fmt.tprintf("Cannot use shell reserved word '%s' as Alias name", name)
		}
	}
	return ""
}

// Why `value` cannot be stored (alias command, constant value, PATH dir),
// "" when it can: a NUL byte (the shell cannot hold one; it was written raw
// into core.<ext>) or invalid UTF-8 (entries.json is JSON text). `what`
// names the value in the message. Temp-allocated.
stored_value_error :: proc(what: string, value: string) -> string {
	if strings.index_byte(value, 0) >= 0 {
		return fmt.tprintf("%s contains a NUL byte", what)
	}
	if !utf8.valid_string(value) {
		return fmt.tprintf("%s is not valid UTF-8", what)
	}
	return ""
}

// Environment names `wayu const add` refuses (OKAMI-304): setting them from
// wayu breaks the shell or wayu itself (`const add PATH /x` left every new
// shell without ls). zsh ties `path`/`fpath` to PATH/FPATH. Every WAYU_*
// name is refused too (wayu's own settings and runtime variables).
PROTECTED_ENV_NAMES :: []string {
	"PATH",
	"path",
	"FPATH",
	"fpath",
	"HOME",
	"IFS",
	"SHELL",
	"USER",
	"LOGNAME",
	"PWD",
	"OLDPWD",
	"ZDOTDIR",
	"SHLVL",
	"_",
}

// Why `name` is a protected environment name, "" when it is not.
// Temp-allocated.
protected_env_name_error :: proc(name: string) -> string {
	if strings.has_prefix(name, "WAYU_") {
		return fmt.tprintf("%s is reserved: wayu does not manage WAYU_* variables", name)
	}
	for p in PROTECTED_ENV_NAMES {
		if name == p {
			return fmt.tprintf(
				"%s is protected: setting it from wayu would break your shell (protected: %s, WAYU_*)",
				name,
				strings.join(PROTECTED_ENV_NAMES, ", ", context.temp_allocator),
			)
		}
	}
	return ""
}

// Validate alias-specific rules
validate_alias :: proc(name: string, command: string) -> ValidationResult {
	if err := alias_name_error(name); len(err) > 0 {
		return ValidationResult{valid = false, error_message = strings.clone(err)}
	}

	// Check command is not empty
	if len(strings.trim_space(command)) == 0 {
		return ValidationResult {
			valid = false,
			error_message = fmt.aprintf("Alias command cannot be empty"),
		}
	}
	if err := stored_value_error("Alias command", command); len(err) > 0 {
		return ValidationResult{valid = false, error_message = strings.clone(err)}
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
	if err := protected_env_name_error(name); len(err) > 0 {
		return ValidationResult{valid = false, error_message = strings.clone(err)}
	}
	if err := stored_value_error("Constant value", value); len(err) > 0 {
		return ValidationResult{valid = false, error_message = strings.clone(err)}
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
		return ValidationResult {
			valid = true,
			error_message = "",
			warning = fmt.aprintf(
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

// A PATH entry must not contain the PATH separator or line breaks. Shared by
// validate_path (CLI/TUI input) and the [paths] readers (hand-edited TOML).
is_path_entry_safe :: proc(path: string) -> bool {
	return strings.index_any(path, ":\n\r") < 0
}

// Validate path
validate_path :: proc(path: string) -> ValidationResult {
	if len(strings.trim_space(path)) == 0 {
		return ValidationResult{valid = false, error_message = fmt.aprintf("Path cannot be empty")}
	}

	// NUL bytes (security) / invalid UTF-8 (entries.json is JSON text).
	if err := stored_value_error("Path", path); len(err) > 0 {
		return ValidationResult{valid = false, error_message = strings.clone(err)}
	}

	// ':' is the PATH separator: "/x/a:." would put "/x/a" AND "." (the CWD)
	// on PATH. Newlines break the line-oriented generated files.
	if !is_path_entry_safe(path) {
		return ValidationResult {
			valid = false,
			error_message = fmt.aprintf("Path cannot contain ':' or newlines (PATH separator)"),
		}
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
	eprintf_color("%s%sERROR:%s ", BOLD, ERROR, RESET)

	switch error_type {
	case .FILE_NOT_FOUND:
		eprintfln_color("File not found: %s%s%s", BRIGHT_YELLOW, resource, RESET)

		if strings.contains(resource, "/wayu/") {
			fmt.eprintfln(
				"\n%sSuggestion:%s Run %swayu init%s to create configuration files",
				BRIGHT_CYAN,
				RESET,
				BOLD,
				RESET,
			)
			fmt.eprintfln(
				"            This sets up ~/.config/wayu/ (config) and ~/.local/share/wayu/ (data)",
			)
		} else {
			fmt.eprintfln(
				"\n%sSuggestion:%s Check the file path and try again",
				BRIGHT_CYAN,
				RESET,
			)
		}

	case .PERMISSION_DENIED:
		eprintfln_color("Permission denied: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		eprintfln_color("\n%sSuggestion:%s Check file permissions with:", BRIGHT_CYAN, RESET)
		eprintfln_color("            %sls -la %s%s", MUTED, resource, RESET)
		fmt.eprintfln("            You may need to run:")
		eprintfln_color("            %schmod 644 %s%s", MUTED, resource, RESET)

	case .FILE_READ_ERROR:
		eprintfln_color("Failed to read file: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		if len(context_msg) > 0 {
			fmt.eprintfln("Details: %s", context_msg)
		}
		fmt.eprintfln(
			"\n%sSuggestion:%s Ensure the file is not corrupted or locked by another process",
			BRIGHT_CYAN,
			RESET,
		)
		fmt.eprintfln("            Try closing other applications that may be using this file")

	case .FILE_WRITE_ERROR:
		eprintfln_color("Failed to write file: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		if len(context_msg) > 0 {
			fmt.eprintfln("Details: %s", context_msg)
		}
		eprintfln_color(
			"\n%sSuggestion:%s Check disk space and file permissions:",
			BRIGHT_CYAN,
			RESET,
		)
		eprintfln_color("            %sdf -h%s  # Check disk space", MUTED, RESET)
		eprintfln_color("            %sls -la %s%s  # Check permissions", MUTED, resource, RESET)

	case .INVALID_INPUT:
		eprintfln_color("Invalid input: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		if len(context_msg) > 0 {
			fmt.eprintfln("Reason: %s", context_msg)
		}
		// Determine command type from resource
		if strings.contains(resource, "alias") {
			fmt.eprintfln(
				"\n%sSuggestion:%s Use %swayu alias help%s for usage information",
				BRIGHT_CYAN,
				RESET,
				MUTED,
				RESET,
			)
		} else if strings.contains(resource, "constant") {
			fmt.eprintfln(
				"\n%sSuggestion:%s Use %swayu constants help%s for usage information",
				BRIGHT_CYAN,
				RESET,
				MUTED,
				RESET,
			)
		} else if strings.contains(resource, "path") {
			fmt.eprintfln(
				"\n%sSuggestion:%s Use %swayu path help%s for usage information",
				BRIGHT_CYAN,
				RESET,
				MUTED,
				RESET,
			)
		} else {
			fmt.eprintfln(
				"\n%sSuggestion:%s Use %swayu help%s for usage information",
				BRIGHT_CYAN,
				RESET,
				MUTED,
				RESET,
			)
		}

	case .CONFIG_NOT_INITIALIZED:
		fmt.eprintfln("Wayu configuration not found in: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		fmt.eprintfln(
			"\n%sFirst time using wayu?%s Run the following command:",
			BRIGHT_CYAN,
			RESET,
		)
		eprintfln_color("  %swayu init%s", BOLD, RESET)
		fmt.eprintfln("\nThis will:")
		fmt.eprintfln("  • Create ~/.config/wayu/ and ~/.local/share/wayu/")
		fmt.eprintfln("  • Initialize all configuration files")
		fmt.eprintfln("  • Set up shell integration")

	case .DIRECTORY_NOT_FOUND:
		eprintfln_color("Directory not found: %s%s%s", BRIGHT_YELLOW, resource, RESET)
		if len(context_msg) > 0 {
			fmt.eprintfln("Details: %s", context_msg)
		}
		eprintfln_color(
			"\n%sSuggestion:%s Verify the directory exists or create it:",
			BRIGHT_CYAN,
			RESET,
		)
		eprintfln_color("            %smkdir -p %s%s", MUTED, resource, RESET)
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

// Safe file write with detailed error reporting. Atomic (temp + fsync +
// rename, see write_file_atomic): a crash never leaves a truncated file.
safe_write_file :: proc(file_path: string, content: []byte) -> bool {
	write_err := write_file_atomic(file_path, content)
	if write_err != nil {
		// Check specific failure reason
		dir_path := get_directory(file_path)
		defer delete(dir_path)

		if !os.exists(dir_path) {
			print_error_with_context(
				.DIRECTORY_NOT_FOUND,
				dir_path,
				"Parent directory does not exist",
			)
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
	// The TUI (print_quiet) captures it for its notification instead of
	// writing over the alternate screen.
	if print_quiet {
		print_error(format, ..args)
		return
	}
	eprintf_color("%s%sERROR:%s ", BOLD, ERROR, RESET)
	fmt.eprintfln(format, ..args)
}

// Check if wayu is initialized
// Cached result for check_wayu_initialized — avoids repeated os.exists
// calls and path allocation on every sub-command.
@(private = "file")
WAYU_INIT_CHECK: struct {
	done:   bool,
	result: bool,
} = {}

check_wayu_initialized :: proc() -> bool {
	if WAYU_INIT_CHECK.done {
		return WAYU_INIT_CHECK.result
	}

	if !os.exists(wayu.config) {
		print_error_with_context(.CONFIG_NOT_INITIALIZED, wayu.config)
		WAYU_INIT_CHECK = {
			done   = true,
			result = false,
		}
		return false
	}

	// Post-migration: wayu.toml is the single source of truth.
	toml_path := fmt.aprintf("%s/wayu.toml", wayu.config)
	defer delete(toml_path)
	if !os.exists(toml_path) {
		print_error_with_context(.FILE_NOT_FOUND, toml_path)
		WAYU_INIT_CHECK = {
			done   = true,
			result = false,
		}
		return false
	}

	WAYU_INIT_CHECK = {
		done   = true,
		result = true,
	}
	return true
}
