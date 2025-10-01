package wayu

import "core:fmt"

// ANSI color codes similar to gum
RESET     :: "\x1b[0m"
BOLD      :: "\x1b[1m"
DIM       :: "\x1b[2m"
ITALIC    :: "\x1b[3m"
UNDERLINE :: "\x1b[4m"

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

// Common gum-style colors
PRIMARY    :: BRIGHT_CYAN
SECONDARY  :: BRIGHT_MAGENTA
SUCCESS    :: BRIGHT_GREEN
WARNING    :: BRIGHT_YELLOW
ERROR      :: BRIGHT_RED
MUTED      :: BRIGHT_BLACK
ACCENT     :: MAGENTA

// Emojis
EMOJI_SUCCESS   :: "✅"
EMOJI_ERROR     :: "❌"
EMOJI_WARNING   :: "⚠️"
EMOJI_INFO      :: "ℹ️"
EMOJI_QUESTION  :: "❓"
EMOJI_ROCKET    :: "🚀"
EMOJI_GEAR      :: "⚙️"
EMOJI_FILE      :: "📁"
EMOJI_PATH      :: "🗂️"
EMOJI_ALIAS     :: "🔗"
EMOJI_CONSTANT  :: "📦"
EMOJI_REMOVE    :: "🗑️"
EMOJI_ADD       :: "➕"
EMOJI_LIST      :: "📋"

// Styled print functions
print_success :: proc(msg: string, args: ..any) {
	fmt.printf("%s%s %s", SUCCESS, EMOJI_SUCCESS, RESET)
	fmt.printf(msg, ..args)
	fmt.println()
}

print_error :: proc(msg: string, args: ..any) {
	fmt.printf("%s%s %s", ERROR, EMOJI_ERROR, RESET)
	fmt.printf(msg, ..args)
	fmt.println()
}

print_warning :: proc(msg: string, args: ..any) {
	fmt.printf("%s%s %s", WARNING, EMOJI_WARNING, RESET)
	fmt.printf(msg, ..args)
	fmt.println()
}

print_info :: proc(msg: string, args: ..any) {
	fmt.printf("%s%s %s", PRIMARY, EMOJI_INFO, RESET)
	fmt.printf(msg, ..args)
	fmt.println()
}

print_header :: proc(msg: string, emoji: string = EMOJI_ROCKET) {
	fmt.printf("%s%s%s  %s%s%s\n", BOLD, PRIMARY, emoji, msg, RESET, RESET)
}

print_section :: proc(msg: string) {
	fmt.printf("\n%s%s%s %s%s\n", BOLD, ACCENT, EMOJI_GEAR, msg, RESET)
}

print_item :: proc(prefix: string, name: string, value: string = "", emoji: string = "") {
	if emoji != "" {
		fmt.printf("  %s%s%s ", MUTED, emoji, RESET)
	} else {
		fmt.printf("  %s%s%s ", MUTED, prefix, RESET)
	}

	if value != "" {
		fmt.printf("%s%s%s%s %s->%s %s%s%s\n",
			BOLD, PRIMARY, name, RESET,
			BRIGHT_YELLOW, RESET,
			SECONDARY, value, RESET)
	} else {
		fmt.printf("%s%s%s%s\n", BOLD, PRIMARY, name, RESET)
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