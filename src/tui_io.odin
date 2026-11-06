package wayu
import "core:fmt"
import "core:c"
import "core:os"
import "core:strconv"
import "core:strings"
import "base:intrinsics"
import "core:time"
import "core:sys/posix"
import "base:runtime"
import "core:unicode/utf8"
foreign import libc "system:c"

foreign libc {
    ioctl :: proc(fd: c.int, request: c.ulong, arg: rawptr) -> c.int ---
    signal :: proc(sig: c.int, handler: proc "c" (i32)) -> proc "c" (i32) ---
    select :: proc(nfds: c.int, readfds: rawptr, writefds: rawptr, errorfds: rawptr, timeout: rawptr) -> c.int ---
}
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
CLEAR_SCREEN     :: "\x1b[2J"
CURSOR_HOME      :: "\x1b[H"

// Terminal size structure
winsize :: struct {
    ws_row:    c.ushort,
    ws_col:    c.ushort,
    ws_xpixel: c.ushort,
    ws_ypixel: c.ushort,
}

// Foreign imports

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
    // Clear the alt screen before exiting so no TUI content bleeds through
    fmt.print(CLEAR_SCREEN)
    fmt.print(CURSOR_HOME)
    fmt.print(SHOW_CURSOR)
    exit_alt_screen()
}

// ============================================================================
// TUI raw mode + emergency terminal restore
// ============================================================================
//
// The TUI owns its own termios snapshot (separate from fuzzy.odin's CLI raw
// mode) because it needs a stricter mode: ISIG/IEXTEN off so Ctrl+C/Ctrl+Z/
// Ctrl+V arrive in-band as bytes, and ICRNL off so Enter (CR) and Ctrl+J (LF)
// stay distinguishable. Every exit path — normal return, SIGTERM/SIGHUP,
// fatal signals from bounds traps, and assert/panic — funnels through
// tui_emergency_restore so the user's shell is never left in raw mode on the
// alternate screen with a hidden cursor.

@(private="file")
tui_saved_termios: posix.termios

// Set once raw mode is active; read from signal handlers (async-signal-safe).
@(private="file")
tui_termios_saved: bool

// Set once the alternate screen has been entered.
@(private="file")
tui_screen_active: bool

// Bytes written on emergency exit: reset SGR, clear, show cursor, leave alt screen.
@(private="file")
TUI_RESTORE_SEQ :: "\x1b[0m\x1b[2J\x1b[H\x1b[?25h\x1b[?1049l"

// Enable the TUI's raw mode. Returns false (terminal untouched) on failure.
tui_enable_raw_mode :: proc() -> bool {
    saved: posix.termios
    if posix.tcgetattr(posix.FD(STDIN_FILENO), &saved) != .OK {
        return false
    }
    raw := saved
    raw.c_lflag -= {.ECHO, .ICANON, .ISIG, .IEXTEN}
    raw.c_iflag -= {.IXON, .IXOFF, .ICRNL, .INLCR, .IGNCR}
    // Fully non-blocking reads are driven by select(); VMIN=1 keeps read()
    // semantics simple when select() reports readiness.
    raw.c_cc[.VMIN]  = 1
    raw.c_cc[.VTIME] = 0
    if posix.tcsetattr(posix.FD(STDIN_FILENO), .TCSANOW, &raw) != .OK {
        return false
    }
    tui_saved_termios = saved
    intrinsics.volatile_store(&tui_termios_saved, true)
    return true
}

// Restore the termios captured by tui_enable_raw_mode (idempotent).
tui_disable_raw_mode :: proc() {
    if !intrinsics.volatile_load(&tui_termios_saved) do return
    posix.tcsetattr(posix.FD(STDIN_FILENO), .TCSANOW, &tui_saved_termios)
    intrinsics.volatile_store(&tui_termios_saved, false)
}

// Mark the alternate screen active/inactive so the emergency path knows
// whether it must leave it.
tui_set_screen_active :: proc(active: bool) {
    intrinsics.volatile_store(&tui_screen_active, active)
}

// Async-signal-safe restore: only tcsetattr + write. Safe to call from a
// signal handler, an assertion-failure proc, or normal cleanup.
tui_emergency_restore :: proc "contextless" () {
    if intrinsics.volatile_load(&tui_termios_saved) {
        posix.tcsetattr(posix.FD(STDIN_FILENO), .TCSANOW, &tui_saved_termios)
        intrinsics.volatile_store(&tui_termios_saved, false)
    }
    if intrinsics.volatile_load(&tui_screen_active) {
        seq := TUI_RESTORE_SEQ
        posix.write(posix.FD(STDOUT_FILENO), raw_data(seq), uint(len(seq)))
        intrinsics.volatile_store(&tui_screen_active, false)
    }
}

// Termination + fatal signals that must restore the terminal before dying.
// SIGILL/SIGTRAP cover Odin bounds-check traps; SIGABRT covers libc aborts.
@(private="file")
TUI_RESTORE_SIGNALS :: [?]posix.Signal{
    .SIGTERM, .SIGHUP, .SIGINT, .SIGQUIT,
    .SIGSEGV, .SIGBUS, .SIGILL, .SIGTRAP, .SIGABRT, .SIGFPE,
}

@(private="file")
tui_signal_handler :: proc "c" (sig: posix.Signal) {
    tui_emergency_restore()
    // Re-raise with the default disposition so the exit status reflects the
    // signal (and core dumps still happen for fatal ones).
    posix.signal(sig, auto_cast posix.SIG_DFL)
    posix.raise(sig)
}

// Install handlers for TUI_RESTORE_SIGNALS.
tui_install_signal_handlers :: proc() {
    for sig in TUI_RESTORE_SIGNALS {
        posix.signal(sig, tui_signal_handler)
    }
}

// Reset handlers installed by tui_install_signal_handlers to SIG_DFL.
tui_uninstall_signal_handlers :: proc() {
    for sig in TUI_RESTORE_SIGNALS {
        posix.signal(sig, auto_cast posix.SIG_DFL)
    }
}

// Assertion-failure proc installed into the TUI's context: restore the
// terminal first so the panic message is readable in the user's shell.
tui_assertion_failure_proc :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
    tui_emergency_restore()
    runtime.default_assertion_failure_proc(prefix, message, loc)
}
// timeval struct for select timeout
timeval :: struct {
    tv_sec:  c.long,
    tv_usec: c.long,
}

// fd_set manipulation for select
FD_SETSIZE :: 1024

@(private)
fd_set :: struct #raw_union {
    bits: [FD_SETSIZE / (8 * size_of(c.long))]c.long,
}

@(private)
fd_zero :: proc(set: ^fd_set) {
    for i in 0..<len(set.bits) {
        set.bits[i] = 0
    }
}

@(private)
fd_set_bit :: proc(set: ^fd_set, fd: c.int) {
    set.bits[fd / (8 * size_of(c.long))] |= 1 << (uint(fd) % (8 * size_of(c.long)))
}

@(private)
fd_isset :: proc(set: ^fd_set, fd: c.int) -> bool {
    return (set.bits[fd / (8 * size_of(c.long))] >> (uint(fd) % (8 * size_of(c.long)))) & 1 != 0
}

// Field order is layout-optimized (data-oriented): the 8-byte-aligned
// strings come first, then the 4-byte rune, then the 1-byte bools. This
// packs Cell into 40 bytes instead of 48 (rune no longer forces 4 bytes of
// padding before `fg`). Cells are bulk-allocated as a width*height grid and
// touched every frame, so the 17% shrink improves render-loop cache density.
Cell :: struct {
	fg:    string,
	bg:    string,
	char:  rune,
	bold:  bool,
	dim:   bool,
}

Screen :: struct {
	buffer:      [][]Cell,
	prev_buffer: [][]Cell,
	width:       int,
	height:      int,
	cursor_x:    int,
	cursor_y:    int,
}

// Create screen with dimensions
screen_create :: proc(width, height: int) -> Screen {
	buffer := make([][]Cell, height)
	prev_buffer := make([][]Cell, height)

	for y in 0..<height {
		buffer[y] = make([]Cell, width)
		prev_buffer[y] = make([]Cell, width)

		// Initialize with space cells
		for x in 0..<width {
			buffer[y][x] = Cell{char = ' '}
			prev_buffer[y][x] = Cell{char = ' '}
		}
	}

	return Screen{
		buffer = buffer,
		prev_buffer = prev_buffer,
		width = width,
		height = height,
	}
}

// Free only the cell buffers (used by screen_resize to preserve other fields).
screen_free_buffers :: proc(screen: ^Screen) {
	for y in 0..<len(screen.buffer) {
		delete(screen.buffer[y])
		delete(screen.prev_buffer[y])
	}
	delete(screen.buffer)
	delete(screen.prev_buffer)
}

// Destroy screen and free memory
screen_destroy :: proc(screen: ^Screen) {
	screen_free_buffers(screen)
}

// Resize screen, preserving content
screen_resize :: proc(screen: ^Screen, new_width, new_height: int) {
	// Allocate new buffers
	new_buffer := make([][]Cell, new_height)
	new_prev_buffer := make([][]Cell, new_height)

	for y in 0..<new_height {
		new_buffer[y] = make([]Cell, new_width)
		new_prev_buffer[y] = make([]Cell, new_width)

		// Initialize with spaces
		for x in 0..<new_width {
			new_buffer[y][x] = Cell{char = ' '}
			new_prev_buffer[y][x] = Cell{char = ' '}
		}

		// Copy existing content
		if y < screen.height {
			copy_width := min(new_width, screen.width)
			copy(new_buffer[y][:copy_width], screen.buffer[y][:copy_width])
			copy(new_prev_buffer[y][:copy_width], screen.prev_buffer[y][:copy_width])
		}
	}

	// Free old buffers only (preserve cursor and any future fields)
	screen_free_buffers(screen)

	// Update screen
	screen.buffer = new_buffer
	screen.prev_buffer = new_prev_buffer
	screen.width = new_width
	screen.height = new_height
}

// Marks the right half of a double-width glyph. The lead cell (x-1) holds
// the rune; screen_flush emits nothing for continuation cells because the
// terminal already advanced two columns when printing the lead.
CELL_CONTINUATION :: rune(-1)

// Set cell at position.
// Overwriting either half of a double-width glyph blanks the other half so
// the buffer never holds an orphaned lead or continuation cell.
screen_set_cell :: proc(screen: ^Screen, x, y: int, cell: Cell) {
	if x < 0 || x >= screen.width || y < 0 || y >= screen.height do return
	row := screen.buffer[y]
	if row[x].char == CELL_CONTINUATION && cell.char != CELL_CONTINUATION && x > 0 {
		row[x - 1] = Cell{char = ' '}
	}
	if x + 1 < screen.width && row[x + 1].char == CELL_CONTINUATION {
		row[x + 1] = Cell{char = ' '}
	}
	row[x] = cell
}

// Put one rune at (x, y) honoring its display width. Returns the number of
// columns consumed: 0 for zero-width runes or when a wide rune doesn't fit
// before `limit` (exclusive right edge; defaults to the screen width).
screen_put_rune :: proc(screen: ^Screen, x, y: int, r: rune, cell: Cell, limit := -1) -> int {
	right := screen.width if limit < 0 else min(limit, screen.width)
	w := get_rune_width(r)
	if w <= 0 do return 0
	if x + w > right do return 0
	c := cell
	c.char = r
	screen_set_cell(screen, x, y, c)
	if w == 2 {
		cont := cell
		cont.char = CELL_CONTINUATION
		screen_set_cell(screen, x + 1, y, cont)
	}
	return w
}

// Clear screen (fill with spaces, reset all formatting)
screen_clear :: proc(screen: ^Screen) {
	for y in 0..<screen.height {
		for x in 0..<screen.width {
			// Clear cell completely - char AND all formatting fields
			screen.buffer[y][x] = Cell{char = ' ', fg = "", bg = "", bold = false, dim = false}
		}
	}
}

// Convert screen buffer to plain text string (no ANSI codes)
// Used for component testing and golden file generation
screen_to_string :: proc(screen: ^Screen) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	for y in 0..<screen.height {
		for x in 0..<screen.width {
			cell := screen.buffer[y][x]
			if cell.char == CELL_CONTINUATION do continue
			strings.write_rune(&builder, cell.char)
		}
		// Add newline after each row except the last
		if y < screen.height - 1 {
			fmt.sbprintf(&builder, "\n")
		}
	}

	// Clone the string before builder is destroyed
	return strings.clone(strings.to_string(builder))
}
// Event types
Event :: union {
    KeyEvent,
    MouseEvent,
    ResizeEvent,
}

KeyEvent :: struct {
    key:       Key,
    char:      rune,
    modifiers: KeyModifiers,
}

MouseEvent :: struct {
    x, y:      int,
    button:    int,
}

ResizeEvent :: struct {
    width, height: int,
}

Key :: enum {
    None,
    Char,
    Enter,
    Tab,
    Backspace,
    Delete,
    Escape,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    F1, F2, F3, F4, F5, F6,
    F7, F8, F9, F10, F11, F12,
}

KeyModifiers :: bit_set[KeyModifier]
KeyModifier :: enum {
    Shift,
    Ctrl,
    Alt,
}

// ============================================================================
// Input decoding
// ============================================================================
//
// Raw bytes from stdin are accumulated in input_pending and decoded one event
// at a time, so a single read() containing several keys (paste, key repeat,
// fast typing) yields several events instead of only the first byte.
// Sequences split across reads are completed by the next read; a lone ESC is
// disambiguated from the start of an escape sequence by waiting
// ESC_SEQUENCE_TIMEOUT_US for more bytes.

INPUT_BUFFER_SIZE       :: 512
POLL_TIMEOUT_US         :: 50_000  // main-loop tick (resize checks, notifications)
ESC_SEQUENCE_TIMEOUT_US :: 25_000  // lone ESC vs. start of a CSI/SS3 sequence

@(private="file")
input_pending: [INPUT_BUFFER_SIZE]u8
@(private="file")
input_pending_len: int

ParseStatus :: enum {
	Ok,          // event decoded, `consumed` bytes used
	Incomplete,  // need more bytes to decide
	Invalid,     // unrecognised input; skip `consumed` bytes
}

// Wait up to timeout_us for stdin to become readable.
@(private="file")
stdin_ready :: proc(timeout_us: int) -> bool {
	readfds: fd_set
	fd_zero(&readfds)
	fd_set_bit(&readfds, c.int(STDIN_FILENO))
	timeout := timeval{
		tv_sec  = c.long(timeout_us / 1_000_000),
		tv_usec = c.long(timeout_us % 1_000_000),
	}
	return select(c.int(STDIN_FILENO) + 1, &readfds, nil, nil, &timeout) > 0
}

// Append whatever stdin has to input_pending. Returns false on EOF/error.
@(private="file")
fill_input :: proc() -> bool {
	space := input_pending[input_pending_len:]
	if len(space) == 0 do return true
	n, err := os.read(os.stdin, space)
	if err != nil || n <= 0 do return false
	input_pending_len += n
	return true
}

@(private="file")
consume_input :: proc(count: int) {
	n := clamp(count, 0, input_pending_len)
	copy(input_pending[:], input_pending[n:input_pending_len])
	input_pending_len -= n
}

// Poll for events with timeout (non-blocking).
// Returns: Event if available, nil if timeout or no decodable data.
poll_event :: proc() -> Event {
	if input_pending_len == 0 {
		if !stdin_ready(POLL_TIMEOUT_US) do return nil
		if !fill_input() do return nil
	}

	for input_pending_len > 0 {
		key, consumed, status := parse_input_event(input_pending[:input_pending_len], false)
		switch status {
		case .Ok:
			consume_input(consumed)
			return key
		case .Invalid:
			consume_input(max(1, consumed))
		case .Incomplete:
			// More bytes may be in flight (split escape sequence / UTF-8 rune).
			if input_pending_len < INPUT_BUFFER_SIZE && stdin_ready(ESC_SEQUENCE_TIMEOUT_US) && fill_input() {
				continue
			}
			// Nothing more arrived: decode what we have as final input
			// (a lone ESC becomes the Escape key).
			key, consumed, status = parse_input_event(input_pending[:input_pending_len], true)
			consume_input(max(1, consumed))
			if status == .Ok do return key
		}
	}
	return nil
}

// Decode the first event in `buf`. When `final` is true no more bytes will
// follow, so a lone ESC is the Escape key and truncated sequences are invalid.
parse_input_event :: proc(buf: []u8, final: bool) -> (key: KeyEvent, consumed: int, status: ParseStatus) {
	if len(buf) == 0 do return {}, 0, .Incomplete

	ch := buf[0]

	if ch == 27 {
		return parse_escape_sequence(buf, final)
	}

	switch ch {
	case 13:     return KeyEvent{key = .Enter}, 1, .Ok
	case 9:      return KeyEvent{key = .Tab}, 1, .Ok
	case 127, 8: return KeyEvent{key = .Backspace}, 1, .Ok
	case 0:      return {}, 1, .Invalid
	}

	// Control keys (Ctrl+A = 1 … Ctrl+Z = 26). LF (10) is Ctrl+J: the TUI
	// clears ICRNL, so Enter arrives as CR and LF stays distinguishable.
	if ch >= 1 && ch <= 26 {
		return KeyEvent{key = .Char, char = rune('a' + ch - 1), modifiers = {.Ctrl}}, 1, .Ok
	}
	if ch < 32 do return {}, 1, .Invalid  // other C0 controls (FS, GS, …)

	// Printable ASCII
	if ch < 0x80 {
		return KeyEvent{key = .Char, char = rune(ch)}, 1, .Ok
	}

	// UTF-8 multi-byte rune
	need := 0
	switch {
	case ch & 0xE0 == 0xC0: need = 2
	case ch & 0xF0 == 0xE0: need = 3
	case ch & 0xF8 == 0xF0: need = 4
	case:                   return {}, 1, .Invalid  // stray continuation byte
	}
	if len(buf) < need {
		// Make sure what we have so far is a plausible prefix.
		for i in 1..<len(buf) {
			if buf[i] & 0xC0 != 0x80 do return {}, 1, .Invalid
		}
		return {}, 0, .Invalid if final else .Incomplete
	}
	r, size := utf8.decode_rune(buf[:need])
	if r == utf8.RUNE_ERROR || size != need do return {}, 1, .Invalid
	if r < 0xA0 do return {}, need, .Invalid  // C1 controls
	return KeyEvent{key = .Char, char = r}, need, .Ok
}

@(private="file")
parse_escape_sequence :: proc(buf: []u8, final: bool) -> (key: KeyEvent, consumed: int, status: ParseStatus) {
	if len(buf) == 1 {
		if final do return KeyEvent{key = .Escape}, 1, .Ok
		return {}, 0, .Incomplete
	}

	switch buf[1] {
	case '[':
		// CSI: ESC [ params(0x30-0x3F)* intermediates(0x20-0x2F)* final(0x40-0x7E)
		i := 2
		for i < len(buf) && buf[i] >= 0x20 && buf[i] <= 0x3F {
			i += 1
		}
		if i >= len(buf) {
			return {}, (len(buf) if final else 0), (.Invalid if final else .Incomplete)
		}
		final_byte := buf[i]
		if final_byte < 0x40 || final_byte > 0x7E {
			return {}, i, .Invalid  // malformed: drop up to the bad byte
		}
		consumed = i + 1
		params := string(buf[2:i])
		// Modifier parameter (e.g. ESC [ 1 ; 5 A = Ctrl+Up).
		mods: KeyModifiers
		first := params
		if semi := strings.index_byte(params, ';'); semi >= 0 {
			first = params[:semi]
			if m, ok := strconv.parse_int(params[semi + 1:]); ok && m > 1 {
				bits := m - 1
				if bits & 1 != 0 do mods += {.Shift}
				if bits & 2 != 0 do mods += {.Alt}
				if bits & 4 != 0 do mods += {.Ctrl}
			}
		}
		k: Key
		switch final_byte {
		case 'A': k = .Up
		case 'B': k = .Down
		case 'C': k = .Right
		case 'D': k = .Left
		case 'H': k = .Home
		case 'F': k = .End
		case 'Z': return KeyEvent{key = .Tab, modifiers = {.Shift}}, consumed, .Ok
		case '~':
			n, ok := strconv.parse_int(first)
			if !ok do return {}, consumed, .Invalid
			switch n {
			case 1, 7:  k = .Home
			case 2:     return {}, consumed, .Invalid  // Insert: unused
			case 3:     k = .Delete
			case 4, 8:  k = .End
			case 5:     k = .PageUp
			case 6:     k = .PageDown
			case 11:    k = .F1
			case 12:    k = .F2
			case 13:    k = .F3
			case 14:    k = .F4
			case 15:    k = .F5
			case 17:    k = .F6
			case 18:    k = .F7
			case 19:    k = .F8
			case 20:    k = .F9
			case 21:    k = .F10
			case 23:    k = .F11
			case 24:    k = .F12
			case:       return {}, consumed, .Invalid
			}
		case:
			return {}, consumed, .Invalid  // unsupported CSI (mouse, focus, …)
		}
		return KeyEvent{key = k, modifiers = mods}, consumed, .Ok

	case 'O':
		// SS3: ESC O <final> (F1-F4, application-mode arrows/Home/End)
		if len(buf) < 3 {
			return {}, (len(buf) if final else 0), (.Invalid if final else .Incomplete)
		}
		k: Key
		switch buf[2] {
		case 'P': k = .F1
		case 'Q': k = .F2
		case 'R': k = .F3
		case 'S': k = .F4
		case 'A': k = .Up
		case 'B': k = .Down
		case 'C': k = .Right
		case 'D': k = .Left
		case 'H': k = .Home
		case 'F': k = .End
		case:     return {}, 3, .Invalid
		}
		return KeyEvent{key = k}, 3, .Ok

	case 27:
		// ESC ESC: first one is a plain Escape.
		return KeyEvent{key = .Escape}, 1, .Ok
	}

	// ESC followed by anything else: a plain Escape keypress (the next byte is
	// decoded as its own key). wayu has no Alt bindings, and treating it as
	// Alt+key would turn a quick "Esc, d" into a stray 'd' action.
	return KeyEvent{key = .Escape}, 1, .Ok
}

// Parse the first key event from input_buf[:n], treating the buffer as
// complete (no further bytes will arrive). Kept for callers/tests that hand
// in one key's worth of bytes.
parse_key_event :: proc(input_buf: []byte, length: int) -> (KeyEvent, bool) {
	n := clamp(length, 0, len(input_buf))
	if n == 0 do return {}, false
	key, _, status := parse_input_event(input_buf[:n], true)
	return key, status == .Ok
}
// ============================================================================
// Color profile adaptation
// ============================================================================

// Color capability the TUI renders with. tui_run copies CURRENT_COLOR_PROFILE
// here (NO_COLOR/--no-color → .ASCII). Defaults to TRUECOLOR so headless
// rendering/tests see the raw palette.
tui_color_mode: ColorProfile = .TRUECOLOR

// Write a TUI color escape adapted to tui_color_mode. TUI palette constants
// are truecolor SGR ("\x1b[38;2;R;G;Bm" / "\x1b[48;2;...m"); lower profiles get
// the nearest 256/16 color, ASCII gets nothing.
write_tui_color :: proc(b: ^strings.Builder, code: string) {
	if len(code) == 0 do return
	switch tui_color_mode {
	case .TRUECOLOR:
		strings.write_string(b, code)
		return
	case .ASCII:
		return
	case .ANSI256, .ANSI:
	}
	is_bg, r, g, bl, ok := parse_truecolor_sgr(code)
	if !ok {
		strings.write_string(b, code)
		return
	}
	if tui_color_mode == .ANSI256 {
		fmt.sbprintf(b, "\x1b[%d;5;%dm", 48 if is_bg else 38, rgb_to_ansi256(r, g, bl))
	} else {
		idx := rgb_to_ansi16(r, g, bl)
		base := 40 if is_bg else 30
		if idx >= 8 {
			base = 100 if is_bg else 90
		}
		fmt.sbprintf(b, "\x1b[%dm", base + idx % 8)
	}
}

// Parse "\x1b[38;2;R;G;Bm" (fg) or "\x1b[48;2;R;G;Bm" (bg).
parse_truecolor_sgr :: proc(code: string) -> (is_bg: bool, r, g, b: int, ok: bool) {
	body := code
	if !strings.has_prefix(body, "\x1b[") || !strings.has_suffix(body, "m") do return
	body = body[2:len(body) - 1]
	if strings.has_prefix(body, "38;2;") {
		is_bg = false
	} else if strings.has_prefix(body, "48;2;") {
		is_bg = true
	} else {
		return
	}
	body = body[5:]
	vals: [3]int
	for i in 0..<3 {
		end := strings.index_byte(body, ';')
		part := body if end < 0 else body[:end]
		v, v_ok := strconv.parse_int(part)
		if !v_ok || v < 0 || v > 255 do return
		vals[i] = v
		if i < 2 {
			if end < 0 do return
			body = body[end + 1:]
		}
	}
	return is_bg, vals[0], vals[1], vals[2], true
}

// Nearest xterm-256 color index for an RGB triple.
rgb_to_ansi256 :: proc(r, g, b: int) -> int {
	if r == g && g == b {
		if r < 8 do return 16
		if r > 248 do return 231
		return 232 + (r - 8) * 24 / 247
	}
	level :: proc(v: int) -> int {
		if v < 48 do return 0
		if v < 115 do return 1
		return (v - 35) / 40
	}
	return 16 + 36 * level(r) + 6 * level(g) + level(b)
}

// Nearest of the 16 standard ANSI colors (0-7 normal, 8-15 bright).
rgb_to_ansi16 :: proc(r, g, b: int) -> int {
	PALETTE :: [16][3]int{
		{0, 0, 0}, {205, 0, 0}, {0, 205, 0}, {205, 205, 0},
		{0, 0, 238}, {205, 0, 205}, {0, 205, 205}, {229, 229, 229},
		{127, 127, 127}, {255, 0, 0}, {0, 255, 0}, {255, 255, 0},
		{92, 92, 255}, {255, 0, 255}, {0, 255, 255}, {255, 255, 255},
	}
	palette := PALETTE
	best, best_dist := 0, max(int)
	for c, i in palette {
		dr, dg, db := r - c[0], g - c[1], b - c[2]
		dist := dr*dr + dg*dg + db*db
		if dist < best_dist {
			best, best_dist = i, dist
		}
	}
	return best
}

// ============================================================================
// Primary Colors
// ============================================================================

// Hot pink - Main accent color for highlights, selected items, focused borders
TUI_PRIMARY :: "\x1b[38;2;228;0;80m"  // #E40050

// Teal-cyan - Secondary elements, success indicators
TUI_SECONDARY :: "\x1b[38;2;14;116;144m"  // #0E7490

// ============================================================================
// Semantic Colors
// ============================================================================

// Success color - Teal (same as secondary)
TUI_SUCCESS :: "\x1b[38;2;14;116;144m"  // #0E7490

// Error color - Dark red
TUI_ERROR :: "\x1b[38;2;153;27;27m"  // #991B1B

// Warning color - Amber
TUI_WARNING :: "\x1b[38;2;217;119;6m"  // #D97706

// Bright orange - Focused button highlight, active form field cursor
TUI_ORANGE :: "\x1b[38;2;255;140;0m"  // #FF8C00

// Info color - Teal-cyan (same as secondary)
TUI_INFO :: "\x1b[38;2;14;116;144m"  // #0E7490

// Source indicators - Green for wayu active, Yellow for inactive, Blue for external
TUI_SOURCE_WAYU_ACTIVE :: "\x1b[38;2;34;197;94m"    // #22C55E (green)
TUI_SOURCE_WAYU_INACTIVE :: "\x1b[38;2;217;119;6m"  // #D97706 (amber/yellow)
TUI_SOURCE_EXTERNAL :: "\x1b[38;2;59;130;246m"      // #3B82F6 (blue)
TUI_SOURCE_SHADOWED :: "\x1b[38;2;168;85;247m"      // #A855F7 (purple)

// ============================================================================
// UI Element Colors
// ============================================================================

// Highlight color - Hot pink (same as primary)
TUI_HIGHLIGHT :: "\x1b[38;2;228;0;80m"  // #E40050

// Muted text - Light gray for secondary text
TUI_MUTED :: "\x1b[38;2;208;208;208m"  // #D0D0D0

// Dim text - Dimmer gray for disabled/subtle text
TUI_DIM :: "\x1b[38;2;100;100;100m"  // #646464

// Divider line - Very dim gray for horizontal separators between menu items
TUI_DIVIDER :: "\x1b[38;2;51;51;51m"  // #333333

// ============================================================================
// Background Colors
// ============================================================================

// Normal background - Dark purple-blue
TUI_BG_NORMAL :: "\x1b[48;2;24;24;37m"  // #181825

// Selected item background - Almost black for maximum contrast
TUI_BG_SELECTED :: "\x1b[48;2;9;9;11m"  // #09090B

// Header/footer background - Slightly lighter than normal
TUI_BG_HEADER :: "\x1b[48;2;18;18;27m"  // #12121B

// ============================================================================
// Border Colors
// ============================================================================

// Normal border color - Gray for inactive panels
TUI_BORDER_NORMAL :: "\x1b[38;2;100;100;100m"  // #646464

// Focused border color - Hot pink for active panel
TUI_BORDER_FOCUSED :: "\x1b[38;2;228;0;80m"  // #E40050

// ============================================================================
// Box Drawing Characters (Unicode)
// ============================================================================

// Light single-line box drawing (standard style)
BOX_HORIZONTAL     :: '─'  // U+2500
BOX_VERTICAL       :: '│'  // U+2502
BOX_TOP_LEFT       :: '┌'  // U+250C
BOX_TOP_RIGHT      :: '┐'  // U+2510
BOX_BOTTOM_LEFT    :: '└'  // U+2514
BOX_BOTTOM_RIGHT   :: '┘'  // U+2518
BOX_VERTICAL_RIGHT :: '├'  // U+251C (left T-junction)
BOX_VERTICAL_LEFT  :: '┤'  // U+2524 (right T-junction)
BOX_HORIZONTAL_DOWN :: '┬'  // U+252C (top T-junction)
BOX_HORIZONTAL_UP   :: '┴'  // U+2534 (bottom T-junction)
BOX_CROSS          :: '┼'  // U+253C (4-way intersection)

// Rounded corners (softer appearance)
BOX_ROUND_TOP_LEFT     :: '╭'  // U+256D
BOX_ROUND_TOP_RIGHT    :: '╮'  // U+256E
BOX_ROUND_BOTTOM_LEFT  :: '╰'  // U+256F
BOX_ROUND_BOTTOM_RIGHT :: '╯'  // U+2570

// Heavy/thick box drawing (for emphasis)
BOX_HEAVY_HORIZONTAL     :: '━'  // U+2501
BOX_HEAVY_VERTICAL       :: '┃'  // U+2503
BOX_HEAVY_TOP_LEFT       :: '┏'  // U+250F
BOX_HEAVY_TOP_RIGHT      :: '┓'  // U+2513
BOX_HEAVY_BOTTOM_LEFT    :: '┗'  // U+2517
BOX_HEAVY_BOTTOM_RIGHT   :: '┛'  // U+251B

// Double-line box drawing (for strong emphasis)
BOX_DBL_HORIZONTAL     :: '═'  // U+2550
BOX_DBL_VERTICAL       :: '║'  // U+2551
BOX_DBL_TOP_LEFT       :: '╔'  // U+2554
BOX_DBL_TOP_RIGHT      :: '╗'  // U+2557
BOX_DBL_BOTTOM_LEFT    :: '╚'  // U+255A
BOX_DBL_BOTTOM_RIGHT   :: '╝'  // U+255D

// ============================================================================
// Helper: Color Aliases for Backward Compatibility
// ============================================================================

// These aliases map new naming to old code expecting different names
TUI_FG_NORMAL    :: TUI_MUTED      // Normal text
TUI_FG_SELECTED  :: TUI_PRIMARY    // Selected item text
TUI_FG_HIGHLIGHT :: TUI_HIGHLIGHT  // Highlighted text
TUI_FG_MUTED     :: TUI_DIM        // Muted text
// ============================================================================
// Border Layout Constants
// ============================================================================

// Border dimensions (box-drawing characters take 1 cell)
BORDER_TOP_HEIGHT    :: 1  // Top border line
BORDER_BOTTOM_HEIGHT :: 1  // Bottom border line
BORDER_LEFT_WIDTH    :: 1  // Left border column
BORDER_RIGHT_WIDTH   :: 1  // Right border column

// Total border overhead
BORDER_HORIZONTAL_TOTAL :: BORDER_LEFT_WIDTH + BORDER_RIGHT_WIDTH  // 2 cells
BORDER_VERTICAL_TOTAL   :: BORDER_TOP_HEIGHT + BORDER_BOTTOM_HEIGHT  // 2 cells

// ============================================================================
// Header Layout Constants
// ============================================================================

// Header line positions (inside border, 1-indexed from border top)
HEADER_TITLE_LINE  :: 1  // Line 1: Main title (e.g., "📂 PATH Configuration")
HEADER_COUNT_LINE  :: 2  // Line 2: Item count (e.g., "35 entries")
HEADER_HEIGHT      :: 2  // Total header height in lines

// Blank line after header before content starts
HEADER_CONTENT_GAP :: 1

// ============================================================================
// Footer Layout Constants
// ============================================================================

// Footer height and position
FOOTER_HEIGHT :: 1  // Footer takes 1 line
FOOTER_OFFSET_FROM_BOTTOM :: 2  // Footer is 2 lines from bottom (border + footer)

// Notification bar height (rendered between footer and bottom border)
NOTIFICATION_HEIGHT :: 1

// ============================================================================
// Content Area Layout Constants
// ============================================================================

// Content area offsets (relative to border)
CONTENT_PADDING_LEFT :: 2  // Indent content 2 cells from left border
CONTENT_PADDING_TOP  :: 1  // 1 line padding from border top

// List item positioning
LIST_ITEM_START_LINE :: CONTENT_PADDING_TOP + HEADER_HEIGHT + HEADER_CONTENT_GAP  // Line 4 (1 + 2 + 1)
LIST_ITEM_INDENT     :: CONTENT_PADDING_LEFT  // Indent items 2 cells from border

// Selection indicator
SELECTION_PREFIX_WIDTH :: 2  // "> " takes 2 characters

// Main menu item layout (dashboard-style with dividers)
MENU_ITEM_SPACING :: 2  // Each menu item occupies 2 rows (text + divider)
MENU_ACCENT_BAR_WIDTH :: 1  // ┃ accent bar is 1 cell
MENU_ACCENT_GAP :: 2  // Gap after accent bar before text

// ============================================================================
// Visible Height Calculation Constants
// ============================================================================

// Calculate visible height for scrollable lists
// Formula: terminal_height - (borders + header + gap + footer + margins)
//
// Breakdown:
// - BORDER_TOP_HEIGHT (1): Top border
// - CONTENT_PADDING_TOP (1): Padding after top border
// - HEADER_HEIGHT (2): Title + count lines
// - HEADER_CONTENT_GAP (1): Blank line after header
// - FOOTER_HEIGHT (1): Footer line
// - FOOTER_OFFSET_FROM_BOTTOM (2): Footer + bottom border
//
// Total overhead: 1 + 1 + 2 + 1 + 1 = 6 lines
// (border_top + padding_top + header_height + header_gap + footer+border_bottom)
// Notification is rendered outside the box — not counted in visible list height
VISIBLE_HEIGHT_OVERHEAD :: 6

// ============================================================================
// Helper Functions
// ============================================================================

// Calculate visible height for list items
calculate_visible_height :: proc(terminal_height: int) -> int {
	return terminal_height - VISIBLE_HEIGHT_OVERHEAD
}

// Calculate footer Y position
calculate_footer_y :: proc(terminal_height: int) -> int {
	return terminal_height - FOOTER_OFFSET_FROM_BOTTOM - 1  // -1 for border
}

// Calculate list item Y position
calculate_list_item_y :: proc(index_in_visible_area: int) -> int {
	return LIST_ITEM_START_LINE + index_in_visible_area
}

// Calculate border dimensions (responsive - fills terminal width)
calculate_border_dimensions :: proc(terminal_width, terminal_height: int) -> (width: int, height: int) {
	width = terminal_width - BORDER_HORIZONTAL_TOTAL
	height = terminal_height - BORDER_VERTICAL_TOTAL - NOTIFICATION_HEIGHT
	return
}

// Calculate max content width inside the border box (for text truncation)
tui_calculate_content_width :: proc(border_width: int) -> int {
	// border_width includes left+right border chars
	// Inside: CONTENT_PADDING_LEFT + SELECTION_PREFIX_WIDTH + text + right margin
	return border_width - CONTENT_PADDING_LEFT - SELECTION_PREFIX_WIDTH - BORDER_RIGHT_WIDTH - 1
}

// Calculate notification bar Y position (below the border box)
calculate_notification_y :: proc(terminal_height: int) -> int {
	return terminal_height - NOTIFICATION_HEIGHT
}

// ============================================================================
// Responsive Breakpoints
// ============================================================================

// Minimum terminal dimensions the TUI supports.
// Below these the layout still renders but content may truncate.
MIN_TERMINAL_WIDTH  :: 40
MIN_TERMINAL_HEIGHT :: 12

// Width thresholds for layout adaptations.
BREAKPOINT_COMPACT  :: 60  // compact footers, reduced padding
BREAKPOINT_NARROW   :: 50  // minimal layout

// is_compact returns true when the terminal is narrow enough to use
// shortened footer strings and tighter padding.
is_compact :: proc(terminal_width: int) -> bool {
	return terminal_width < BREAKPOINT_COMPACT
}

// is_narrow returns true when the terminal is very narrow.
is_narrow :: proc(terminal_width: int) -> bool {
	return terminal_width < BREAKPOINT_NARROW
}

// Calculate the actual number of item rows the renderer draws in the current view.
//
// Each view subtracts rows from calculate_visible_height():
//   - All list views: -1 for the divider row below the header
//   - All list views: -1 for the scroll-indicator / bottom-margin row
//     (the renderer always reserves this row at content_start + visible_height,
//      so the last visible item is at content_start + visible_height - 1)
//   - Filter active:  -1 for the filter bar row
//   - Alias/Constants: -2 for column header + its divider (col_header_offset)
//
// This must stay in sync with the visible_height calculation inside each
// render_*_view proc in the view_*.odin files so that tui_state_move_selection tracks
// exactly the same drawable rows that the renderer uses.
get_view_visible_height :: proc(state: ^TUIState) -> int {
	base := calculate_visible_height(state.terminal_height)

	#partial switch state.current_view {
	case .MAIN_MENU:
		// Menu items start at LIST_ITEM_START_LINE + 2 (divider + blank).
		// Each item takes MENU_ITEM_SPACING rows. Footer must stay clear.
		// footer_y = terminal_height - FOOTER_OFFSET_FROM_BOTTOM - 1
		menu_start_y  := LIST_ITEM_START_LINE + 2
		footer_y      := state.terminal_height - FOOTER_OFFSET_FROM_BOTTOM - 1
		available     := footer_y - 1 - menu_start_y + 1  // -1: leave one row above footer
		visible_count := available / MENU_ITEM_SPACING
		if visible_count < 1 { visible_count = 1 }
		return visible_count

	}

	// Filter bar row — render_filter_bar draws it whenever any filter
	// (text, active input, or source) is on.
	filter_offset := 1 if has_any_filter(state) else 0

	#partial switch state.current_view {
	case .ALIAS_VIEW, .CONSTANTS_VIEW:
		// column header row + its divider (only when items are visible)
		col_header_offset := 2 if view_shows_column_header(state) else 0
		// -1 divider, -1 scroll-indicator row, -filter_offset, -col_header_offset
		return base - 2 - filter_offset - col_header_offset

	case .PLUGINS_VIEW:
		// Registry tab always draws a column header + divider (2 rows).
		col_header_offset := 2 if state.plugin_tab == PLUGIN_TAB_REGISTRY else 0
		return base - 2 - filter_offset - col_header_offset

	case:
		// PATH_VIEW, COMPLETIONS_VIEW, BACKUPS_VIEW
		// -1 divider, -1 scroll-indicator row, -filter_offset
		return base - 2 - filter_offset
	}
}

// ============================================================================
// Responsive Footer Strings
// ============================================================================

// Compact footer variants for narrow terminals.
// Each returns the appropriate string based on terminal width.

get_footer_filter_active :: proc(width: int) -> string {
	if width < BREAKPOINT_NARROW {
		return "Type filter  Esc Cancel"
	}
	if width < BREAKPOINT_COMPACT {
		return "Type to filter   Esc Cancel   Enter Accept"
	}
	return FOOTER_FILTER_ACTIVE
}

get_footer_data_view :: proc(width: int) -> string {
	if width < BREAKPOINT_NARROW {
		return "/ Filter   a Add   h Back"
	}
	if width < BREAKPOINT_COMPACT {
		return "/ Filter   a Add   d Del   h Back   j/k Nav"
	}
	return FOOTER_DATA_VIEW
}

get_footer_readonly_view :: proc(width: int) -> string {
	if width < BREAKPOINT_NARROW {
		return "/ Filter   h Back"
	}
	if width < BREAKPOINT_COMPACT {
		return "/ Filter   h Back   j/k Navigate"
	}
	return FOOTER_READONLY_VIEW
}

get_footer_backup_view :: proc(width: int) -> string {
	if width < BREAKPOINT_NARROW {
		return "/ Filter   c Clean   h Back"
	}
	if width < BREAKPOINT_COMPACT {
		return "/ Filter   c Cleanup   h Back   j/k Nav"
	}
	return FOOTER_BACKUP_VIEW
}

get_footer_static_view :: proc(width: int) -> string {
	return FOOTER_STATIC_VIEW
}

get_footer_plugins_installed :: proc(width: int) -> string {
	if width < BREAKPOINT_NARROW {
		return "Tab Switch   / Filter   h Back"
	}
	if width < BREAKPOINT_COMPACT {
		return "Tab Switch   / Filter   e Ena   d Dis   h Back"
	}
	return FOOTER_PLUGINS_INSTALLED
}

get_footer_plugins_registry :: proc(width: int) -> string {
	if width < BREAKPOINT_NARROW {
		return "Tab Switch   / Filter   h Back"
	}
	if width < BREAKPOINT_COMPACT {
		return "Tab Switch   / Filter   Enter Install   h Back"
	}
	return FOOTER_PLUGINS_REGISTRY
}

get_footer_main_menu :: proc(width: int) -> string {
	if width < BREAKPOINT_NARROW {
		return "j/k Nav   l Sel   q Quit"
	}
	if width < BREAKPOINT_COMPACT {
		return "j/k Navigate   l Select   q Quit"
	}
	return "j/k Navigate   l Select   q Quit"
}
// Component types available for testing
ComponentType :: enum {
	BOX,
	LIST_ITEM,
	HEADER,
	FOOTER,
	SCROLL_INDICATOR,
	EMPTY_STATE,
}

// Arguments for component rendering
ComponentArgs :: struct {
	// Common args
	width:    int,
	height:   int,

	// Text content
	text:     string,
	title:    string,
	message:  string,

	// State
	selected: bool,

	// Numeric data
	count:    int,
	start:    int,  // For scroll indicator
	end:      int,
	total:    int,

	// Visual elements
	emoji:    string,
	shortcuts: string,  // Comma-separated "key=action" pairs
}

// Parse component type from string
parse_component_type :: proc(name: string) -> (ComponentType, bool) {
	switch name {
	case "box":
		return .BOX, true
	case "list-item", "list_item":
		return .LIST_ITEM, true
	case "header":
		return .HEADER, true
	case "footer":
		return .FOOTER, true
	case "scroll", "scroll-indicator", "scroll_indicator":
		return .SCROLL_INDICATOR, true
	case "empty", "empty-state", "empty_state":
		return .EMPTY_STATE, true
	case:
		return .BOX, false  // Default, but signal error
	}
}

// Parse component arguments from CLI
parse_component_args :: proc(args: []string) -> ComponentArgs {
	result := ComponentArgs{
		width = 80,   // Default terminal width
		height = 24,  // Default terminal height
		selected = false,
	}

	for arg in args {
		if !strings.contains(arg, "=") do continue

		parts := strings.split(arg, "=")
		defer delete(parts)

		if len(parts) != 2 do continue

		key := strings.trim_space(parts[0])
		value := strings.trim_space(parts[1])

		switch key {
		case "width":
			result.width, _ = strconv.parse_int(value)
		case "height":
			result.height, _ = strconv.parse_int(value)
		case "text":
			result.text = strings.clone(value)
		case "title":
			result.title = strings.clone(value)
		case "message":
			result.message = strings.clone(value)
		case "selected":
			result.selected = (value == "true" || value == "1")
		case "count":
			result.count, _ = strconv.parse_int(value)
		case "start":
			result.start, _ = strconv.parse_int(value)
		case "end":
			result.end, _ = strconv.parse_int(value)
		case "total":
			result.total, _ = strconv.parse_int(value)
		case "emoji":
			result.emoji = strings.clone(value)
		case "shortcuts":
			result.shortcuts = strings.clone(value)
		}
	}

	return result
}

// Free component args memory
component_args_destroy :: proc(args: ^ComponentArgs) {
	if args.text != "" do delete(args.text)
	if args.title != "" do delete(args.title)
	if args.message != "" do delete(args.message)
	if args.emoji != "" do delete(args.emoji)
	if args.shortcuts != "" do delete(args.shortcuts)
}

// Render component to plain text string (headless)
render_component :: proc(type: ComponentType, args: ComponentArgs) -> string {
	// Create headless screen buffer
	screen := screen_create(args.width, args.height)
	defer screen_destroy(&screen)

	// Clear to spaces
	screen_clear(&screen)

	// Render based on component type
	switch type {
	case .BOX:
		// Render box filling entire screen
		tui_render_box(&screen, 0, 0, args.width, args.height)

	case .LIST_ITEM:
		// Render list item with selection indicator
		prefix: string
		if args.selected {
			prefix = "> "
		} else {
			prefix = "  "
		}
		text := fmt.tprintf("%s%s", prefix, args.text)
		// Note: tprintf() uses temp buffer, do NOT delete
		render_text(&screen, 0, 0, text)

	case .HEADER:
		// Render header with emoji and title
		header_line: string
		if args.emoji != "" {
			header_line = fmt.tprintf("%s %s", args.emoji, args.title)
		} else {
			header_line = args.title
		}
		// Note: tprintf() uses temp buffer, do NOT delete
		render_text(&screen, 2, 0, header_line)

		// Render count if provided
		if args.count > 0 {
			count_line := fmt.tprintf("%d entries", args.count)
			// Note: tprintf() uses temp buffer, do NOT delete
			render_text(&screen, 2, 1, count_line)
		}

	case .FOOTER:
		// Render footer at bottom
		render_text(&screen, 2, args.height - 1, args.shortcuts)

	case .SCROLL_INDICATOR:
		// Render scroll position
		scroll_text := fmt.tprintf("Showing %d-%d of %d",
			args.start, args.end, args.total)
		// Note: tprintf() uses temp buffer, do NOT delete
		render_text(&screen, 2, 0, scroll_text)

	case .EMPTY_STATE:
		// Center message vertically and horizontally
		message := args.message
		if message == "" {
			message = "No items found"
		}
		y := args.height / 2
		x := (args.width - len(message)) / 2
		render_text(&screen, x, y, message)
	}

	// Convert to plain text
	output := screen_to_string(&screen)
	return output
}
