package test_wayu

import "core:testing"
import "core:fmt"
import tui "../../src/tui"

// ============================================================================
// Test: Printable Characters
// ============================================================================

@(test)
test_parse_printable_char_lowercase :: proc(t: ^testing.T) {
    input_buf := []byte{'a'}
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse lowercase letter")
    testing.expect_value(t, event.key, tui.Key.Char)
    testing.expect_value(t, event.char, 'a')
    testing.expect(t, card(event.modifiers) == 0, "Should have no modifiers")
}

@(test)
test_parse_printable_char_uppercase :: proc(t: ^testing.T) {
    input_buf := []byte{'Z'}
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse uppercase letter")
    testing.expect_value(t, event.key, tui.Key.Char)
    testing.expect_value(t, event.char, 'Z')
}

@(test)
test_parse_printable_char_digit :: proc(t: ^testing.T) {
    input_buf := []byte{'5'}
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse digit")
    testing.expect_value(t, event.key, tui.Key.Char)
    testing.expect_value(t, event.char, '5')
}

@(test)
test_parse_printable_char_symbol :: proc(t: ^testing.T) {
    input_buf := []byte{'@'}
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse symbol")
    testing.expect_value(t, event.key, tui.Key.Char)
    testing.expect_value(t, event.char, '@')
}

// ============================================================================
// Test: Special Keys
// ============================================================================

@(test)
test_parse_enter_lf :: proc(t: ^testing.T) {
    input_buf := []byte{10}  // LF (Line Feed)
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse Enter (LF)")
    testing.expect_value(t, event.key, tui.Key.Enter)
}

@(test)
test_parse_enter_cr :: proc(t: ^testing.T) {
    input_buf := []byte{13}  // CR (Carriage Return)
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse Enter (CR)")
    testing.expect_value(t, event.key, tui.Key.Enter)
}

@(test)
test_parse_tab :: proc(t: ^testing.T) {
    input_buf := []byte{9}
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse Tab")
    testing.expect_value(t, event.key, tui.Key.Tab)
}

@(test)
test_parse_backspace_127 :: proc(t: ^testing.T) {
    input_buf := []byte{127}  // DEL
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse Backspace (DEL)")
    testing.expect_value(t, event.key, tui.Key.Backspace)
}

@(test)
test_parse_backspace_8 :: proc(t: ^testing.T) {
    input_buf := []byte{8}  // BS
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse Backspace (BS)")
    testing.expect_value(t, event.key, tui.Key.Backspace)
}

@(test)
test_parse_escape :: proc(t: ^testing.T) {
    input_buf := []byte{27}  // ESC alone
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse Escape")
    testing.expect_value(t, event.key, tui.Key.Escape)
}

// ============================================================================
// Test: Arrow Keys
// ============================================================================

@(test)
test_parse_arrow_up :: proc(t: ^testing.T) {
    input_buf := []byte{27, '[', 'A'}  // ESC [ A
    event, ok := tui.parse_key_event(input_buf, 3)

    testing.expect(t, ok, "Should parse Up arrow")
    testing.expect_value(t, event.key, tui.Key.Up)
}

@(test)
test_parse_arrow_down :: proc(t: ^testing.T) {
    input_buf := []byte{27, '[', 'B'}  // ESC [ B
    event, ok := tui.parse_key_event(input_buf, 3)

    testing.expect(t, ok, "Should parse Down arrow")
    testing.expect_value(t, event.key, tui.Key.Down)
}

@(test)
test_parse_arrow_right :: proc(t: ^testing.T) {
    input_buf := []byte{27, '[', 'C'}  // ESC [ C
    event, ok := tui.parse_key_event(input_buf, 3)

    testing.expect(t, ok, "Should parse Right arrow")
    testing.expect_value(t, event.key, tui.Key.Right)
}

@(test)
test_parse_arrow_left :: proc(t: ^testing.T) {
    input_buf := []byte{27, '[', 'D'}  // ESC [ D
    event, ok := tui.parse_key_event(input_buf, 3)

    testing.expect(t, ok, "Should parse Left arrow")
    testing.expect_value(t, event.key, tui.Key.Left)
}

@(test)
test_parse_home :: proc(t: ^testing.T) {
    input_buf := []byte{27, '[', 'H'}  // ESC [ H
    event, ok := tui.parse_key_event(input_buf, 3)

    testing.expect(t, ok, "Should parse Home")
    testing.expect_value(t, event.key, tui.Key.Home)
}

@(test)
test_parse_end :: proc(t: ^testing.T) {
    input_buf := []byte{27, '[', 'F'}  // ESC [ F
    event, ok := tui.parse_key_event(input_buf, 3)

    testing.expect(t, ok, "Should parse End")
    testing.expect_value(t, event.key, tui.Key.End)
}

// ============================================================================
// Test: Ctrl Keys
// ============================================================================

@(test)
test_parse_ctrl_a :: proc(t: ^testing.T) {
    input_buf := []byte{1}  // Ctrl+A
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse Ctrl+A")
    testing.expect_value(t, event.key, tui.Key.Char)
    testing.expect_value(t, event.char, 'a')
    testing.expect(t, .Ctrl in event.modifiers, "Should have Ctrl modifier")
}

@(test)
test_parse_ctrl_c :: proc(t: ^testing.T) {
    input_buf := []byte{3}  // Ctrl+C
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse Ctrl+C")
    testing.expect_value(t, event.key, tui.Key.Char)
    testing.expect_value(t, event.char, 'c')
    testing.expect(t, .Ctrl in event.modifiers, "Should have Ctrl modifier")
}

@(test)
test_parse_ctrl_n :: proc(t: ^testing.T) {
    input_buf := []byte{14}  // Ctrl+N
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse Ctrl+N")
    testing.expect_value(t, event.key, tui.Key.Char)
    testing.expect_value(t, event.char, 'n')
    testing.expect(t, .Ctrl in event.modifiers, "Should have Ctrl modifier")
}

@(test)
test_parse_ctrl_z :: proc(t: ^testing.T) {
    input_buf := []byte{26}  // Ctrl+Z
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse Ctrl+Z")
    testing.expect_value(t, event.key, tui.Key.Char)
    testing.expect_value(t, event.char, 'z')
    testing.expect(t, .Ctrl in event.modifiers, "Should have Ctrl modifier")
}

// ============================================================================
// Test: Function Keys
// ============================================================================

@(test)
test_parse_f1 :: proc(t: ^testing.T) {
    input_buf := []byte{27, 'O', 'P'}  // ESC O P
    event, ok := tui.parse_key_event(input_buf, 3)

    testing.expect(t, ok, "Should parse F1")
    testing.expect_value(t, event.key, tui.Key.F1)
}

@(test)
test_parse_f2 :: proc(t: ^testing.T) {
    input_buf := []byte{27, 'O', 'Q'}  // ESC O Q
    event, ok := tui.parse_key_event(input_buf, 3)

    testing.expect(t, ok, "Should parse F2")
    testing.expect_value(t, event.key, tui.Key.F2)
}

@(test)
test_parse_f3 :: proc(t: ^testing.T) {
    input_buf := []byte{27, 'O', 'R'}  // ESC O R
    event, ok := tui.parse_key_event(input_buf, 3)

    testing.expect(t, ok, "Should parse F3")
    testing.expect_value(t, event.key, tui.Key.F3)
}

@(test)
test_parse_f4 :: proc(t: ^testing.T) {
    input_buf := []byte{27, 'O', 'S'}  // ESC O S
    event, ok := tui.parse_key_event(input_buf, 3)

    testing.expect(t, ok, "Should parse F4")
    testing.expect_value(t, event.key, tui.Key.F4)
}

@(test)
test_parse_f5 :: proc(t: ^testing.T) {
    input_buf := []byte{27, '[', '5', '~'}  // ESC [ 5 ~
    event, ok := tui.parse_key_event(input_buf, 4)

    testing.expect(t, ok, "Should parse F5")
    testing.expect_value(t, event.key, tui.Key.F5)
}

@(test)
test_parse_f6 :: proc(t: ^testing.T) {
    input_buf := []byte{27, '[', '7', '~'}  // ESC [ 7 ~
    event, ok := tui.parse_key_event(input_buf, 4)

    testing.expect(t, ok, "Should parse F6")
    testing.expect_value(t, event.key, tui.Key.F6)
}

@(test)
test_parse_f7 :: proc(t: ^testing.T) {
    input_buf := []byte{27, '[', '8', '~'}  // ESC [ 8 ~
    event, ok := tui.parse_key_event(input_buf, 4)

    testing.expect(t, ok, "Should parse F7")
    testing.expect_value(t, event.key, tui.Key.F7)
}

@(test)
test_parse_f8 :: proc(t: ^testing.T) {
    input_buf := []byte{27, '[', '9', '~'}  // ESC [ 9 ~
    event, ok := tui.parse_key_event(input_buf, 4)

    testing.expect(t, ok, "Should parse F8")
    testing.expect_value(t, event.key, tui.Key.F8)
}

// ============================================================================
// Test: Edge Cases and Error Handling
// ============================================================================

@(test)
test_parse_empty_buffer :: proc(t: ^testing.T) {
    input_buf := []byte{}
    event, ok := tui.parse_key_event(input_buf, 0)

    testing.expect(t, !ok, "Should not parse empty buffer")
}

@(test)
test_parse_invalid_escape_sequence :: proc(t: ^testing.T) {
    input_buf := []byte{27, '[', 'X'}  // Invalid sequence
    event, ok := tui.parse_key_event(input_buf, 3)

    testing.expect(t, !ok, "Should not parse invalid escape sequence")
}

@(test)
test_parse_incomplete_escape_sequence :: proc(t: ^testing.T) {
    input_buf := []byte{27, '['}  // Incomplete
    event, ok := tui.parse_key_event(input_buf, 2)

    testing.expect(t, !ok, "Should not parse incomplete escape sequence")
}

@(test)
test_parse_non_printable_char :: proc(t: ^testing.T) {
    input_buf := []byte{0}  // NULL
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, !ok, "Should not parse non-printable character")
}

@(test)
test_parse_high_byte :: proc(t: ^testing.T) {
    input_buf := []byte{200}  // Above ASCII range
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, !ok, "Should not parse high byte value")
}

// ============================================================================
// Test: Key Event Structure
// ============================================================================

@(test)
test_key_event_modifiers_empty :: proc(t: ^testing.T) {
    input_buf := []byte{'a'}
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse")
    testing.expect(t, card(event.modifiers) == 0, "Should have empty modifiers")
    testing.expect(t, .Ctrl not_in event.modifiers, "Should not have Ctrl")
    testing.expect(t, .Shift not_in event.modifiers, "Should not have Shift")
    testing.expect(t, .Alt not_in event.modifiers, "Should not have Alt")
}

@(test)
test_key_event_modifiers_ctrl :: proc(t: ^testing.T) {
    input_buf := []byte{1}  // Ctrl+A
    event, ok := tui.parse_key_event(input_buf, 1)

    testing.expect(t, ok, "Should parse")
    testing.expect(t, .Ctrl in event.modifiers, "Should have Ctrl modifier")
    testing.expect(t, card(event.modifiers) == 1, "Should have exactly one modifier")
}

// ============================================================================
// Test: Key Enum Values
// ============================================================================

@(test)
test_key_enum_distinct :: proc(t: ^testing.T) {
    // Verify that key enum values are distinct
    testing.expect(t, tui.Key.Char != tui.Key.Enter, "Char != Enter")
    testing.expect(t, tui.Key.Up != tui.Key.Down, "Up != Down")
    testing.expect(t, tui.Key.F1 != tui.Key.F2, "F1 != F2")
}

// ============================================================================
// Test: Event Union Type
// ============================================================================

@(test)
test_event_union_key_event :: proc(t: ^testing.T) {
    key_event := tui.KeyEvent{key = .Enter}
    event: tui.Event = key_event

    switch e in event {
    case tui.KeyEvent:
        testing.expect_value(t, e.key, tui.Key.Enter)
    case tui.MouseEvent:
        testing.expect(t, false, "Should not be MouseEvent")
    case tui.ResizeEvent:
        testing.expect(t, false, "Should not be ResizeEvent")
    }
}

@(test)
test_event_union_mouse_event :: proc(t: ^testing.T) {
    mouse_event := tui.MouseEvent{x = 10, y = 20, button = 1}
    event: tui.Event = mouse_event

    switch e in event {
    case tui.MouseEvent:
        testing.expect_value(t, e.x, 10)
        testing.expect_value(t, e.y, 20)
        testing.expect_value(t, e.button, 1)
    case tui.KeyEvent:
        testing.expect(t, false, "Should not be KeyEvent")
    case tui.ResizeEvent:
        testing.expect(t, false, "Should not be ResizeEvent")
    }
}

@(test)
test_event_union_resize_event :: proc(t: ^testing.T) {
    resize_event := tui.ResizeEvent{width = 80, height = 24}
    event: tui.Event = resize_event

    switch e in event {
    case tui.ResizeEvent:
        testing.expect_value(t, e.width, 80)
        testing.expect_value(t, e.height, 24)
    case tui.KeyEvent:
        testing.expect(t, false, "Should not be KeyEvent")
    case tui.MouseEvent:
        testing.expect(t, false, "Should not be MouseEvent")
    }
}
