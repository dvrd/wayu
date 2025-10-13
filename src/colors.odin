package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// ANSI color codes similar to gum
RESET     :: "\x1b[0m"
BOLD      :: "\x1b[1m"
DIM       :: "\x1b[2m"
ITALIC    :: "\x1b[3m"
UNDERLINE :: "\x1b[4m"

// Color Profile for terminal capability detection
ColorProfile :: enum {
	ASCII,      // No colors (NO_COLOR env)
	ANSI,       // 16 colors (basic terminals)
	ANSI256,    // 256 colors (most terminals)
	TRUECOLOR,  // 24-bit RGB (modern terminals)
}

// Foreground colors
BLACK   :: "\x1b[30m"
RED     :: "\x1b[31m"
GREEN   :: "\x1b[32m"
YELLOW  :: "\x1b[33m"
BLUE    :: "\x1b[34m"
MAGENTA :: "\x1b[35m"
CYAN    :: "\x1b[36m"
WHITE   :: "\x1b[37m"

// Bright colors
BRIGHT_BLACK   :: "\x1b[90m"
BRIGHT_RED     :: "\x1b[91m"
BRIGHT_GREEN   :: "\x1b[92m"
BRIGHT_YELLOW  :: "\x1b[93m"
BRIGHT_BLUE    :: "\x1b[94m"
BRIGHT_MAGENTA :: "\x1b[95m"
BRIGHT_CYAN    :: "\x1b[96m"
BRIGHT_WHITE   :: "\x1b[97m"

// Background colors
BG_BLACK   :: "\x1b[40m"
BG_RED     :: "\x1b[41m"
BG_GREEN   :: "\x1b[42m"
BG_YELLOW  :: "\x1b[43m"
BG_BLUE    :: "\x1b[44m"
BG_MAGENTA :: "\x1b[45m"
BG_CYAN    :: "\x1b[46m"
BG_WHITE   :: "\x1b[47m"

// Common gum-style colors (LEGACY - for backward compatibility)
PRIMARY    :: BRIGHT_CYAN
SECONDARY  :: BRIGHT_MAGENTA
SUCCESS    :: BRIGHT_GREEN
WARNING    :: BRIGHT_YELLOW
ERROR      :: BRIGHT_RED
MUTED      :: BRIGHT_BLACK
ACCENT     :: MAGENTA

// ============================================================================
// VIBRANT COLOR PALETTE (Phase 1 - PRP-09)
// TrueColor (24-bit RGB) - Zellij "dvrd" theme inspired
// ============================================================================

// Primary Colors (From Zellij dvrd theme)
VIBRANT_PRIMARY   :: "\x1b[38;2;228;0;80m"     // Hot pink #E40050 (emphasis_2)
VIBRANT_SECONDARY :: "\x1b[38;2;14;116;144m"   // Teal-cyan #0E7490 (emphasis_1)
VIBRANT_ACCENT    :: "\x1b[38;2;194;65;12m"    // Orange-red #C2410C (emphasis_0)

// Semantic Colors (Zellij-inspired)
VIBRANT_SUCCESS   :: "\x1b[38;2;14;116;144m"   // Teal (reusing emphasis_1)
VIBRANT_ERROR     :: "\x1b[38;2;153;27;27m"    // Dark red #991B1B
VIBRANT_WARNING   :: "\x1b[38;2;217;119;6m"    // Orange #D97706
VIBRANT_INFO      :: "\x1b[38;2;14;116;144m"   // Teal-cyan #0E7490

// UI Elements
VIBRANT_HIGHLIGHT   :: "\x1b[38;2;228;0;80m"     // Hot pink (primary)
VIBRANT_SELECTED_BG :: "\x1b[48;2;9;9;11m"       // Almost black background
VIBRANT_MUTED       :: "\x1b[38;2;208;208;208m"  // Light gray (base text)
VIBRANT_DIM         :: "\x1b[38;2;100;100;100m"  // Dimmer gray

// Background colors (Zellij backgrounds)
BG_DARK   :: "\x1b[48;2;24;24;37m"   // Dark purple-blue
BG_DARKER :: "\x1b[48;2;9;9;11m"     // Almost black

// Gradient colors (using Zellij theme colors)
GRADIENT_START :: "\x1b[38;2;194;65;12m"   // Orange-red
GRADIENT_END   :: "\x1b[38;2;228;0;80m"    // Hot pink

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

// Global color profile (initialized once)
CURRENT_COLOR_PROFILE: ColorProfile

// Detect terminal color capabilities
detect_color_profile :: proc() -> ColorProfile {
	// Check NO_COLOR environment variable (standard)
	no_color := os.get_env("NO_COLOR")
	defer delete(no_color)
	if len(no_color) > 0 {
		return .ASCII
	}

	// Check WAYU_PLAIN for explicit plain output
	wayu_plain := os.get_env("WAYU_PLAIN")
	defer delete(wayu_plain)
	if len(wayu_plain) > 0 {
		return .ASCII
	}

	// Check COLORTERM for TrueColor support
	colorterm := os.get_env("COLORTERM")
	defer delete(colorterm)
	if colorterm == "truecolor" || colorterm == "24bit" {
		return .TRUECOLOR
	}

	// Check TERM for 256 color support
	term := os.get_env("TERM")
	defer delete(term)
	if strings.contains(term, "256color") {
		return .ANSI256
	}

	// Check if running in a known TrueColor terminal
	term_program := os.get_env("TERM_PROGRAM")
	defer delete(term_program)
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

// Initialize color profile (call once at startup)
init_colors :: proc() {
	CURRENT_COLOR_PROFILE = detect_color_profile()
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

// Get current color profile
get_color_profile :: proc() -> ColorProfile {
	return CURRENT_COLOR_PROFILE
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
SYMBOL_CHECK_SUCCESS :: "\x1b[38;2;14;116;144m✓\x1b[0m"   // Teal checkmark
SYMBOL_CHECK_ERROR   :: "\x1b[38;2;153;27;27m✗\x1b[0m"    // Red X
SYMBOL_CHECK_MISSING :: "\x1b[38;2;217;119;6m○\x1b[0m"    // Orange circle
SYMBOL_CHECK_WARN    :: "\x1b[38;2;217;119;6m⚠\x1b[0m"    // Orange warning

// ============================================================================
// ENHANCED PRINT FUNCTIONS (PRP-09 Phase 1)
// Using adaptive vibrant colors
// ============================================================================

// Styled print functions
print_success :: proc(msg: string, args: ..any) {
	fmt.printf("%s✓ ", get_success())
	fmt.printf(msg, ..args)
	fmt.printf("%s\n", RESET)
}

print_error :: proc(msg: string, args: ..any) {
	fmt.printf("%s%sERROR:%s ", BOLD, get_error(), RESET)
	fmt.printf(msg, ..args)
	fmt.println()
}

print_warning :: proc(msg: string, args: ..any) {
	fmt.printf("%s⚠ ", get_warning())
	fmt.printf(msg, ..args)
	fmt.printf("%s\n", RESET)
}

print_info :: proc(msg: string, args: ..any) {
	fmt.printf("%sℹ ", get_info())
	fmt.printf(msg, ..args)
	fmt.printf("%s\n", RESET)
}

print_header :: proc(msg: string, emoji: string = EMOJI_ROCKET) {
	fmt.printf("%s%s%s %s%s%s\n", BOLD, get_primary(), emoji, msg, RESET, RESET)
}

print_section :: proc(msg: string, emoji: string) {
	fmt.printf("%s%s%s %s%s%s\n", BOLD, get_secondary(), emoji, msg, RESET, RESET)
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
