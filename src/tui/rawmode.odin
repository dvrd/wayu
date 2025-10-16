package wayu_tui

import "core:c"

// Terminal raw mode management
// Copied from fuzzy.odin for terminal state management

foreign import libc_term "system:c"

STDIN_FILENO :: 0
STDOUT_FILENO :: 1
TCSANOW :: 0

// Terminal mode flags
// c_lflag (local flags)
ICANON :: 0x00000100  // Canonical input (line buffering)
ECHO   :: 0x00000008  // Echo input characters

// c_iflag (input flags)
IXON   :: 0x00000400  // Enable XON/XOFF flow control on output
IXOFF  :: 0x00001000  // Enable XON/XOFF flow control on input

termios :: struct {
	c_iflag:  c.ulong,  // tcflag_t is unsigned long on macOS
	c_oflag:  c.ulong,
	c_cflag:  c.ulong,
	c_lflag:  c.ulong,
	c_cc:     [20]c.uchar,  // NCCS=20 on macOS
	c_ispeed: c.ulong,  // speed_t is unsigned long on macOS
	c_ospeed: c.ulong,
}

foreign libc_term {
	tcgetattr :: proc(fd: c.int, termios_p: ^termios) -> c.int ---
	tcsetattr :: proc(fd: c.int, optional_actions: c.int, termios_p: ^termios) -> c.int ---
	isatty :: proc(fd: c.int) -> c.int ---
}

// Global variable to save terminal state
saved_termios: termios

// Check if file descriptor is a TTY
is_tty :: proc(fd: c.int) -> bool {
	return isatty(fd) != 0
}

// Check if stdin is a TTY
is_stdin_tty :: proc() -> bool {
	return is_tty(STDIN_FILENO)
}

// Check if stdout is a TTY
is_stdout_tty :: proc() -> bool {
	return is_tty(STDOUT_FILENO)
}

// Enable raw mode with proper terminal state saving
// Returns false if terminal control failed
enable_raw_mode :: proc() -> bool {
	// Save current terminal state
	if tcgetattr(STDIN_FILENO, &saved_termios) != 0 {
		return false
	}

	// Create raw mode settings
	raw := saved_termios
	raw.c_lflag &= ~(c.ulong(ECHO) | c.ulong(ICANON))
	// Disable XON/XOFF flow control so Ctrl+Q and Ctrl+S work
	raw.c_iflag &= ~(c.ulong(IXON) | c.ulong(IXOFF))

	if tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0 {
		return false
	}

	return true
}

// Restore terminal to saved state
disable_raw_mode :: proc() {
	tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios)
}
