package wayu
import "core:fmt"
import "core:os"
import "core:strings"
// ANSI color codes similar to gum
RESET_CODE     :: "\x1b[0m"
BOLD_CODE      :: "\x1b[1m"
DIM_CODE       :: "\x1b[2m"
ITALIC_CODE    :: "\x1b[3m"
UNDERLINE_CODE :: "\x1b[4m"

// Runtime variables (modified by init_colors())
RESET:     string = RESET_CODE
BOLD:      string = BOLD_CODE
DIM:       string = DIM_CODE
ITALIC:    string = ITALIC_CODE
UNDERLINE: string = UNDERLINE_CODE

// Color Profile for terminal capability detection
ColorProfile :: enum {
	ASCII,      // No colors (NO_COLOR env)
	ANSI,       // 16 colors (basic terminals)
	ANSI256,    // 256 colors (most terminals)
	TRUECOLOR,  // 24-bit RGB (modern terminals)
}

// Palette tokens are runtime vars, not constants: set_plain_output blanks
// every one of them under the ASCII profile (NO_COLOR, --no-color, output
// not a terminal), so no call site can leak an escape code (OKAMI-238).

// Foreground colors
BLACK:   string = "\x1b[30m"
RED:     string = "\x1b[31m"
GREEN:   string = "\x1b[32m"
YELLOW:  string = "\x1b[33m"
BLUE:    string = "\x1b[34m"
MAGENTA: string = "\x1b[35m"
CYAN:    string = "\x1b[36m"
WHITE:   string = "\x1b[37m"

// Bright colors
BRIGHT_BLACK:   string = "\x1b[90m"
BRIGHT_RED:     string = "\x1b[91m"
BRIGHT_GREEN:   string = "\x1b[92m"
BRIGHT_YELLOW:  string = "\x1b[93m"
BRIGHT_BLUE:    string = "\x1b[94m"
BRIGHT_MAGENTA: string = "\x1b[95m"
BRIGHT_CYAN:    string = "\x1b[96m"
BRIGHT_WHITE:   string = "\x1b[97m"

// Background colors
BG_BLACK:   string = "\x1b[40m"
BG_RED:     string = "\x1b[41m"
BG_GREEN:   string = "\x1b[42m"
BG_YELLOW:  string = "\x1b[43m"
BG_BLUE:    string = "\x1b[44m"
BG_MAGENTA: string = "\x1b[45m"
BG_CYAN:    string = "\x1b[46m"
BG_WHITE:   string = "\x1b[47m"

// Common gum-style colors (LEGACY - for backward compatibility)
PRIMARY:    string = "\x1b[96m"  // BRIGHT_CYAN
SECONDARY:  string = "\x1b[95m"  // BRIGHT_MAGENTA
SUCCESS:    string = "\x1b[92m"  // BRIGHT_GREEN
WARNING:    string = "\x1b[93m"  // BRIGHT_YELLOW
ERROR:      string = "\x1b[91m"  // BRIGHT_RED
MUTED:      string = "\x1b[90m"  // BRIGHT_BLACK
ACCENT:     string = "\x1b[35m"  // MAGENTA

// ============================================================================
// VIBRANT COLOR PALETTE (Phase 1 - PRP-09)
// TrueColor (24-bit RGB) - Zellij "dvrd" theme inspired
// ============================================================================

// Primary Colors (From Zellij dvrd theme)
VIBRANT_PRIMARY:   string = "\x1b[38;2;228;0;80m"     // Hot pink #E40050 (emphasis_2)
VIBRANT_SECONDARY: string = "\x1b[38;2;14;116;144m"   // Teal-cyan #0E7490 (emphasis_1)
VIBRANT_ACCENT:    string = "\x1b[38;2;194;65;12m"    // Orange-red #C2410C (emphasis_0)

// Semantic Colors (Zellij-inspired)
VIBRANT_SUCCESS:   string = "\x1b[38;2;14;116;144m"   // Teal (reusing emphasis_1)
VIBRANT_ERROR:     string = "\x1b[38;2;153;27;27m"    // Dark red #991B1B
VIBRANT_WARNING:   string = "\x1b[38;2;217;119;6m"    // Orange #D97706
VIBRANT_INFO:      string = "\x1b[38;2;14;116;144m"   // Teal-cyan #0E7490

// UI Elements
VIBRANT_HIGHLIGHT:   string = "\x1b[38;2;228;0;80m"     // Hot pink (primary)
VIBRANT_SELECTED_BG: string = "\x1b[48;2;9;9;11m"       // Almost black background
VIBRANT_MUTED:       string = "\x1b[38;2;208;208;208m"  // Light gray (base text)
VIBRANT_DIM:         string = "\x1b[38;2;100;100;100m"  // Dimmer gray

// Background colors (Zellij backgrounds)
BG_DARK:   string = "\x1b[48;2;24;24;37m"   // Dark purple-blue
BG_DARKER: string = "\x1b[48;2;9;9;11m"     // Almost black

// Gradient colors (using Zellij theme colors)
GRADIENT_START: string = "\x1b[38;2;194;65;12m"   // Orange-red
GRADIENT_END:   string = "\x1b[38;2;228;0;80m"    // Hot pink

// ANSI 256 fallback colors (closest matches to Zellij theme)
ANSI256_PRIMARY   :: "\x1b[38;5;197m"  // Hot pink
ANSI256_SECONDARY :: "\x1b[38;5;31m"   // Teal
ANSI256_ACCENT    :: "\x1b[38;5;166m"  // Orange
ANSI256_SUCCESS   :: "\x1b[38;5;31m"   // Teal
ANSI256_ERROR     :: "\x1b[38;5;124m"  // Dark red
ANSI256_WARNING   :: "\x1b[38;5;172m"  // Orange
ANSI256_INFO      :: "\x1b[38;5;31m"   // Teal

// ============================================================================
// TERMINAL CAPABILITY DETECTION
// ============================================================================

// Global color profile (initialized once by init_colors). Defaults to ANSI
// so it agrees with the palette tokens' initial (colored) values.
CURRENT_COLOR_PROFILE: ColorProfile = .ANSI

// True when env var `name` is set to something other than "" or "0".
@(private = "file")
env_flag_set :: proc(name: string) -> bool {
	v := os.get_env(name, context.temp_allocator)
	return len(v) > 0 && v != "0"
}

// FORCE_COLOR / CLICOLOR_FORCE keep colors on when output is not a terminal.
@(private = "file")
color_forced :: proc() -> bool {
	return env_flag_set("FORCE_COLOR") || env_flag_set("CLICOLOR_FORCE")
}

// Detect terminal color capabilities
detect_color_profile :: proc() -> ColorProfile {
	// Check NO_COLOR environment variable (standard)
	no_color := os.get_env("NO_COLOR", context.temp_allocator)
	if len(no_color) > 0 {
		return .ASCII
	}

	// Check WAYU_PLAIN for explicit plain output
	wayu_plain := os.get_env("WAYU_PLAIN", context.temp_allocator)
	if len(wayu_plain) > 0 {
		return .ASCII
	}

	// Piped/redirected stdout gets plain text unless colors are forced.
	if !color_forced() && !is_stdout_tty() {
		return .ASCII
	}

	// Check COLORTERM for TrueColor support
	colorterm := os.get_env("COLORTERM", context.temp_allocator)
	if colorterm == "truecolor" || colorterm == "24bit" {
		return .TRUECOLOR
	}

	// Check TERM for 256 color support
	term := os.get_env("TERM", context.temp_allocator)
	if strings.contains(term, "256color") {
		return .ANSI256
	}

	// Check if running in a known TrueColor terminal
	term_program := os.get_env("TERM_PROGRAM", context.temp_allocator)
	if term_program == "iTerm.app" ||
	   term_program == "Apple_Terminal" ||
	   term_program == "vscode" ||
	   strings.contains(term, "kitty") ||
	   strings.contains(term, "alacritty") ||
	   strings.contains(term, "wezterm") {
		return .TRUECOLOR
	}

	// Default to basic ANSI colors
	return .ANSI
}

// Whether stderr output (errors, warnings) may carry escape codes. Decided
// separately from stdout: `wayu path list 2>log` keeps a colored table but
// writes a plain log. eprintf_color/eprintfln_color honor it.
stderr_color: bool

// Initialize color profile (call once at startup)
init_colors :: proc() {
	CURRENT_COLOR_PROFILE = detect_color_profile()
	if CURRENT_COLOR_PROFILE == .ASCII {
		set_plain_output()
		return
	}
	stderr_color = color_forced() || is_tty(STDERR_FILENO)
}

// Switch to plain output for the rest of the run: ASCII profile and every
// palette token blanked (used by NO_COLOR, --no-color, non-TTY stdout).
set_plain_output :: proc() {
	CURRENT_COLOR_PROFILE = .ASCII
	stderr_color = false
	tokens := [?]^string{
		&RESET, &BOLD, &DIM, &ITALIC, &UNDERLINE,
		&BLACK, &RED, &GREEN, &YELLOW, &BLUE, &MAGENTA, &CYAN, &WHITE,
		&BRIGHT_BLACK, &BRIGHT_RED, &BRIGHT_GREEN, &BRIGHT_YELLOW,
		&BRIGHT_BLUE, &BRIGHT_MAGENTA, &BRIGHT_CYAN, &BRIGHT_WHITE,
		&BG_BLACK, &BG_RED, &BG_GREEN, &BG_YELLOW, &BG_BLUE, &BG_MAGENTA, &BG_CYAN, &BG_WHITE,
		&PRIMARY, &SECONDARY, &SUCCESS, &WARNING, &ERROR, &MUTED, &ACCENT,
		&VIBRANT_PRIMARY, &VIBRANT_SECONDARY, &VIBRANT_ACCENT, &VIBRANT_SUCCESS,
		&VIBRANT_ERROR, &VIBRANT_WARNING, &VIBRANT_INFO, &VIBRANT_HIGHLIGHT,
		&VIBRANT_SELECTED_BG, &VIBRANT_MUTED, &VIBRANT_DIM,
		&BG_DARK, &BG_DARKER, &GRADIENT_START, &GRADIENT_END,
	}
	for t in tokens { t^ = "" }
	SYMBOL_CHECK_SUCCESS = "✓"
	SYMBOL_CHECK_ERROR   = "✗"
	SYMBOL_CHECK_MISSING = "○"
	SYMBOL_CHECK_WARN    = "⚠"
}

// fmt.eprintf that strips escape codes unless stderr_color is set.
eprintf_color :: proc(format: string, args: ..any) {
	text := fmt.tprintf(format, ..args)
	if stderr_color {
		fmt.eprint(text)
		return
	}
	plain := strip_ansi_codes(text, allocator = context.temp_allocator)
	fmt.eprint(plain)
}

// fmt.eprintfln that strips escape codes unless stderr_color is set.
eprintfln_color :: proc(format: string, args: ..any) {
	eprintf_color(format, ..args)
	fmt.eprintln()
}

// Get adaptive color based on terminal capabilities
adaptive_color :: proc(truecolor, ansi256, ansi: string) -> string {
	switch CURRENT_COLOR_PROFILE {
	case .TRUECOLOR: return truecolor
	case .ANSI256:   return ansi256
	case .ANSI:      return ansi
	case .ASCII:     return ""
	}
	return ansi  // fallback
}

// Smart color getters that adapt to terminal
get_primary :: proc() -> string {
	return adaptive_color(VIBRANT_PRIMARY, ANSI256_PRIMARY, BRIGHT_CYAN)
}

get_secondary :: proc() -> string {
	return adaptive_color(VIBRANT_SECONDARY, ANSI256_SECONDARY, BRIGHT_MAGENTA)
}

get_accent :: proc() -> string {
	return adaptive_color(VIBRANT_ACCENT, ANSI256_ACCENT, MAGENTA)
}

get_success :: proc() -> string {
	return adaptive_color(VIBRANT_SUCCESS, ANSI256_SUCCESS, BRIGHT_GREEN)
}

get_error :: proc() -> string {
	return adaptive_color(VIBRANT_ERROR, ANSI256_ERROR, BRIGHT_RED)
}

get_warning :: proc() -> string {
	return adaptive_color(VIBRANT_WARNING, ANSI256_WARNING, BRIGHT_YELLOW)
}

get_info :: proc() -> string {
	return adaptive_color(VIBRANT_INFO, ANSI256_INFO, BRIGHT_CYAN)
}

get_muted :: proc() -> string {
	return adaptive_color(VIBRANT_MUTED, BRIGHT_BLACK, BRIGHT_BLACK)
}

get_bold :: proc() -> string {
	return BOLD
}

get_reset :: proc() -> string {
	return RESET
}

// Get current color profile
get_color_profile :: proc() -> ColorProfile {
	return CURRENT_COLOR_PROFILE
}

// Canonical ANSI-strip routine. Removes CSI escape sequences (ESC '[' ... final)
// where the final byte is in the standard CSI range 0x40..0x7E. When
// newlines_to_space is set, '\n' and '\r' are collapsed to a single space so
// table rows stay intact. A lone ESC not starting a CSI sequence is preserved.
strip_ansi_codes :: proc(text: string, newlines_to_space := false, allocator := context.allocator) -> string {
	// Fast path: nothing to strip or rewrite.
	needs := false
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if c == '\x1b' || (newlines_to_space && (c == '\n' || c == '\r')) {
			needs = true
			break
		}
	}
	if !needs {
		return strings.clone(text, allocator)
	}

	buf := make([dynamic]byte, 0, len(text), allocator)
	defer delete(buf)
	i := 0
	for i < len(text) {
		c := text[i]
		if c == '\x1b' && i + 1 < len(text) && text[i+1] == '[' {
			// Skip CSI: ESC '[' params/intermediates until final byte 0x40..0x7E.
			i += 2
			for i < len(text) && !(text[i] >= 0x40 && text[i] <= 0x7e) {
				i += 1
			}
			if i < len(text) {
				i += 1 // skip the terminating final byte
			}
		} else if newlines_to_space && (c == '\n' || c == '\r') {
			append(&buf, ' ')
			i += 1
		} else {
			append(&buf, c)
			i += 1
		}
	}
	return strings.clone(string(buf[:]), allocator)
}

// Emojis
EMOJI_SUCCESS   :: "✅"
EMOJI_ERROR     :: "❌"
EMOJI_WARNING   :: "󰀦 "
EMOJI_INFO      :: "󰋽 "
EMOJI_QUESTION  :: "❓"
EMOJI_ROCKET    :: "🚀"
EMOJI_MOUNTAIN  :: "⛰️"
EMOJI_USER      :: "󰼭 "
EMOJI_COMMAND   :: " "
EMOJI_ACTION    :: " "
EMOJI_CYCLIST   :: " "
EMOJI_FILE      :: " "
EMOJI_PATH      :: " "
EMOJI_ALIAS     :: " "
EMOJI_CONSTANT  :: " "
EMOJI_REMOVE    :: " "
EMOJI_ADD       :: "➕"
EMOJI_LIST      :: " "

// Colored Status Symbols (using Zellij theme colors)
SYMBOL_CHECK_SUCCESS: string = "\x1b[38;2;14;116;144m✓\x1b[0m"   // Teal checkmark
SYMBOL_CHECK_ERROR:   string = "\x1b[38;2;153;27;27m✗\x1b[0m"    // Red X
SYMBOL_CHECK_MISSING: string = "\x1b[38;2;217;119;6m○\x1b[0m"    // Orange circle
SYMBOL_CHECK_WARN:    string = "\x1b[38;2;217;119;6m⚠\x1b[0m"    // Orange warning

// ============================================================================
// ENHANCED PRINT FUNCTIONS (PRP-09 Phase 1)
// Using adaptive vibrant colors
// ============================================================================

// When true, print_success/print_warning/print_info/print_error write nothing.
// The TUI sets this while it owns the terminal so shared CLI code paths
// (entry_add, backups, plugin ops) can't scribble over the alternate screen.
// print_error messages are captured instead (see take_print_capture).
print_quiet: bool

// Last print_error message emitted while print_quiet was set (heap-owned).
@(private="file")
print_captured_error: string

// Return the last captured print_error message ("" if none) and reset the
// capture. Caller owns the returned string when non-empty.
take_print_capture :: proc() -> string {
	msg := print_captured_error
	print_captured_error = ""
	return msg
}

// Drop any captured message.
clear_print_capture :: proc() {
	if len(print_captured_error) > 0 {
		delete(print_captured_error)
	}
	print_captured_error = ""
}

// Styled print functions. Success/info go to stdout; errors and warnings go
// to stderr so `wayu ... --json | jq` and captured output stay clean.
print_success :: proc(msg: string, args: ..any) {
	if print_quiet do return
	fmt.printf("%s✓ ", get_success())
	fmt.printf(msg, ..args)
	fmt.printf("%s\n", RESET)
}

print_error :: proc(msg: string, args: ..any) {
	if print_quiet {
		clear_print_capture()
		print_captured_error = fmt.aprintf(msg, ..args)
		// The TUI redirects stderr to a file it replays only if it dies
		// (os.exit from shared code, crash): keep the reason there too.
		if tui_stderr_capturing() do fmt.eprintfln("ERROR: %s", print_captured_error)
		return
	}
	eprintf_color("%s%sERROR:%s ", BOLD, get_error(), RESET)
	eprintf_color(msg, ..args)
	fmt.eprintln()
}

print_warning :: proc(msg: string, args: ..any) {
	if print_quiet do return
	eprintf_color("%s⚠ ", get_warning())
	eprintf_color(msg, ..args)
	eprintf_color("%s\n", RESET)
}

// Status lines nested under a parent line: the indent goes before the icon.
print_success_at :: proc(indent: string, msg: string, args: ..any) {
	if print_quiet do return
	fmt.print(indent)
	print_success(msg, ..args)
}

print_warning_at :: proc(indent: string, msg: string, args: ..any) {
	if print_quiet do return
	eprintf_color("%s", indent)
	print_warning(msg, ..args)
}

print_info_at :: proc(indent: string, msg: string, args: ..any) {
	if print_quiet do return
	fmt.print(indent)
	print_info(msg, ..args)
}

print_info :: proc(msg: string, args: ..any) {
	if print_quiet do return
	fmt.printf("%sℹ ", get_info())
	fmt.printf(msg, ..args)
	fmt.printf("%s\n", RESET)
}

print_header :: proc(msg: string, emoji: string = EMOJI_ROCKET) {
	fmt.printf("%s%s%s %s%s%s\n", get_bold(), get_primary(), emoji, msg, get_reset(), get_reset())
}

print_section :: proc(msg: string, emoji: string) {
	fmt.printf("%s%s%s %s%s%s\n", get_bold(), get_secondary(), emoji, msg, get_reset(), get_reset())
}

print_item :: proc(prefix: string, name: string, value: string = "", emoji: string = "") {
	if value != "" {
		fmt.printf("  %-20s %s\n", name, value)
	} else {
		fmt.printf("  %s\n", name)
	}
}

print_prompt :: proc(msg: string) {
	fmt.printf("\n%s%s %s%s %s", PRIMARY, EMOJI_QUESTION, BOLD, msg, RESET)
}

stylize :: proc(text: string, color: string, style: string = "") -> string {
	if style != "" {
		return fmt.aprintf("%s%s%s%s", style, color, text, RESET)
	}
	return fmt.aprintf("%s%s%s", color, text, RESET)
}
// json_escape_string_builder escapes JSON-special characters into a strings.Builder.
@(private="file")
json_escape_string_builder :: proc(builder: ^strings.Builder, str: string) {
	for r in str {
		switch r {
		case '"':
			strings.write_string(builder, `\"`)
		case '\\':
			strings.write_string(builder, `\\`)
		case '\n':
			strings.write_string(builder, `\n`)
		case '\t':
			strings.write_string(builder, `\t`)
		case:
			if r < 0x20 {
				fmt.sbprintf(builder, "\\u%04x", r)
			} else {
				strings.write_rune(builder, r)
			}
		}
	}
}

// json_escape returns `str` with JSON-mandatory characters escaped.
// Caller owns the returned string and must `delete` it.
json_escape :: proc(str: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	json_escape_string_builder(&builder, str)
	return strings.clone(strings.to_string(builder))
}

// AliasEntry represents a single alias (used by init_generator)
AliasEntry :: struct {
	name:    string,
	command: string,
}
