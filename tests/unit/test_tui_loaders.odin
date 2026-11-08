package test_wayu

// OKAMI-248: TUI data loaders and mutations under the per-test tracking
// allocator (a leak fails the test), in a scratch config dir. Mutations run
// through execute_add_form / execute_pending_delete like a key press would,
// with and without --dry-run.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import wayu "../../src"

@(private = "file")
LOADER_TOML :: `[paths]
bin = "/usr/bin"
missing = "/nonexistent/wayu-tui-loader"

[aliases]
ll = "ls -la"
gs = "git status"

[env]
EDITOR = "vim"
`

// Scratch config+data dir holding LOADER_TOML, a backup, a completion and
// plugins.json. Restores wayu.wayu on return through the caller's defer.
@(private = "file")
Sandbox :: struct {
	dir:  string,
	toml: string,
	saved: wayu.AppContext,
}

@(private = "file")
sandbox_open :: proc(t: ^testing.T, name: string) -> Sandbox {
	sb := Sandbox{dir = test_tmp(name), saved = wayu.wayu}
	os.remove_all(sb.dir)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/backup", sb.dir)) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/completions", sb.dir)) == nil)
	sb.toml = fmt.aprintf("%s/%s", sb.dir, wayu.WAYU_TOML)
	write :: proc(t: ^testing.T, path, body: string) {
		testing.expectf(t, os.write_entire_file(path, transmute([]byte)body) == nil, "write %s", path)
	}
	write(t, sb.toml, LOADER_TOML)
	write(t, fmt.tprintf("%s/backup/wayu.toml.backup.2026-01-01_00-00-00.000001", sb.dir), LOADER_TOML)
	write(t, fmt.tprintf("%s/completions/_demo", sb.dir), "#compdef demo\n")
	write(t, fmt.tprintf("%s/plugins.json", sb.dir),
		`{"version": "1.0", "plugins": [{"name": "demo", "url": "https://example.test/demo.git", "enabled": true, "shell": "ZSH", "installed_path": "/nonexistent/demo", "priority": 100}]}`)
	wayu.wayu.config = sb.dir
	wayu.wayu.data = sb.dir
	wayu.wayu.shell = .ZSH
	wayu.wayu.shell_ext = "zsh"
	wayu.wayu.dry_run = false
	wayu.print_quiet = true
	wayu.clear_toml_content_cache()
	return sb
}

@(private = "file")
sandbox_close :: proc(sb: ^Sandbox) {
	wayu.wayu = sb.saved
	wayu.print_quiet = false
	wayu.clear_print_capture()
	wayu.clear_toml_content_cache()
	os.remove_all(sb.dir)
	delete(sb.toml)
}

@(private = "file")
read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return string(data) if err == nil else ""
}

@(private = "file")
cache_has :: proc(state: ^wayu.TUIState, view: wayu.TUIView, key: string) -> bool {
	for m in state.row_meta[view] {
		if m.key == key do return true
	}
	return false
}

// Every loader, twice (the second load replaces the first cache), then
// state teardown: nothing may leak.
@(test)
test_tui_loaders_do_not_leak :: proc(t: ^testing.T) {
	sb := sandbox_open(t, "wayu-test-tui-loaders")
	defer sandbox_close(&sb)

	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)

	views := []wayu.TUIView{.PATH_VIEW, .ALIAS_VIEW, .CONSTANTS_VIEW, .COMPLETIONS_VIEW, .BACKUPS_VIEW, .PLUGINS_VIEW}
	for _ in 0..<2 {
		for v in views {
			state.current_view = v
			wayu.clear_view_cache(&state, v)
			wayu.tui_ensure_data_loaded(&state, v)
		}
		state.settings.loaded = false
		wayu.tui_load_settings(&state)
	}

	testing.expect(t, cache_has(&state, .PATH_VIEW, "/usr/bin"), "PATH view lists [paths] entries")
	testing.expect(t, cache_has(&state, .ALIAS_VIEW, "gs"), "alias view lists [aliases] entries")
	testing.expect(t, cache_has(&state, .CONSTANTS_VIEW, "EDITOR"), "constants view lists [env] entries")
	testing.expect(t, cache_has(&state, .PLUGINS_VIEW, "demo"), "plugins view lists plugins.json entries")
	testing.expect(t, len(state.row_meta[.COMPLETIONS_VIEW]) == 1, "completions view lists _demo")
	testing.expectf(t, len(state.row_meta[.BACKUPS_VIEW]) == 1, "backups view lists the wayu.toml backup (got %d rows)", len(state.row_meta[.BACKUPS_VIEW]))
	testing.expectf(t, state.settings.backups == 1, "settings count the wayu.toml backup (got %d)", state.settings.backups)
	testing.expect(t, state.plugin_registry_cache != nil, "plugins view loads the registry")
	testing.expect(t, state.settings.loaded, "settings loaded")
}

@(private = "file")
fill_form :: proc(state: ^wayu.TUIState, view: wayu.TUIView, a, b: string) {
	wayu.show_add_form(state, view)
	for r in a do wayu.rune_buffer_push(&state.add_form.input_0, r)
	for r in b do wayu.rune_buffer_push(&state.add_form.input_1, r)
}

@(private = "file")
confirm_delete :: proc(state: ^wayu.TUIState, view: wayu.TUIView, name: string) {
	state.delete_confirm = {name = strings.clone(name), view = view, pending = true, focused = true}
	state.detail.shown = true
	wayu.execute_pending_delete(state)
}

// Add + delete for each data view: wayu.toml gets exactly the change, the
// notification says so, the cache is dropped for a reload; no leaks.
@(test)
test_tui_mutations_write_and_notify :: proc(t: ^testing.T) {
	sb := sandbox_open(t, "wayu-test-tui-mutations")
	defer sandbox_close(&sb)

	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)

	state.current_view = .ALIAS_VIEW
	wayu.tui_ensure_data_loaded(&state, .ALIAS_VIEW)
	fill_form(&state, .ALIAS_VIEW, "tz", "echo 'tui'")
	wayu.execute_add_form(&state)
	testing.expectf(t, strings.contains(read_text(sb.toml), `tz = "echo 'tui'"`), "alias written:\n%s", read_text(sb.toml))
	testing.expect_value(t, state.notify.kind, wayu.NotificationKind.SUCCESS)
	testing.expect(t, strings.has_prefix(state.notify.message, "Added alias: tz"), state.notify.message)
	testing.expect(t, !state.add_form.active, "form closes after a successful add")
	testing.expect(t, state.data_cache[.ALIAS_VIEW] == nil, "alias cache dropped for reload")

	fill_form(&state, .CONSTANTS_VIEW, "TUI_CONST", "a b")
	wayu.execute_add_form(&state)
	testing.expect(t, strings.contains(read_text(sb.toml), `TUI_CONST = "a b"`), "constant written")

	fill_form(&state, .PATH_VIEW, sb.dir, "")
	wayu.execute_add_form(&state)
	testing.expectf(t, strings.contains(read_text(sb.toml), sb.dir), "path written:\n%s", read_text(sb.toml))

	confirm_delete(&state, .ALIAS_VIEW, "gs")
	testing.expect(t, !strings.contains(read_text(sb.toml), "gs ="), "alias removed")
	testing.expect(t, strings.has_prefix(state.notify.message, "Removed alias: gs"), state.notify.message)
	testing.expect(t, !state.delete_confirm.pending && !state.detail.shown, "confirm dialog dismissed")

	confirm_delete(&state, .CONSTANTS_VIEW, "EDITOR")
	testing.expect(t, !strings.contains(read_text(sb.toml), "EDITOR"), "constant removed")

	confirm_delete(&state, .PATH_VIEW, "/usr/bin")
	testing.expect(t, !strings.contains(read_text(sb.toml), `"/usr/bin"`), "path removed")

	// Failures keep the form open with the reason; nothing is written.
	before := strings.clone(read_text(sb.toml))
	defer delete(before)
	fill_form(&state, .ALIAS_VIEW, "bad name", "x")
	wayu.execute_add_form(&state)
	testing.expect(t, state.add_form.active && len(state.add_form.error_message) > 0, "invalid alias keeps the form with an error")
	testing.expect_value(t, read_text(sb.toml), before)
	wayu.clear_add_form(&state)

	confirm_delete(&state, .ALIAS_VIEW, "no-such-alias")
	testing.expect_value(t, state.notify.kind, wayu.NotificationKind.ERROR)
	testing.expect_value(t, read_text(sb.toml), before)
}

// --dry-run: same notifications prefixed "Dry run: would …", and no file in
// the config dir changes.
@(test)
test_tui_mutations_dry_run_write_nothing :: proc(t: ^testing.T) {
	sb := sandbox_open(t, "wayu-test-tui-dryrun")
	defer sandbox_close(&sb)
	wayu.wayu.dry_run = true

	snapshot :: proc(dir: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		for sub in ([]string{"", "/backup"}) {
			d, err := os.open(fmt.tprintf("%s%s", dir, sub))
			if err != nil do continue
			infos, _ := os.read_dir(d, -1, context.temp_allocator)
			os.close(d)
			for fi in infos {
				if fi.type == .Directory do continue
				fmt.sbprintf(&b, "%s%s/%s=%s\n", dir, sub, fi.name, read_text(fi.fullpath))
			}
		}
		return strings.to_string(b)
	}
	before := strings.clone(snapshot(sb.dir))
	defer delete(before)

	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)

	fill_form(&state, .ALIAS_VIEW, "dz", "echo dry")
	wayu.execute_add_form(&state)
	testing.expect(t, strings.has_prefix(state.notify.message, "Dry run: would add alias: dz"), state.notify.message)
	fill_form(&state, .PATH_VIEW, sb.dir, "")
	wayu.execute_add_form(&state)
	testing.expect(t, strings.has_prefix(state.notify.message, "Dry run: would add PATH entry"), state.notify.message)
	confirm_delete(&state, .CONSTANTS_VIEW, "EDITOR")
	testing.expect(t, strings.has_prefix(state.notify.message, "Dry run: would remove constant: EDITOR"), state.notify.message)
	confirm_delete(&state, .PATH_VIEW, "/usr/bin")
	testing.expect(t, strings.has_prefix(state.notify.message, "Dry run: would remove PATH entry"), state.notify.message)

	testing.expect_value(t, snapshot(sb.dir), before)
}
