package wayu_tui

import "core:fmt"
import "core:c"
import "core:os"
import "core:strconv"
import "core:strings"
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

// Get terminal dimensions.
// Tries three methods in order:
//   1. ioctl TIOCGWINSZ (most reliable when available)
//   2. $COLUMNS / $LINES environment variables (set by most shells)
//   3. ANSI cursor-position probe (works in any VT100-compatible terminal)
//   4. Fallback to 80x24
get_terminal_size :: proc() -> (width, height: int, ok: bool) {
    // Method 1: ioctl (fast, no I/O).
    ws: winsize
    if ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
        return int(ws.ws_col), int(ws.ws_row), true
    }

    // Method 2: environment variables (shells like zsh/bash export these).
    // Use stack buffers to avoid heap allocation.
    {
        cols_buf: [16]byte
        rows_buf: [16]byte
        cols_str, cols_err := os.lookup_env_buf(cols_buf[:], "COLUMNS")
        rows_str, rows_err := os.lookup_env_buf(rows_buf[:], "LINES")
        if cols_err == nil && rows_err == nil {
            cols, cols_ok := strconv.parse_int(cols_str)
            rows, rows_ok := strconv.parse_int(rows_str)
            if cols_ok && rows_ok && cols > 0 && rows > 0 {
                return cols, rows, true
            }
        }
    }

    // Method 3: ANSI cursor-position probe.
    // Move cursor to bottom-right corner, then query position.
    // Response: ESC [ rows ; cols R
    {
        // Save cursor, move to 999;999, query position.
        os.write(os.stdout, transmute([]u8)string("\x1b[s\x1b[999;999H\x1b[6n\x1b[u"))

        // Read response (up to 32 bytes, format: ESC [ rows ; cols R).
        buf: [32]byte
        n, err := os.read(os.stdin, buf[:])
        if err == nil && n > 0 {
            response := string(buf[:n])
            // Parse ESC [ rows ; cols R
            if esc_idx := strings.index_byte(response, '['); esc_idx >= 0 {
                inner := response[esc_idx + 1:]
                if r_idx := strings.index_byte(inner, 'R'); r_idx >= 0 {
                    inner = inner[:r_idx]
                    if semi := strings.index_byte(inner, ';'); semi >= 0 {
                        rows, rows_ok := strconv.parse_int(inner[:semi])
                        cols, cols_ok := strconv.parse_int(inner[semi + 1:])
                        if rows_ok && cols_ok && cols > 0 && rows > 0 {
                            return cols, rows, true
                        }
                    }
                }
            }
        }
    }

    return 80, 24, false  // Last resort fallback.
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
