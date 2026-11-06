package test_wayu

// Regression tests for the buffered TUI input decoder (parse_input_event):
// multi-event reads (paste), split escape sequences, UTF-8 runes, and the
// lone-ESC timeout path.

import "core:testing"
import wayu "../../src"

// Decode every event in `input` the way poll_event does (non-final first,
// final flush when incomplete).
@(private="file")
decode_all :: proc(input: string) -> [dynamic]wayu.KeyEvent {
	events := make([dynamic]wayu.KeyEvent)
	buf := transmute([]u8)input
	for len(buf) > 0 {
		key, used, status := wayu.parse_input_event(buf, false)
		if status == .Incomplete {
			key, used, status = wayu.parse_input_event(buf, true)
		}
		if status == .Ok do append(&events, key)
		buf = buf[max(1, used):]
	}
	return events
}

@(test)
test_input_paste_yields_every_char :: proc(t: ^testing.T) {
	events := decode_all("/usr/local/bin")
	defer delete(events)
	testing.expect_value(t, len(events), 14)
	if len(events) == 14 {
		testing.expect_value(t, events[0].char, '/')
		testing.expect_value(t, events[13].char, 'n')
	}
}

@(test)
test_input_multiple_sequences_in_one_read :: proc(t: ^testing.T) {
	events := decode_all("\x1b[A\x1b[Bj\r")
	defer delete(events)
	testing.expect_value(t, len(events), 4)
	if len(events) == 4 {
		testing.expect_value(t, events[0].key, wayu.Key.Up)
		testing.expect_value(t, events[1].key, wayu.Key.Down)
		testing.expect_value(t, events[2].char, 'j')
		testing.expect_value(t, events[3].key, wayu.Key.Enter)
	}
}

@(test)
test_input_split_escape_sequence_is_incomplete :: proc(t: ^testing.T) {
	// First read delivered only "ESC [" — must wait, not emit Escape + "[".
	_, used, status := wayu.parse_input_event(transmute([]u8)string("\x1b["), false)
	testing.expect(t, status == .Incomplete, "partial CSI must be Incomplete")
	testing.expect_value(t, used, 0)

	// Lone ESC is ambiguous until the timeout fires (final=true).
	_, _, status = wayu.parse_input_event(transmute([]u8)string("\x1b"), false)
	testing.expect(t, status == .Incomplete, "lone ESC must wait for more bytes")
	key, consumed, final_status := wayu.parse_input_event(transmute([]u8)string("\x1b"), true)
	testing.expect(t, final_status == .Ok, "lone ESC at timeout is the Escape key")
	testing.expect_value(t, key.key, wayu.Key.Escape)
	testing.expect_value(t, consumed, 1)
}

@(test)
test_input_utf8_runes :: proc(t: ^testing.T) {
	events := decode_all("añ日🚀")
	defer delete(events)
	testing.expect_value(t, len(events), 4)
	if len(events) == 4 {
		testing.expect_value(t, events[1].char, 'ñ')
		testing.expect_value(t, events[2].char, '日')
		testing.expect_value(t, events[3].char, '🚀')
	}

	// Truncated multi-byte rune waits for the rest.
	_, _, status := wayu.parse_input_event([]u8{0xE6, 0x97}, false)
	testing.expect(t, status == .Incomplete, "partial UTF-8 must be Incomplete")
}

@(test)
test_input_page_keys_not_function_keys :: proc(t: ^testing.T) {
	events := decode_all("\x1b[5~\x1b[6~\x1b[15~")
	defer delete(events)
	testing.expect_value(t, len(events), 3)
	if len(events) == 3 {
		testing.expect_value(t, events[0].key, wayu.Key.PageUp)
		testing.expect_value(t, events[1].key, wayu.Key.PageDown)
		testing.expect_value(t, events[2].key, wayu.Key.F5)
	}
}

@(test)
test_input_esc_then_key_is_two_events :: proc(t: ^testing.T) {
	// "Esc, q" typed quickly lands in one read: Escape followed by 'q'.
	events := decode_all("\x1bq")
	defer delete(events)
	testing.expect_value(t, len(events), 2)
	if len(events) == 2 {
		testing.expect_value(t, events[0].key, wayu.Key.Escape)
		testing.expect_value(t, events[1].char, 'q')
	}
}

@(test)
test_input_ctrl_modified_arrow :: proc(t: ^testing.T) {
	events := decode_all("\x1b[1;5A")
	defer delete(events)
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 {
		testing.expect_value(t, events[0].key, wayu.Key.Up)
		testing.expect(t, .Ctrl in events[0].modifiers, "1;5 means Ctrl")
	}
}
