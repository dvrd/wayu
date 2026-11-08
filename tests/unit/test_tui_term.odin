package test_wayu

// TUI terminal layer: input decoding (Alt chords, OSC replies, bracketed
// paste), rune widths, theme/palette mapping, and the restore paths that
// must leave the user's terminal usable (wayu_exit, fatal signals) with
// captured stderr replayed afterwards.

import "core:c"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import wayu "../../src"

// ---------------------------------------------------------------------------
// Input decoding (OKAMI-257, OKAMI-253)
// ---------------------------------------------------------------------------

@(test)
test_decode_alt_chords :: proc(t: ^testing.T) {
	k, n, st := wayu.parse_input_event(transmute([]u8)string("\x1bd"), false)
	testing.expect_value(t, st, wayu.ParseStatus.Ok)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, k.key, wayu.Key.Char)
	testing.expect_value(t, k.char, 'd')
	testing.expect(t, .Alt in k.modifiers, "ESC d must be Alt+d")

	k, n, st = wayu.parse_input_event(transmute([]u8)string("\x1b\x7f"), false)
	testing.expect(t, st == .Ok && k.key == .Backspace && .Alt in k.modifiers, "ESC DEL = Alt+Backspace")

	k, n, st = wayu.parse_input_event(transmute([]u8)string("\x1b\x01"), false)
	testing.expect(t, st == .Ok && k.char == 'a' && k.modifiers == {.Alt, .Ctrl}, "ESC ^A = Ctrl+Alt+a")

	k, n, st = wayu.parse_input_event(transmute([]u8)string("\x1bé"), false)
	testing.expect(t, st == .Ok && k.char == 'é' && .Alt in k.modifiers && n == 3, "ESC + UTF-8 rune = Alt+rune")
}

@(test)
test_decode_lone_escape_waits_for_more :: proc(t: ^testing.T) {
	// Not final: the next bytes may complete a sequence (slow link).
	_, _, st := wayu.parse_input_event(transmute([]u8)string("\x1b"), false)
	testing.expect_value(t, st, wayu.ParseStatus.Incomplete)
	k, n, st2 := wayu.parse_input_event(transmute([]u8)string("\x1b"), true)
	testing.expect(t, st2 == .Ok && k.key == .Escape && n == 1, "final lone ESC = Escape")
	// ESC then "[B" (completed later) is still Down.
	k, n, st = wayu.parse_input_event(transmute([]u8)string("\x1b[B"), false)
	testing.expect(t, st == .Ok && k.key == .Down && n == 3, "ESC [ B = Down")
	// ESC ESC: the first is a plain Escape.
	k, n, st = wayu.parse_input_event(transmute([]u8)string("\x1b\x1b[B"), false)
	testing.expect(t, st == .Ok && k.key == .Escape && n == 1 && k.modifiers == {}, "ESC ESC = Escape")
}

@(test)
test_decode_swallows_osc_replies :: proc(t: ^testing.T) {
	reply := "\x1b]11;rgb:ffff/ffff/ffff\x1b\\j"
	_, n, st := wayu.parse_input_event(transmute([]u8)reply, false)
	testing.expect_value(t, st, wayu.ParseStatus.Invalid)
	testing.expect_value(t, n, len(reply) - 1)  // the trailing `j` is a key
	_, n, st = wayu.parse_input_event(transmute([]u8)string("\x1b]11;rgb:0/0/0\x07"), false)
	testing.expect(t, st == .Invalid && n == 15, "BEL-terminated OSC swallowed")
	_, _, st = wayu.parse_input_event(transmute([]u8)string("\x1b]11;rgb:ff"), false)
	testing.expect_value(t, st, wayu.ParseStatus.Incomplete)
	// A cursor position reply is ignored, not a key.
	_, n, st = wayu.parse_input_event(transmute([]u8)string("\x1b[24;80R"), false)
	testing.expect(t, st == .Invalid && n == 8, "DSR reply ignored")
}

@(test)
test_scan_paste_chunk :: proc(t: ^testing.T) {
	body, n, done := wayu.scan_paste_chunk(transmute([]u8)string("a\rb\x1b[201~dy"))
	testing.expect_value(t, string(body), "a\rb")
	testing.expect_value(t, n, 9)
	testing.expect(t, done, "end marker found")

	// A trailing partial end marker is held back for the next read.
	body, n, done = wayu.scan_paste_chunk(transmute([]u8)string("abc\x1b[20"))
	testing.expect(t, !done && string(body) == "abc" && n == 3, "partial marker kept")

	body, n, done = wayu.scan_paste_chunk(transmute([]u8)string("x\x1b[A"))
	testing.expect(t, !done && string(body) == "x\x1b[A" && n == 4, "other sequences are paste text")
}

// ---------------------------------------------------------------------------
// Rune widths (OKAMI-258)
// ---------------------------------------------------------------------------

@(test)
test_rune_widths_match_terminals :: proc(t: ^testing.T) {
	Case :: struct { r: rune, w: int }
	cases := []Case{
		{'a', 1}, {'é', 1}, {0x0301, 0}, {0xFE0F, 0}, {0x200D, 0}, {0x200B, 0},
		{'➜', 1}, {'✔', 1}, {'★', 1}, {'❤', 1}, {'⚠', 1}, {'✓', 1}, {'⛰', 1},
		{'✨', 2}, {'✅', 2}, {'🚀', 2}, {'👨', 2}, {'日', 2}, {'│', 1}, {0x7F, 0},
	}
	for tc in cases {
		testing.expectf(t, wayu.get_rune_width(tc.r) == tc.w, "width(U+%04X) = %d, want %d",
			tc.r, wayu.get_rune_width(tc.r), tc.w)
	}
	testing.expect_value(t, wayu.visual_width("café"), 4)
	testing.expect_value(t, wayu.visual_width("❤️"), 1)
	testing.expect_value(t, wayu.visual_width("👨‍👩‍👧"), 6)
}

@(test)
test_render_combining_and_selectors :: proc(t: ^testing.T) {
	screen := wayu.screen_create(8, 1)
	defer wayu.screen_destroy(&screen)
	wayu.render_text(&screen, 0, 0, "café!")
	testing.expect_value(t, screen.buffer[0][3].char, 'e')
	testing.expect_value(t, screen.buffer[0][3].comb, rune(0x0301))
	testing.expect_value(t, screen.buffer[0][4].char, '!')  // the mark took no column

	wayu.screen_clear(&screen)
	wayu.render_text(&screen, 0, 0, "❤️x👨‍👩")
	testing.expect_value(t, screen.buffer[0][0].char, '❤')
	testing.expect_value(t, screen.buffer[0][0].comb, rune(0))  // VS16 dropped
	testing.expect_value(t, screen.buffer[0][1].char, 'x')
	testing.expect_value(t, screen.buffer[0][2].char, '👨')
	testing.expect_value(t, screen.buffer[0][3].char, wayu.CELL_CONTINUATION)
	testing.expect_value(t, screen.buffer[0][4].char, '👩')  // ZWJ dropped
	testing.expect_value(t, screen.buffer[0][2].comb, rune(0))

	out := wayu.screen_to_string(&screen)
	defer delete(out)
	testing.expect_value(t, out, "❤x👨👩  ")
}

// ---------------------------------------------------------------------------
// Theme + palette (OKAMI-263)
// ---------------------------------------------------------------------------

@(test)
test_theme_detection_parsers :: proc(t: ^testing.T) {
	th, ok := wayu.theme_from_colorfgbg("15;0")
	testing.expect(t, ok && th == .Dark, "15;0 = dark")
	th, ok = wayu.theme_from_colorfgbg("0;15")
	testing.expect(t, ok && th == .Light, "0;15 = light")
	th, ok = wayu.theme_from_colorfgbg("0;default;7")
	testing.expect(t, ok && th == .Light, "0;default;7 = light")
	_, ok = wayu.theme_from_colorfgbg("garbage")
	testing.expect(t, !ok, "unparseable COLORFGBG ignored")

	r, g, b, rgb_ok := wayu.parse_osc11_reply("x\x1b]11;rgb:ffff/ffff/ffff\x1b\\")
	testing.expect(t, rgb_ok && wayu.theme_from_rgb(r, g, b) == .Light, "white = light")
	r, g, b, rgb_ok = wayu.parse_osc11_reply("\x1b]11;rgb:1e/1e/2e\x07")
	testing.expect(t, rgb_ok && wayu.theme_from_rgb(r, g, b) == .Dark, "#1e1e2e = dark")
	_, _, _, rgb_ok = wayu.parse_osc11_reply("\x1b]11;rgb:ffff/ffff\x07")
	testing.expect(t, !rgb_ok, "two components rejected")
}

@(test)
test_palette_mapping :: proc(t: ^testing.T) {
	// Normal text uses the terminal's default foreground in every theme.
	testing.expect_value(t, wayu.theme_color_for(wayu.TUI_MUTED, .Dark, .TRUECOLOR), "")
	testing.expect_value(t, wayu.theme_color_for(wayu.TUI_MUTED, .Light, .ANSI256), "")
	// Light theme: dividers become a light gray, not #333.
	testing.expect(t, wayu.theme_color_for(wayu.TUI_DIVIDER, .Light, .TRUECOLOR) != wayu.TUI_DIVIDER, "light divider")
	testing.expect_value(t, wayu.theme_color_for(wayu.TUI_DIVIDER, .Dark, .TRUECOLOR), wayu.TUI_DIVIDER)
	// 16 colors: distinct accent and error, gray (not black) dividers.
	primary, _ := wayu.palette_ansi16(wayu.TUI_PRIMARY, .Dark)
	err, _ := wayu.palette_ansi16(wayu.TUI_ERROR, .Dark)
	divider, _ := wayu.palette_ansi16(wayu.TUI_DIVIDER, .Dark)
	testing.expect(t, primary != err, "pink and red must differ in 16 colors")
	testing.expect_value(t, divider, 8)
}

// ---------------------------------------------------------------------------
// Restore paths (OKAMI-251, OKAMI-262) — run in a forked child whose
// stdout/stderr are a pipe, so the test process' own fds are untouched.
// ---------------------------------------------------------------------------

Child_Result :: struct {
	output: string,  // stdout + stderr, in order
	status: c.int,
}

// Fork; the child runs `body` with fds 1 and 2 on a pipe and must exit.
@(private = "file")
run_in_child :: proc(body: proc()) -> Child_Result {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK do return {}
	pid := posix.fork()
	if pid == 0 {
		posix.close(fds[0])
		posix.dup2(fds[1], 1)
		posix.dup2(fds[1], 2)
		posix.close(fds[1])
		body()
		posix._exit(99)  // body must not return
	}
	posix.close(fds[1])
	b := strings.builder_make(context.temp_allocator)
	buf: [1024]u8
	for {
		n := posix.read(fds[0], raw_data(buf[:]), len(buf))
		if n <= 0 do break
		strings.write_bytes(&b, buf[:n])
	}
	posix.close(fds[0])
	status: c.int
	posix.waitpid(pid, &status, {})
	return {output = strings.to_string(b), status = status}
}

@(test)
test_wayu_exit_restores_terminal_and_replays_stderr :: proc(t: ^testing.T) {
	res := run_in_child(proc() {
		wayu.tui_set_screen_active(true)
		if !wayu.tui_stderr_capture_begin() do posix._exit(90)
		msg := "ERROR: cannot read wayu.toml\n"
		posix.write(2, raw_data(msg), len(msg))
		wayu.wayu_exit(66)
	})
	testing.expectf(t, posix.WIFEXITED(res.status) && posix.WEXITSTATUS(res.status) == 66,
		"child status %d, output %q", res.status, res.output)
	leave := strings.index(res.output, "\x1b[?1049l")
	msg := strings.index(res.output, "ERROR: cannot read wayu.toml")
	testing.expectf(t, leave >= 0 && msg > leave,
		"message must follow the restore sequence (leave %d, msg %d): %q", leave, msg, res.output)
	testing.expect(t, strings.contains(res.output, "\x1b[?2004l\x1b[?25h"), "paste off + cursor shown")
}

@(test)
test_fatal_signal_replays_stderr :: proc(t: ^testing.T) {
	res := run_in_child(proc() {
		wayu.tui_set_screen_active(true)
		if !wayu.tui_stderr_capture_begin() do posix._exit(90)
		wayu.tui_install_signal_handlers()
		msg := "Index 7 is out of range 0..<3\n"  // what a bounds trap prints
		posix.write(2, raw_data(msg), len(msg))
		posix.raise(.SIGTRAP)
		posix._exit(91)
	})
	testing.expectf(t, posix.WIFSIGNALED(res.status) && posix.WTERMSIG(res.status) == .SIGTRAP,
		"child status %d", res.status)
	leave := strings.index(res.output, "\x1b[?1049l")
	msg := strings.index(res.output, "out of range")
	testing.expectf(t, leave >= 0 && msg > leave, "bounds message lost or before restore: %q", res.output)
}

@(test)
test_normal_cleanup_discards_stderr :: proc(t: ^testing.T) {
	res := run_in_child(proc() {
		if !wayu.tui_stderr_capture_begin() do posix._exit(90)
		msg := "noise\n"
		posix.write(2, raw_data(msg), len(msg))
		wayu.tui_stderr_capture_end(replay = false)
		after := "after\n"
		posix.write(2, raw_data(after), len(after))
		posix._exit(0)
	})
	testing.expectf(t, res.output == "after\n", "got %q", res.output)
}
