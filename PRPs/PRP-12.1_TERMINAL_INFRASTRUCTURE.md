name: "PRP-12.1: Terminal Infrastructure - Size Detection, Signals, Alt Screen"
description: |
  Implement terminal control foundation: dynamic size detection via ioctl, SIGWINCH signal
  handling for resize events, and alternate screen buffer management.

version: "1.0.0"
parent: "PRP-12_FULL_TUI_MODE_BASE.md"
phase: "1 of 7"
status: "READY_FOR_EXECUTION"

---

## Goal

**Feature Goal**: Implement POSIX terminal control functions for TUI: terminal size detection, resize signal handling, and alternate screen buffer lifecycle.

**Deliverable**:
- `src/tui/tui_terminal.odin` with get_terminal_size(), setup_resize_handler(), enter/exit_alt_screen()
- `tests/unit/test_tui_terminal.odin` with unit tests
- Compiles without errors, all tests pass

**Success Definition**:
- Terminal size detection works on macOS and Linux
- SIGWINCH handler registers without crashing
- Alternate screen buffer can be entered/exited cleanly
- Unit tests pass: `odin test tests/unit/test_tui_terminal.odin -file`

---

## Why

- **Foundation**: All TUI rendering depends on knowing terminal dimensions
- **Responsiveness**: Users resize terminals frequently - must handle gracefully
- **Professional UX**: Alternate screen buffer preserves terminal history
- **Platform Support**: Works on macOS and Linux via POSIX APIs

---

## What

### Implementation Tasks

```yaml
Task 1: CREATE src/tui/tui_terminal.odin
  Components:
    - get_terminal_size() using ioctl(TIOCGWINSZ)
    - setup_resize_handler() for SIGWINCH signal
    - enter_alt_screen() with ANSI codes
    - exit_alt_screen() with ANSI codes
    - tui_lifecycle_init() and tui_lifecycle_cleanup()

  Platform handling:
    - macOS: TIOCGWINSZ = 0x40087468
    - Linux: TIOCGWINSZ = 0x5413
    - Use `when ODIN_OS` for platform detection

  Critical:
    - Signal handler MUST use "c" calling convention
    - Always defer cleanup functions
    - Fallback to 80x24 if ioctl fails

Task 2: CREATE tests/unit/test_tui_terminal.odin
  Tests:
    - test_terminal_size_detection: Returns positive width/height
    - test_alt_screen_buffer: Can enter/exit without crash
    - test_signal_handler: setup_resize_handler() doesn't crash
```

### Success Criteria

- [ ] get_terminal_size() returns positive dimensions
- [ ] SIGWINCH handler registers successfully
- [ ] Alternate screen enter/exit works (manual verification)
- [ ] All unit tests pass
- [ ] Compiles with `odin build src/tui -out:bin/tui_test`

---

## All Needed Context

### Documentation References

```yaml
- file: /Users/kakurega/dev/projects/wayu/src/fuzzy.odin
  lines: 15-79
  why: termios structure definition, raw mode pattern
  pattern: Platform-specific termios struct for macOS

- url: https://pkg.odin-lang.org/core/sys/posix/
  why: ioctl, sigaction definitions
  critical: Must use posix.ioctl and posix.sigaction

- url: https://github.com/odin-lang/examples/tree/master/console/raw_console
  why: Official example of terminal control
  pattern: Proper cleanup with defer
```

### Known Gotchas

```odin
// CRITICAL: macOS vs Linux differences
when ODIN_OS == .Darwin {
    TIOCGWINSZ :: 0x40087468
} else when ODIN_OS == .Linux {
    TIOCGWINSZ :: 0x5413
}

// CRITICAL: Signal handlers need "c" convention
terminal_resized: bool  // Global flag

sigwinch_handler :: proc "c" (sig: i32) {
    terminal_resized = true  // Cannot use allocator here
}

// CRITICAL: Always defer cleanup
defer {
    fmt.print(EXIT_ALT_SCREEN)
    fmt.print(SHOW_CURSOR)
}
```

---

## Implementation Blueprint

### Complete Code Pattern

```odin
package wayu_tui

import "core:fmt"
import "core:c"

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
}

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
sigwinch_handler :: proc "c" (sig: i32) {
    terminal_resized = true
}

// Setup resize signal handler
setup_resize_handler :: proc() {
    import "core:sys/posix"

    act := posix.sigaction{
        sa_handler = sigwinch_handler,
        sa_flags = {.RESTART},
    }
    posix.sigaction(.SIGWINCH, &act, nil)
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
```

---

## Validation Loop

### Level 1: Compilation

```bash
# Compile TUI package
odin build src/tui -out:bin/tui_test -debug
# Expected: Zero errors
```

### Level 2: Unit Tests

```bash
# Run terminal tests
odin test tests/unit/test_tui_terminal.odin -file
# Expected: All tests pass
```

### Level 3: Manual Verification

```bash
# Create test program
cat > test_terminal.odin <<'EOF'
package main

import "tui"
import "core:fmt"

main :: proc() {
    width, height, ok := tui.get_terminal_size()
    fmt.printf("Terminal: %dx%d, ok=%v\n", width, height, ok)

    tui.tui_lifecycle_init()
    defer tui.tui_lifecycle_cleanup()

    fmt.println("Press Enter to exit...")
    buf: [1]byte
    os.read(os.stdin, buf[:])
}
EOF

odin run test_terminal.odin -file
# Expected: Shows terminal size, alternate screen works
```

---

## Final Validation Checklist

- [ ] Compiles without errors
- [ ] Unit tests pass
- [ ] get_terminal_size() returns reasonable values (e.g., 80x24 or larger)
- [ ] Alternate screen buffer enters/exits cleanly (verified manually)
- [ ] SIGWINCH handler registers without crash
- [ ] Works on macOS (tested platform)
- [ ] No memory leaks (check with defer patterns)

---

**Status**: ✅ READY FOR EXECUTION
**Estimated Time**: 1-2 hours
**Dependencies**: None
**Confidence**: 10/10
