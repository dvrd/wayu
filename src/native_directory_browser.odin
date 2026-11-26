package wayu

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

warp_jump :: proc(args: []string, session: ^Native_Session = nil) -> int {
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil {
		return EXIT_OSERR
	}
	dir := native_jump_match(cwd, args)
	if dir == "" {
		fmt.eprintln("wayu warp: no matching directory")
		return EXIT_FAILURE
	}
	if session != nil {
		return native_cd(session, dir)
	}
	fmt.println(dir)
	return EXIT_SUCCESS
}

Warp_Row :: struct {
	dir:   string,
	score: f64,
}

warp_rows :: proc(visits: map[string]Native_Dir_Visit, terms: []string) -> []Warp_Row {
	rows := make([dynamic]Warp_Row, context.temp_allocator)
	now := time.to_unix_nanoseconds(time.now())
	for dir, visit in visits {
		lower := strings.to_lower(dir, context.temp_allocator)
		match := true
		for term in terms {
			if !strings.contains(lower, term) {
				match = false
				break
			}
		}
		if match {
			append(&rows, Warp_Row{dir, native_jump_score(visit, now)})
		}
	}
	slice.sort_by(rows[:], proc(a, b: Warp_Row) -> bool {
		return a.score > b.score || a.score == b.score && a.dir < b.dir
	})
	return rows[:]
}

handle_warp :: proc(action: Action, args: []string) -> int {
	if action == .HELP {
		fmt.println("wayu warp <words...>           Jump to the highest-scoring match")
		fmt.println("wayu warp edit                 Edit directory history")
		fmt.println("wayu warp search [words...]    Select a directory and print its path")
		return EXIT_SUCCESS
	}
	if action == .RUN {
		return warp_jump(args)
	}
	path := fmt.tprintf("%s/directories.json", wayu.data)
	if action == .UPDATE {
		if len(args) != 0 {
			fmt.eprintln("Usage: wayu warp edit")
			return EXIT_USAGE
		}
		if is_stdin_tty() && is_stdout_tty() {
			status := warp_editor(path)
			if status == EXIT_CONFIG {
				fmt.eprintfln("Cannot read %s", path)
			}
			return status
		}
	}
	visits, ok := native_directory_visits(path)
	if !ok {
		fmt.eprintfln("Cannot read %s", path)
		return EXIT_CONFIG
	}
	terms := make([dynamic]string, context.temp_allocator)
	for arg in args {append(&terms, strings.to_lower(arg, context.temp_allocator))}
	rows := warp_rows(visits, terms[:])
	items := make([]string, len(rows), context.temp_allocator)
	for row, i in rows {
		display, _ := strings.replace_all(row.dir, "\\", "\\\\", context.temp_allocator)
		items[i] = fmt.tprintf("%8.1f  %s", row.score, term_safe(display))
	}
	title :: "   SCORE  PATH"
	if action == .UPDATE {
		fmt.println(title)
		for item in items {fmt.println(item)}
		return EXIT_SUCCESS
	}
	if len(rows) == 0 {
		fmt.eprintln("No matching directories.")
		return EXIT_FAILURE
	}
	tty, err := os.open("/dev/tty", {.Read, .Write})
	if err != nil {
		fmt.eprintln("wayu warp search needs a controlling terminal for selection")
		return EXIT_UNAVAILABLE
	}
	defer os.close(tty)
	selected, picked := interactive_select(items, title, tty, tty)
	defer delete(selected)
	if !picked {
		return EXIT_FAILURE
	}
	idx, _ := slice.linear_search(items, selected)
	fmt.println(rows[idx].dir)
	return EXIT_SUCCESS
}

warp_change :: proc(path, dir: string, key: rune, seen: Native_Dir_Visit) -> string {
	if wayu.dry_run {
		return "Dry run: history unchanged"
	}
	if !config_lock_acquire() {
		return "Could not lock directory history"
	}
	defer config_lock_release()
	current, ok := native_directory_visits(path)
	if !ok {
		return "Could not read directory history"
	}
	visit, exists := current[dir]
	if !exists || (key == 'd' && visit != seen) {
		return "Entry changed. Review before editing again."
	}
	switch key {
	case 'd':
		delete_key(&current, dir)
	case 'w':
		visit.count = min(visit.count + 1, NATIVE_JUMP_MAX_RANK)
		current[dir] = visit
	case 's':
		visit.count = max(visit.count - 1, min(visit.count, 1))
		current[dir] = visit
	}
	if !native_directory_save(path, current) {
		return "Could not save directory history"
	}
	return ""
}

warp_preview :: proc(screen: ^Screen, dir: string, first, bottom: int) {
	y := first
	render_text_styled(screen, 0, y, "Contents", bold = true)
	for col in 9 ..< screen.width {screen_set_cell(screen, col, y, Cell{char = '─', dim = true})}
	handle, err := os.open(dir)
	if err != nil {
		render_text(screen, 2, y + 1, "Directory unavailable")
		return
	}
	defer os.close(handle)
	entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
	if read_err != nil {
		render_text(screen, 2, y + 1, "Cannot read directory")
		return
	}
	names := make([dynamic]string, context.temp_allocator)
	for entry in entries {
		if strings.has_prefix(entry.name, ".") {
			continue
		}
		append(&names, fmt.tprintf("%s%s", entry.name, "/" if entry.type == .Directory else ""))
	}
	slice.sort(names[:])
	if len(names) == 0 {
		render_text(screen, 2, y + 1, "(empty)")
		return
	}
	x := 2
	y += 1
	for name in names {
		width := visual_width(name)
		if x > 2 && x + width > screen.width {
			x = 2
			y += 1
		}
		if y >= bottom {
			break
		}
		render_text(screen, x, y, name)
		x += width + 3
	}
}

warp_render :: proc(
	screen: ^Screen,
	filter: string,
	rows: []Warp_Row,
	total, selected: int,
	top: ^int,
	dir, status: string,
	confirm, full: bool,
) {
	w, h := screen.width, screen.height
	screen_clear(screen)
	bottom := h - 1
	preview := bottom - max(3, h / 4) if h >= 9 else bottom
	count := max(1, preview - 2)
	top^ = clamp(top^, max(0, selected - count + 1), selected)
	top^ = min(top^, max(0, len(rows) - count))
	render_text(screen, 0, 0, fmt.tprintf("Filter > %s   %d/%d", filter, len(rows), total))
	render_text_styled(screen, 2, 1, "   SCORE  PATH", bold = true)
	for i in top^ ..< min(len(rows), top^ + count) {
		y := 2 + i - top^
		if i == selected {
			render_text(screen, 0, y, ">")
			screen_mark_focus(screen, 0, y)
		}
		render_text_styled(
			screen,
			2,
			y,
			fmt.tprintf("%8.1f  %s", rows[i].score, rows[i].dir),
			bold = i == selected,
		)
	}
	if dir == "" {
		render_text(screen, 2, 2, "No matching directories")
	}
	if preview < bottom && dir != "" {
		warp_preview(screen, dir, preview, bottom)
	}
	legend := "↑↓ Move  Ctrl+W Raise  Ctrl+S Lower  Ctrl+D Forget  Ctrl+R Reload  Esc Close"
	if w < 76 {
		legend = "↑↓ Move  Ctrl+W/S Rank  Ctrl+D Forget  Ctrl+R Reload  Esc"
	}
	if status != "" {
		legend = status
	}
	if confirm {
		legend = "Forget selected history entry?  Y Yes  Esc Cancel"
	}
	render_text(screen, 0, bottom, legend)
	screen_flush(screen, full, os.stdout)
}

warp_editor :: proc(path: string) -> int {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return EXIT_OSERR
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	tui_init()
	defer tui_cleanup()
	width, height, _ := get_terminal_size(probe = false)
	screen := screen_create(width, height)
	defer screen_destroy(&screen)
	filter: [dynamic]u8
	defer delete(filter)
	selected, top := 0, 0
	keep := ""
	defer delete(keep)
	status := ""
	confirm, full := false, true
	for {
		free_all(context.temp_allocator)
		visits, ok := native_directory_visits(path)
		if !ok {
			return EXIT_CONFIG
		}
		reload := false
		for !reload {
			filter_memory := virtual.arena_temp_begin(&arena)
			defer virtual.arena_temp_end(filter_memory)
			query := strings.to_lower(string(filter[:]), context.temp_allocator)
			terms := strings.fields(query, context.temp_allocator)
			rows := warp_rows(visits, terms)
			selected = clamp(selected, 0, max(0, len(rows) - 1))
			if keep != "" {
				for row, i in rows {
					if row.dir == keep {
						selected = i
						break
					}
				}
				delete(keep)
				keep = ""
			}
			dirty := true
			for {
				w, h, _ := get_terminal_size(probe = false)
				if w != screen.width || h != screen.height {
					screen_resize(&screen, w, h)
					full = true
				}
				dir := rows[selected].dir if len(rows) > 0 else ""
				if dirty || full {
					frame := virtual.arena_temp_begin(&arena)
					defer virtual.arena_temp_end(frame)
					warp_render(
						&screen,
						string(filter[:]),
						rows,
						len(visits),
						selected,
						&top,
						dir,
						status,
						confirm,
						full,
					)
					full, dirty = false, false
				}
				event := poll_event()
				defer destroy_event(event)
				if tui_input_closed {
					return EXIT_SUCCESS
				}
				if event == nil {
					continue
				}
				if paste, pasted := event.(PasteEvent); pasted {
					if !confirm {
						append(&filter, ..transmute([]u8)paste.text)
						selected, top = 0, 0
						break
					}
					continue
				}
				k, pressed := event.(KeyEvent)
				if !pressed {
					continue
				}
				dirty = true
				status = ""
				ctrl := .Ctrl in k.modifiers
				if ctrl && k.char == 'c' {
					return EXIT_SUCCESS
				}
				change: rune
				if confirm {
					confirm = false
					if k.key != .Char || ctrl || (k.char != 'y' && k.char != 'Y') {
						continue
					}
					change = 'd'
				} else if k.key == .Escape || k.key == .Enter {
					return EXIT_SUCCESS
				} else if k.key == .Down || ctrl && k.char == 'n' {
					selected = min(selected + 1, max(0, len(rows) - 1))
				} else if k.key == .Up || ctrl && k.char == 'p' {
					selected = max(selected - 1, 0)
				} else if ctrl && k.char == 'r' {
					reload = true
				} else if ctrl && dir != "" && k.char == 'd' {
					confirm = true
					tui_discard_typeahead()
				} else if ctrl && dir != "" && (k.char == 'w' || k.char == 's') {
					change = k.char
				} else if k.key == .Backspace && len(filter) > 0 {
					_, n := utf8.decode_last_rune(filter[:])
					resize(&filter, len(filter) - n)
					selected, top = 0, 0
					break
				} else if k.key == .Char && k.modifiers == {} {
					bytes, n := utf8.encode_rune(k.char)
					append(&filter, ..bytes[:n])
					selected, top = 0, 0
					break
				}
				if change != 0 {
					status = warp_change(path, dir, change, visits[dir])
					reload = true
				}
				if reload {
					keep = strings.clone(dir)
					break
				}
			}
		}
	}
}
