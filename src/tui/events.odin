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

    // Special keys (must check before Ctrl keys to avoid conflicts)
    switch ch {
    case 10, 13: return KeyEvent{key = .Enter}, true
    case 9:      return KeyEvent{key = .Tab}, true
    case 127, 8: return KeyEvent{key = .Backspace}, true
    }

    // Control keys (Ctrl+A = 1, Ctrl+C = 3, etc.)
    // Note: Tab (9), LF (10), CR (13) are handled above
    if ch >= 1 && ch <= 26 {
        char := rune('a' + ch - 1)
        return KeyEvent{
            key = .Char,
            char = char,
            modifiers = {.Ctrl},
        }, true
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
