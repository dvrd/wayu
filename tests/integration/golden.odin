package integration

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

@(test)
golden :: proc(t: ^testing.T) {
	cli := new_cli(t)
	defer os.remove_all(cli.home)
	data, err := os.read_entire_file_from_path("tests/golden/cases.txt", context.temp_allocator)
	if err != nil {
		testing.fail_now(t, fmt.tprintf("read cases.txt: %v", err))
	}
	goldens, glob_err := os.glob("tests/golden/*.txt", context.temp_allocator)
	if glob_err != nil {
		testing.fail_now(t, fmt.tprintf("list goldens: %v", glob_err))
	}
	remaining := make(map[string]bool, context.temp_allocator)
	for path in goldens {
		name := strings.trim_suffix(filepath.base(path), ".txt")
		if name != "cases" {
			remaining[name] = true
		}
	}
	for raw in strings.split_lines(string(data), context.temp_allocator) {
		line := strings.trim_space(raw)
		if line == "" || strings.has_prefix(line, "#") {
			continue
		}
		words := fixture_words(t, line)
		if !testing.expectf(t, len(words) >= 2, "missing component: %s", line) {
			continue
		}
		name := words[0]
		if !testing.expectf(t, remaining[name], "duplicate case or missing golden: %s", name) {
			continue
		}
		delete_key(&remaining, name)
		i := strings.last_index_byte(name, '_')
		w, split, h := strings.partition(name[i + 1:], "x")
		_, width_ok := strconv.parse_uint(w, 10)
		_, height_ok := strconv.parse_uint(h, 10)
		if !testing.expectf(
			t,
			i >= 0 && split != "" && width_ok && height_ok,
			"bad dimensions: %s",
			name,
		) {
			continue
		}
		args := make([dynamic]string, context.temp_allocator)
		append(
			&args,
			fmt.tprintf("-c=%s", words[1]),
			"--test",
			fmt.tprintf("width=%s", w),
			fmt.tprintf("height=%s", h),
		)
		append(&args, ..words[2:])
		out, code := run_cli(t, cli, ..args[:])
		testing.expectf(
			t,
			code == 0 && strings.contains(out, "MATCH") && !strings.contains(out, "MISMATCH"),
			"%s: exit %d: %s",
			name,
			code,
			out,
		)
	}
	for name in remaining {testing.expectf(t, false, "missing case for %s", name)}
}
