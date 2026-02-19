package wayu_tui

import "core:fmt"
import "core:c"
import "base:intrinsics"

// Platform-specific constants
when ODIN_OS == .Darwin {
    TIOCGWINSZ :: 0x40087468
} else when ODIN_OS == .Linux {
    TIOCGWINSZ :: 0x5413
}

// ANSI escape codes
ENTER_ALT_SCREEN :: "\x1b[?1049h"
EXIT_ALT_SCREEN  :: "\x1b[?1049l"
HIDE_CURSOR      :: "\x1b[?25l"
SHOW_CURSOR      :: "\x1b[?25h"

// Terminal size structure
winsize :: struct {
    ws_row:    c.ushort,
    ws_col:    c.ushort,
    ws_xpixel: c.ushort,
    ws_ypixel: c.ushort,
}

// Foreign imports
foreign import libc "system:c"

foreign libc {
    ioctl :: proc(fd: c.int, request: c.ulong, arg: rawptr) -> c.int ---
    signal :: proc(sig: c.int, handler: proc "c" (i32)) -> proc "c" (i32) ---
}

// Signal constants
SIGWINCH :: 28  // Signal number for window resize (macOS/Linux)

// Global resize flag
terminal_resized: bool

// Get terminal dimensions
get_terminal_size :: proc() -> (width, height: int, ok: bool) {
    ws: winsize
    result := ioctl(1, TIOCGWINSZ, &ws)  // 1 = STDOUT_FILENO

    if result == 0 {
        return int(ws.ws_col), int(ws.ws_row), true
    }

    return 80, 24, false  // Fallback
}

// SIGWINCH handler (MUST be "c" convention)
// Uses volatile_store to ensure the write is visible to the main loop
sigwinch_handler :: proc "c" (sig: i32) {
    intrinsics.volatile_store(&terminal_resized, true)
}

// Setup resize signal handler
setup_resize_handler :: proc() {
    signal(SIGWINCH, sigwinch_handler)
}

// Enter alternate screen buffer
enter_alt_screen :: proc() {
    fmt.print(ENTER_ALT_SCREEN)
}

// Exit alternate screen buffer
exit_alt_screen :: proc() {
    fmt.print(EXIT_ALT_SCREEN)
}

// TUI lifecycle initialization
tui_lifecycle_init :: proc() {
    enter_alt_screen()
    fmt.print(HIDE_CURSOR)
    setup_resize_handler()
}

// TUI lifecycle cleanup
tui_lifecycle_cleanup :: proc() {
    fmt.print(SHOW_CURSOR)
    exit_alt_screen()
}
