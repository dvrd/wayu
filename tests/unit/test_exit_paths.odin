// test_exit_paths.odin - Every exit goes through wayu_exit (OKAMI-367).
//
// On Linux the Odin runtime's os.exit is a raw exit_group: atexit handlers
// (the TUI's terminal restore) never run, so a bare os.exit reachable from
// the TUI leaves the shell in raw mode on the alternate screen. wayu_exit
// restores the terminal first; this test keeps os.exit out of src/ except
// inside wayu_exit itself.

package test_wayu

import "core:strings"
import "core:testing"

@(test)
test_no_bare_os_exit :: proc(t: ^testing.T) {
	files := #load_directory("../../src")
	checked := 0
	for f in files {
		if !strings.has_suffix(f.name, ".odin") do continue
		checked += 1
		text := string(f.data)
		line_no := 0
		for line in strings.split_lines_iterator(&text) {
			line_no += 1
			if !strings.contains(line, "os.exit(") do continue
			code := strings.trim_space(line)
			if strings.has_prefix(code, "//") do continue
			if strings.has_suffix(f.name, "tui_io.odin") && code == "os.exit(code)" do continue // wayu_exit
			testing.expectf(
				t,
				false,
				"%s:%d calls os.exit directly: use wayu_exit (restores the terminal on Linux)",
				f.name,
				line_no,
			)
		}
	}
	testing.expectf(t, checked > 20, "src/ not loaded (%d files)", checked)
}
