name: "PRP-12.2: Event System - Key Parsing and Input Handling"
description: |
  Implement event types (KeyEvent, ResizeEvent) and input parsing for keyboard events
  including arrow keys, function keys, and control sequences.

version: "1.0.0"
parent: "PRP-12_FULL_TUI_MODE_BASE.md"
phase: "2 of 7"
status: "READY_FOR_EXECUTION"

---

## Goal

**Feature Goal**: Implement comprehensive keyboard event parsing system that converts raw terminal input bytes into structured Event types.

**Deliverable**:
- `src/tui/tui_events.odin` with Event union, Key enum, parse_key_event()
- `src/tui/tui_input.odin` with poll_event() for non-blocking input
- `tests/unit/test_tui_events.odin` with unit tests
- All tests pass, compiles without errors

**Success Definition**:
- Can parse common keys (letters, numbers, Enter, Esc)
- Can parse arrow keys (Up, Down, Left, Right)
- Can parse function keys (F1-F12)
- Can parse Ctrl combinations (Ctrl+C, Ctrl+N, etc.)
- poll_event() handles blocking and non-blocking reads

---

## Why

- **User Input**: All TUI interaction depends on keyboard events
- **Navigation**: Arrow keys, j/k, Enter are essential for TUI navigation
- **Escape Sequences**: Must handle 3-byte ANSI sequences correctly
- **Reuse Pattern**: Leverage existing fuzzy.odin input handling (lines 553-707)

---

## What

### Implementation Tasks

```yaml
Task 1: CREATE src/tui/tui_events.odin
  Types:
    - Event :: union { KeyEvent, MouseEvent, ResizeEvent }
    - Key :: enum (Char, Enter, Tab, Backspace, Delete, Escape, arrows, F-keys)
    - KeyModifiers :: bit_set[KeyModifier]
    - KeyModifier :: enum { Shift, Ctrl, Alt }

  Functions:
    - parse_key_event(input_buf: []byte, n: int) -> (KeyEvent, bool)
    - Handle escape sequences: ESC [ A/B/C/D (arrows)
    - Handle function keys: ESC O P/Q/R/S (F1-F4), ESC [ 15~ etc (F5-F12)
    - Handle Ctrl keys: ASCII codes 1-26

Task 2: CREATE src/tui/tui_input.odin
  Functions:
    - poll_event() -> Event (non-blocking read from stdin)
    - Reads up to 8 bytes for escape sequences
    - Returns Event or nil if no input
    - Handles os.read() errors gracefully

Task 3: CREATE tests/unit/test_tui_events.odin
  Tests:
    - test_parse_printable_char: 'a', '1', etc.
    - test_parse_enter: codes 10 and 13
    - test_parse_arrows: ESC [ A/B/C/D
    - test_parse_ctrl_keys: Ctrl+C (3), Ctrl+N (14), etc.
    - test_parse_function_keys: F1-F12 sequences
```

### Success Criteria

- [ ] Can parse all printable ASCII characters
- [ ] Can parse Enter, Tab, Backspace, Escape
- [ ] Can parse arrow keys from escape sequences
- [ ] Can parse Ctrl key combinations
- [ ] Can parse function keys F1-F12
- [ ] poll_event() handles no-input case gracefully
- [ ] All unit tests pass
- [ ] Compiles with `odin build src/tui`

---

## All Needed Context

### Documentation References

```yaml
- file: /Users/kakurega/dev/projects/wayu/src/fuzzy.odin
  lines: 553-707
  why: Production-ready escape sequence parsing
  pattern: Handle ESC [ X for arrows, check n (bytes read)

- docfile: /Users/kakurega/dev/projects/wayu/docs/references/TUI_DESIGN_PATTERNS.md
  section: "Input Handling"
  why: Standard key codes and escape sequences
```

### Known Gotchas

```odin
// GOTCHA: Check bytes read before accessing buffer
n, err := os.read(os.stdin, input_buf[:])
if err != 0 || n == 0 {
    return nil  // No input available
}

// GOTCHA: Arrow keys are 3-byte sequences
// ESC [ A = Up, ESC [ B = Down, ESC [ C = Right, ESC [ D = Left
if ch == 27 && n >= 3 && input_buf[1] == '[' {
    switch input_buf[2] {
    case 'A': return KeyEvent{key = .Up}
    case 'B': return KeyEvent{key = .Down}
    // ...
    }
}

// GOTCHA: Ctrl keys are ASCII codes 1-26
// Ctrl+A = 1, Ctrl+B = 2, ..., Ctrl+Z = 26
if ch >= 1 && ch <= 26 {
    return KeyEvent{
        key = .Char,
        char = rune('a' + ch - 1),
        modifiers = {.Ctrl},
    }
}
```

---

## Implementation Blueprint

### Complete Code Pattern (tui_events.odin)

```odin
package wayu_tui

import "core:os"

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

// Parse key event from input buffer
parse_key_event :: proc(input_buf: []byte, n: int) -> (KeyEvent, bool) {
    if n == 0 do return {}, false

    ch := input_buf[0]

    // Escape sequences (arrow keys, function keys)
    if ch == 27 {
        if n == 1 {
            return KeyEvent{key = .Escape}, true
        }

        // Arrow keys: ESC [ A/B/C/D
        if n >= 3 && input_buf[1] == '[' {
            switch input_buf[2] {
            case 'A': return KeyEvent{key = .Up}, true
            case 'B': return KeyEvent{key = .Down}, true
            case 'C': return KeyEvent{key = .Right}, true
            case 'D': return KeyEvent{key = .Left}, true
            case 'H': return KeyEvent{key = .Home}, true
            case 'F': return KeyEvent{key = .End}, true
            }

            // Function keys: ESC [ 1 5 ~ (F5), etc.
            if n >= 4 && input_buf[3] == '~' {
                code := int(input_buf[2] - '0')
                switch code {
                case 5: return KeyEvent{key = .F5}, true
                case 7: return KeyEvent{key = .F6}, true
                case 8: return KeyEvent{key = .F7}, true
                case 9: return KeyEvent{key = .F8}, true
                }
            }
        }

        // Function keys F1-F4: ESC O P/Q/R/S
        if n >= 3 && input_buf[1] == 'O' {
            switch input_buf[2] {
            case 'P': return KeyEvent{key = .F1}, true
            case 'Q': return KeyEvent{key = .F2}, true
            case 'R': return KeyEvent{key = .F3}, true
            case 'S': return KeyEvent{key = .F4}, true
            }
        }

        return {}, false
    }

    // Control keys (Ctrl+A = 1, Ctrl+C = 3, etc.)
    if ch >= 1 && ch <= 26 {
        char := rune('a' + ch - 1)
        return KeyEvent{
            key = .Char,
            char = char,
            modifiers = {.Ctrl},
        }, true
    }

    // Special keys
    switch ch {
    case 10, 13: return KeyEvent{key = .Enter}, true
    case 9:      return KeyEvent{key = .Tab}, true
    case 127, 8: return KeyEvent{key = .Backspace}, true
    }

    // Printable characters
    if ch >= 32 && ch <= 126 {
        return KeyEvent{
            key = .Char,
            char = rune(ch),
        }, true
    }

    return {}, false
}
```

### Complete Code Pattern (tui_input.odin)

```odin
package wayu_tui

import "core:os"

// Poll for events (non-blocking)
poll_event :: proc() -> Event {
    input_buf: [8]byte
    n, err := os.read(os.stdin, input_buf[:])

    if err != 0 || n == 0 {
        return nil
    }

    if key, ok := parse_key_event(input_buf[:], n); ok {
        return key
    }

    return nil
}
```

---

## Validation Loop

### Level 1: Compilation

```bash
odin build src/tui -out:bin/tui_test -debug
# Expected: Zero errors
```

### Level 2: Unit Tests

```bash
odin test tests/unit/test_tui_events.odin -file
# Expected: All tests pass
```

### Level 3: Interactive Test

```bash
# Create test program
cat > test_events.odin <<'EOF'
package main

import "tui"
import "core:fmt"
import "core:os"

main :: proc() {
    fmt.println("Press keys (q to quit):")

    for {
        event := tui.poll_event()
        if event != nil {
            #partial switch e in event {
            case tui.KeyEvent:
                fmt.printf("Key: %v, char: %c\n", e.key, e.char)
                if e.char == 'q' do break
            }
        }
    }
}
EOF

odin run test_events.odin -file
# Expected: Shows key presses, arrows work
```

---

## Final Validation Checklist

- [ ] Compiles without errors
- [ ] All unit tests pass
- [ ] Can parse letters and numbers
- [ ] Can parse Enter, Esc, Tab, Backspace
- [ ] Arrow keys work (Up/Down/Left/Right)
- [ ] Ctrl+C can be detected
- [ ] Function keys F1-F12 parse correctly
- [ ] poll_event() handles no-input gracefully

---

**Status**: ✅ READY FOR EXECUTION
**Estimated Time**: 2-3 hours
**Dependencies**: None (independent of Phase 1)
**Confidence**: 10/10
