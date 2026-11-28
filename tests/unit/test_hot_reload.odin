// test_hot_reload.odin - `wayu watch` change detection (OKAMI-361): the
// watcher watches secrets.json too, and a watched file that appears or goes
// away after the first poll counts as a change.

package test_wayu

import wayu "../../src"
import "core:os"
import "core:testing"
import "core:time"

@(private = "file")
changed_has :: proc(changed: []string, path: string) -> bool {
	for c in changed {
		if c == path do return true
	}
	return false
}

@(private = "file")
free_changed :: proc(changed: []string) {
	for c in changed {delete(c)}
	delete(changed)
}

@(test)
test_watch_paths_include_secrets_store :: proc(t: ^testing.T) {
	dir := test_tmp("hot_reload_paths")
	os.remove_all(dir)
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	saved_data, saved_config := wayu.wayu.data, wayu.wayu.config
	defer {wayu.wayu.data = saved_data; wayu.wayu.config = saved_config}
	wayu.wayu.data, wayu.wayu.config = dir, dir

	// No secrets.json yet: still watched, so the first secret is picked up.
	paths := wayu.get_default_watch_paths()
	defer {
		for p in paths {delete(p)}
		delete(paths)
	}
	testing.expectf(
		t,
		changed_has(paths, wayu.secrets_store_path()),
		"secrets.json not watched: %v",
		paths,
	)
	testing.expect(t, wayu.watch_path_is_secrets(wayu.secrets_store_path()))
	testing.expect(t, !wayu.watch_path_is_secrets(wayu.entries_file_path(context.temp_allocator)))
}

@(test)
test_watch_detects_created_and_deleted_files :: proc(t: ^testing.T) {
	dir := test_tmp("hot_reload_changes")
	os.remove_all(dir)
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	present := test_tmp("hot_reload_changes/entries.json")
	later := test_tmp("hot_reload_changes/secrets.json")
	_ = os.write_entire_file(present, transmute([]byte)string("{}\n"))

	wayu.hot_reload_init([]string{present, later}, nil)
	defer wayu.hot_reload_reset()

	first := wayu.check_file_changes()
	testing.expectf(t, len(first) == 0, "first poll only records: %v", first)
	free_changed(first)

	_ = os.write_entire_file(later, transmute([]byte)string("{}\n"))
	created := wayu.check_file_changes()
	testing.expectf(t, changed_has(created, later) && len(created) == 1, "created: %v", created)
	free_changed(created)

	quiet := wayu.check_file_changes()
	testing.expectf(t, len(quiet) == 0, "no change: %v", quiet)
	free_changed(quiet)

	os.remove(later)
	gone := wayu.check_file_changes()
	testing.expectf(t, changed_has(gone, later) && len(gone) == 1, "deleted: %v", gone)
	free_changed(gone)
}

@(test)
test_watch_debounce_monotonic :: proc(t: ^testing.T) {
	state: wayu.Watch_Debounce
	first := time.tick_now()
	second := time.tick_add(first, 499 * time.Millisecond)
	wayu.watch_debounce_note(&state, first, true)
	early, _ := wayu.watch_debounce_take(&state, second, 500)
	testing.expect(t, !early)
	wayu.watch_debounce_note(&state, second, false)
	reset, _ := wayu.watch_debounce_take(&state, time.tick_add(first, 500 * time.Millisecond), 500)
	testing.expect(t, !reset)
	// Only the elapsed monotonic interval enters the decision.
	ready, secrets := wayu.watch_debounce_take(
		&state,
		time.tick_add(second, 500 * time.Millisecond),
		500,
	)
	testing.expect(t, ready && secrets)
	again, _ := wayu.watch_debounce_take(&state, time.tick_add(second, time.Hour), 500)
	testing.expect(t, !again)
}

// File times come from the wall clock. A write stamped earlier than the last
// one seen (a backward clock correction, a file restored with its old time)
// is a change like any other, and so is a jump forward.
@(test)
test_watch_detects_changes_across_wall_clock_steps :: proc(t: ^testing.T) {
	dir := test_tmp("hot_reload_clock")
	os.remove_all(dir)
	os.make_directory_all(dir)
	defer os.remove_all(dir)

	path := test_tmp("hot_reload_clock/entries.json")
	_ = os.write_entire_file(path, transmute([]byte)string("{}\n"))

	wayu.hot_reload_init([]string{path}, nil)
	defer wayu.hot_reload_reset()

	first := wayu.check_file_changes()
	testing.expectf(t, len(first) == 0, "first poll only records: %v", first)
	free_changed(first)

	now := time.now()
	for step in ([]time.Duration{-time.Hour, 2 * time.Hour}) {
		stamp := time.time_add(now, step)
		_ = os.write_entire_file(path, transmute([]byte)string("{\"version\":1}\n"))
		testing.expect(t, os.change_times(path, stamp, stamp) == nil)
		stepped := wayu.check_file_changes()
		testing.expectf(
			t,
			changed_has(stepped, path) && len(stepped) == 1,
			"%v: %v",
			step,
			stepped,
		)
		free_changed(stepped)

		quiet := wayu.check_file_changes()
		testing.expectf(t, len(quiet) == 0, "no change after %v: %v", step, quiet)
		free_changed(quiet)
	}
}
