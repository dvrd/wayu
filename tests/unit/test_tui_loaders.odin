package test_wayu

// OKAMI-248: TUI data loaders and mutations under the per-test tracking
// allocator (a leak fails the test), in a scratch config dir. Mutations run
// through execute_add_form / execute_pending_delete like a key press would,
// with and without --dry-run.

import wayu "../../src"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
LOADER_TOML :: "[shell]\ntype = \"zsh\"\n"

@(private = "file")
LOADER_ENTRIES :: `{
  "version": 1,
  "paths": [
    {"key": "bin", "dir": "/usr/bin"},
    {"key": "missing", "dir": "/nonexistent/wayu-tui-loader"}
  ],
  "aliases": [
    {"name": "ll", "value": "ls -la"},
    {"name": "gs", "value": "git status"}
  ],
  "env": [
    {"name": "EDITOR", "value": "vim"}
  ]
}
`

// Scratch config+data dir holding LOADER_TOML, LOADER_ENTRIES, an
// entries.json backup, a completion and plugins.json. Restores wayu.wayu on
// return through the caller's defer.
@(private = "file")
Sandbox :: struct {
	dir:     string,
	toml:    string,
	entries: string,
	saved:   wayu.AppContext,
}

@(private = "file")
sandbox_open :: proc(t: ^testing.T, name: string) -> Sandbox {
	sb := Sandbox {
		dir   = test_tmp(name),
		saved = wayu.wayu,
	}
	os.remove_all(sb.dir)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/backup", sb.dir)) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/completions", sb.dir)) == nil)
	sb.toml = fmt.aprintf("%s/%s", sb.dir, wayu.WAYU_TOML)
	sb.entries = fmt.aprintf("%s/%s", sb.dir, wayu.ENTRIES_FILE)
	write :: proc(t: ^testing.T, path, body: string) {
		testing.expectf(
			t,
			os.write_entire_file(path, transmute([]byte)body) == nil,
			"write %s",
			path,
		)
	}
	write(t, sb.toml, LOADER_TOML)
	write(t, sb.entries, LOADER_ENTRIES)
	write(
		t,
		fmt.tprintf("%s/backup/entries.json.backup.2026-01-01_00-00-00.000001", sb.dir),
		LOADER_ENTRIES,
	)
	write(t, fmt.tprintf("%s/completions/_demo", sb.dir), "#compdef demo\n")
	write(
		t,
		fmt.tprintf("%s/plugins.json", sb.dir),
		`{"version": "1.0", "plugins": [{"name": "demo", "url": "https://example.test/demo.git", "enabled": true, "shell": "ZSH", "installed_path": "/nonexistent/demo", "priority": 100}]}`,
	)
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
	delete(sb.entries)
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

	views := []wayu.TUIView {
		.PATH_VIEW,
		.ALIAS_VIEW,
		.CONSTANTS_VIEW,
		.COMPLETIONS_VIEW,
		.BACKUPS_VIEW,
		.PLUGINS_VIEW,
	}
	for _ in 0 ..< 2 {
		for v in views {
			state.current_view = v
			wayu.clear_view_cache(&state, v)
			wayu.tui_ensure_data_loaded(&state, v)
		}
		state.settings.loaded = false
		wayu.tui_load_settings(&state)
	}

	testing.expect(
		t,
		cache_has(&state, .PATH_VIEW, "/usr/bin"),
		"PATH view lists the store's paths",
	)
	testing.expect(t, cache_has(&state, .ALIAS_VIEW, "gs"), "alias view lists the store's aliases")
	testing.expect(
		t,
		cache_has(&state, .CONSTANTS_VIEW, "EDITOR"),
		"constants view lists the store's env",
	)
	testing.expect(
		t,
		cache_has(&state, .PLUGINS_VIEW, "demo"),
		"plugins view lists plugins.json entries",
	)
	testing.expect(t, len(state.row_meta[.COMPLETIONS_VIEW]) == 1, "completions view lists _demo")
	testing.expectf(
		t,
		len(state.row_meta[.BACKUPS_VIEW]) == 1,
		"backups view lists the entries.json backup (got %d rows)",
		len(state.row_meta[.BACKUPS_VIEW]),
	)
	testing.expectf(
		t,
		state.settings.backups == 1,
		"settings count the entries.json backup (got %d)",
		state.settings.backups,
	)
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
	state.delete_confirm = {
		name    = strings.clone(name),
		view    = view,
		pending = true,
		focused = true,
	}
	state.detail.shown = true
	wayu.execute_pending_delete(state)
}

// Add + delete for each data view: entries.json gets exactly the change, the
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
	testing.expectf(
		t,
		strings.contains(read_text(sb.entries), `{"name": "tz", "value": "echo 'tui'"}`),
		"alias written:\n%s",
		read_text(sb.entries),
	)
	testing.expect_value(t, state.notify.kind, wayu.NotificationKind.SUCCESS)
	testing.expect(
		t,
		strings.has_prefix(state.notify.message, "Added alias: tz"),
		state.notify.message,
	)
	testing.expect(t, !state.add_form.active, "form closes after a successful add")
	testing.expect(t, state.data_cache[.ALIAS_VIEW] == nil, "alias cache dropped for reload")

	fill_form(&state, .CONSTANTS_VIEW, "TUI_CONST", "a b")
	wayu.execute_add_form(&state)
	testing.expect(
		t,
		strings.contains(read_text(sb.entries), `{"name": "TUI_CONST", "value": "a b"}`),
		"constant written",
	)

	fill_form(&state, .PATH_VIEW, sb.dir, "")
	wayu.execute_add_form(&state)
	testing.expectf(
		t,
		strings.contains(read_text(sb.entries), fmt.tprintf(`"dir": "%s"`, sb.dir)),
		"path written:\n%s",
		read_text(sb.entries),
	)

	confirm_delete(&state, .ALIAS_VIEW, "gs")
	testing.expect(t, !strings.contains(read_text(sb.entries), `"name": "gs"`), "alias removed")
	testing.expect(
		t,
		strings.has_prefix(state.notify.message, "Removed alias: gs"),
		state.notify.message,
	)
	testing.expect(
		t,
		!state.delete_confirm.pending && !state.detail.shown,
		"confirm dialog dismissed",
	)

	confirm_delete(&state, .CONSTANTS_VIEW, "EDITOR")
	testing.expect(t, !strings.contains(read_text(sb.entries), "EDITOR"), "constant removed")

	confirm_delete(&state, .PATH_VIEW, "/usr/bin")
	testing.expect(t, !strings.contains(read_text(sb.entries), `"/usr/bin"`), "path removed")

	// Failures keep the form open with the reason; nothing is written.
	before := strings.clone(read_text(sb.entries))
	defer delete(before)
	fill_form(&state, .ALIAS_VIEW, "bad name", "x")
	wayu.execute_add_form(&state)
	testing.expect(
		t,
		state.add_form.active && len(state.add_form.error_message) > 0,
		"invalid alias keeps the form with an error",
	)
	testing.expect_value(t, read_text(sb.entries), before)
	wayu.clear_add_form(&state)

	confirm_delete(&state, .ALIAS_VIEW, "no-such-alias")
	testing.expect_value(t, state.notify.kind, wayu.NotificationKind.ERROR)
	testing.expect_value(t, read_text(sb.entries), before)
}

// --dry-run: notifications "[dry-run] would …", and no file in
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
	testing.expect(
		t,
		strings.has_prefix(state.notify.message, "[dry-run] would add alias: dz"),
		state.notify.message,
	)
	fill_form(&state, .PATH_VIEW, sb.dir, "")
	wayu.execute_add_form(&state)
	testing.expect(
		t,
		strings.has_prefix(state.notify.message, "[dry-run] would add PATH entry"),
		state.notify.message,
	)
	confirm_delete(&state, .CONSTANTS_VIEW, "EDITOR")
	testing.expect(
		t,
		strings.has_prefix(state.notify.message, "[dry-run] would remove constant: EDITOR"),
		state.notify.message,
	)
	confirm_delete(&state, .PATH_VIEW, "/usr/bin")
	testing.expect(
		t,
		strings.has_prefix(state.notify.message, "[dry-run] would remove PATH entry"),
		state.notify.message,
	)

	testing.expect_value(t, snapshot(sb.dir), before)
}

// ---------------------------------------------------------------------------
// Phase 3 (OKAMI-254/255/259/260/264/266/267/183/184)
// ---------------------------------------------------------------------------

@(private = "file")
type_into :: proc(state: ^wayu.TUIState, text: string) {
	for r in text do wayu.handle_add_form_input(state, wayu.KeyEvent{key = .Char, char = r})
}

@(private = "file")
press :: proc(state: ^wayu.TUIState, k: wayu.Key, ch: rune = 0) {
	wayu.handle_key_event(state, wayu.KeyEvent{key = k, char = ch})
}

// OKAMI-254: --dry-run never writes plugins.json / entries.json / backups and
// says so as a preview ([dry-run], INFO), for every TUI mutation.
@(test)
test_tui_dry_run_previews_every_mutation :: proc(t: ^testing.T) {
	sb := sandbox_open(t, "wayu-test-tui-dryrun-all")
	defer sandbox_close(&sb)
	plugins_json := fmt.tprintf("%s/plugins.json", sb.dir)
	before_plugins := strings.clone(read_text(plugins_json))
	defer delete(before_plugins)
	before_entries := strings.clone(read_text(sb.entries))
	defer delete(before_entries)
	wayu.wayu.dry_run = true

	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)

	wayu.tui_set_plugin_enabled(&state, "demo", false)
	testing.expect_value(t, state.notify.kind, wayu.NotificationKind.INFO)
	testing.expect(
		t,
		strings.has_prefix(state.notify.message, "[dry-run] would disable demo"),
		state.notify.message,
	)

	wayu.tui_install_registry_plugin(&state, "zsh-autosuggestions")
	testing.expect(
		t,
		strings.has_prefix(state.notify.message, "[dry-run] would install"),
		state.notify.message,
	)
	ok, err := wayu.tui_install_plugin("zsh-autosuggestions")
	testing.expect(t, !ok, "tui_install_plugin never installs under --dry-run")
	delete(err)

	wayu.tui_restore_backup(
		&state,
		fmt.tprintf("%s/backup/entries.json.backup.2026-01-01_00-00-00.000001", sb.dir),
	)
	testing.expect(
		t,
		strings.has_prefix(state.notify.message, "[dry-run] would restore"),
		state.notify.message,
	)
	wayu.tui_cleanup_backups(&state)
	testing.expect(
		t,
		strings.has_prefix(state.notify.message, "[dry-run] would remove"),
		state.notify.message,
	)

	fill_form(&state, .ALIAS_VIEW, "dz", "echo dry")
	wayu.execute_add_form(&state)
	testing.expect_value(t, state.notify.kind, wayu.NotificationKind.INFO)
	testing.expect(
		t,
		strings.contains(state.notify.message, `dz = "echo dry"`),
		state.notify.message,
	)

	testing.expect_value(t, read_text(plugins_json), before_plugins)
	testing.expect_value(t, read_text(sb.entries), before_entries)
	backups := wayu.list_backups_for_file(plugins_json)
	defer wayu.free_backup_infos(backups)
	testing.expect_value(t, len(backups), 0)
}

// OKAMI-259: PATH input goes through the CLI's parse_path_arg + checks;
// an existing alias/constant needs a confirmation; outcomes are distinct.
@(test)
test_tui_add_matches_cli_semantics :: proc(t: ^testing.T) {
	sb := sandbox_open(t, "wayu-test-tui-add-semantics")
	defer sandbox_close(&sb)
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)

	// name=path names the key (was stored as a relative path "<cwd>/go=...").
	sub := fmt.tprintf("%s/completions", sb.dir)
	fill_form(&state, .PATH_VIEW, fmt.tprintf("mytools=%s", sub), "")
	wayu.execute_add_form(&state)
	testing.expectf(
		t,
		strings.contains(
			read_text(sb.entries),
			strings.concatenate(
				{`{"key": "mytools", "dir": "`, sub, `"}`},
				context.temp_allocator,
			),
		),
		"name=path keeps the name:\n%s",
		read_text(sb.entries),
	)
	testing.expect(
		t,
		strings.has_prefix(state.notify.message, "Added PATH entry"),
		state.notify.message,
	)

	// Same path again: nothing changed, said so (was "Added").
	fill_form(&state, .PATH_VIEW, sub, "")
	wayu.execute_add_form(&state)
	testing.expect_value(t, state.notify.kind, wayu.NotificationKind.INFO)
	testing.expect(
		t,
		strings.has_prefix(state.notify.message, "Already present"),
		state.notify.message,
	)

	// Missing / unresolvable paths are refused with the CLI's reason.
	fill_form(&state, .PATH_VIEW, "relative/does-not-exist", "")
	wayu.execute_add_form(&state)
	testing.expect(t, state.add_form.active, "form stays open")
	testing.expect(
		t,
		strings.contains(
			state.add_form.error_message,
			"Path does not exist: relative/does-not-exist",
		),
		state.add_form.error_message,
	)
	wayu.clear_add_form(&state)
	fill_form(&state, .PATH_VIEW, "$WAYU_SURELY_UNSET_VAR/bin", "")
	wayu.execute_add_form(&state)
	testing.expect(
		t,
		strings.contains(state.add_form.error_message, "Could not resolve"),
		state.add_form.error_message,
	)
	wayu.clear_add_form(&state)

	// Existing alias: confirmation first, nothing written until yes.
	fill_form(&state, .ALIAS_VIEW, "ll", "ls -lah")
	wayu.execute_add_form(&state)
	testing.expect(
		t,
		state.delete_confirm.pending && state.delete_confirm.kind == .REPLACE,
		"replace asks first",
	)
	testing.expect(
		t,
		strings.contains(read_text(sb.entries), `"ls -la"`),
		"not written before yes",
	)
	press(&state, .Char, 'y')
	testing.expect(
		t,
		strings.contains(read_text(sb.entries), `{"name": "ll", "value": "ls -lah"}`),
		"replaced after yes",
	)
	testing.expect(
		t,
		strings.has_prefix(state.notify.message, "Updated alias: ll"),
		state.notify.message,
	)
	testing.expect(t, !state.add_form.active, "form closed")

	// Cancel keeps the form and the old value.
	fill_form(&state, .CONSTANTS_VIEW, "EDITOR", "nano")
	wayu.execute_add_form(&state)
	press(&state, .Escape)
	testing.expect(
		t,
		state.add_form.active && !state.delete_confirm.pending,
		"cancel returns to the form",
	)
	testing.expect(
		t,
		strings.contains(read_text(sb.entries), `{"name": "EDITOR", "value": "vim"}`),
		"kept",
	)
	wayu.clear_add_form(&state)
}

// OKAMI-255 (already fixed by Phase 2: loaders free the whole parsed
// config): reload cycles with writes leak nothing under the tracker.
@(test)
test_tui_reload_cycles_do_not_leak :: proc(t: ^testing.T) {
	sb := sandbox_open(t, "wayu-test-tui-reload-cycles")
	defer sandbox_close(&sb)
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)
	for i in 0 ..< 5 {
		for v in ([]wayu.TUIView {
				.PATH_VIEW,
				.ALIAS_VIEW,
				.CONSTANTS_VIEW,
				.BACKUPS_VIEW,
				.PLUGINS_VIEW,
				.HOOKS_VIEW,
				.SETTINGS_VIEW,
			}) {
			state.current_view = v
			wayu.tui_ensure_data_loaded(&state, v)
		}
		fill_form(&state, .CONSTANTS_VIEW, fmt.tprintf("C_%d", i), "x")
		wayu.execute_add_form(&state)
		wayu.tui_reload_all(&state)
	}
	testing.expect(t, strings.contains(read_text(sb.entries), "C_4"), "writes happened")
}

// OKAMI-260: an external entries.json edit drops the caches; r reloads.
@(test)
test_tui_reloads_external_edits :: proc(t: ^testing.T) {
	sb := sandbox_open(t, "wayu-test-tui-external")
	defer sandbox_close(&sb)
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)
	wayu.tui_watch_sync(&state)
	state.current_view = .ALIAS_VIEW
	wayu.tui_ensure_data_loaded(&state, .ALIAS_VIEW)
	testing.expect(t, cache_has(&state, .ALIAS_VIEW, "gs"), "loaded")

	edited, _ := strings.replace_all(
		LOADER_ENTRIES,
		`{"name": "gs", "value": "git status"}`,
		`{"name": "ext_added", "value": "echo external"}`,
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file(sb.entries, transmute([]byte)edited) == nil)
	testing.expect(t, wayu.tui_check_external_changes(&state, force = true), "change detected")
	wayu.tui_ensure_data_loaded(&state, .ALIAS_VIEW)
	testing.expect(t, cache_has(&state, .ALIAS_VIEW, "ext_added"), "new alias shown")
	testing.expect(t, !cache_has(&state, .ALIAS_VIEW, "gs"), "removed alias gone")
	testing.expect(
		t,
		!wayu.tui_check_external_changes(&state, force = true),
		"no change, no reload",
	)

	press(&state, .Char, 'r')
	testing.expect(t, state.data_cache[.ALIAS_VIEW] == nil, "r drops the cache")
}

// OKAMI-266: the Backups view lists every backup group; Enter restores an
// entries.json backup after confirmation; c prunes every group to 5.
@(test)
test_tui_backups_restore_and_cleanup :: proc(t: ^testing.T) {
	sb := sandbox_open(t, "wayu-test-tui-backups")
	defer sandbox_close(&sb)
	for i in 0 ..< 7 {
		path := fmt.tprintf(
			"%s/backup/entries.json.backup.2025-01-0%d_00-00-00.000000",
			sb.dir,
			i + 1,
		)
		body := strings.concatenate(
			{`{"version": 1, "aliases": [{"name": "old`, fmt.tprint(i), `", "value": "x"}]}`},
			context.temp_allocator,
		)
		testing.expect(t, os.write_entire_file(path, transmute([]byte)body) == nil)
	}
	testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/backup/plugins.json.backup.2025-01-01_00-00-00.000000", sb.dir),
			transmute([]byte)string("{}"),
		) ==
		nil,
	)

	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)
	state.current_view = .BACKUPS_VIEW
	wayu.tui_ensure_data_loaded(&state, .BACKUPS_VIEW)
	testing.expectf(
		t,
		len(state.row_meta[.BACKUPS_VIEW]) == 9,
		"8 entries.json + 1 plugins.json backups (got %d)",
		len(state.row_meta[.BACKUPS_VIEW]),
	)
	testing.expect_value(t, state.row_meta[.BACKUPS_VIEW][0].value, wayu.ENTRIES_FILE)

	press(&state, .Char, 'c')
	testing.expect(
		t,
		state.delete_confirm.pending && state.delete_confirm.kind == .CLEANUP,
		"c asks first",
	)
	press(&state, .Char, 'y')
	testing.expect(
		t,
		strings.has_prefix(state.notify.message, "Removed 3 old backup(s)"),
		state.notify.message,
	)
	backups := wayu.list_backups_for_file(sb.entries)
	testing.expect_value(t, len(backups), wayu.BACKUP_KEEP_COUNT)
	wayu.free_backup_infos(backups)

	// Newest entries.json backup is the 2026 one from the sandbox (row 0).
	wayu.tui_ensure_data_loaded(&state, .BACKUPS_VIEW)
	state.selected_index = 0
	CHANGED :: `{"version": 1, "aliases": [{"name": "changed", "value": "y"}]}`
	testing.expect(t, os.write_entire_file(sb.entries, transmute([]byte)string(CHANGED)) == nil)
	press(&state, .Enter)
	testing.expect(
		t,
		state.delete_confirm.pending && state.delete_confirm.kind == .RESTORE,
		"Enter asks to restore",
	)
	testing.expect_value(t, read_text(sb.entries), CHANGED)
	press(&state, .Char, 'y')
	testing.expect(
		t,
		strings.has_prefix(state.notify.message, "Restored entries.json"),
		state.notify.message,
	)
	testing.expect_value(t, read_text(sb.entries), LOADER_ENTRIES)
}

// OKAMI-264: cursor editing in the form, 'e' edits in place, 'u' offers undo.
@(test)
test_tui_form_editing_and_edit_action :: proc(t: ^testing.T) {
	sb := sandbox_open(t, "wayu-test-tui-editing")
	defer sandbox_close(&sb)
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)

	wayu.show_add_form(&state, .ALIAS_VIEW)
	type_into(&state, "helo")
	wayu.handle_add_form_input(&state, {key = .Left})
	type_into(&state, "l")
	testing.expect_value(t, string(state.add_form.input_0[:]), "hello")
	wayu.handle_add_form_input(&state, {key = .Home})
	type_into(&state, "x")
	wayu.handle_add_form_input(&state, {key = .Delete})
	testing.expect_value(t, string(state.add_form.input_0[:]), "xello")
	wayu.handle_add_form_input(&state, {key = .End})
	type_into(&state, " two words")
	wayu.handle_add_form_input(&state, {key = .Char, char = 'w', modifiers = {.Ctrl}})
	testing.expect_value(t, string(state.add_form.input_0[:]), "xello two ")
	wayu.handle_add_form_input(&state, {key = .Char, char = 'u', modifiers = {.Ctrl}})
	testing.expect_value(t, len(state.add_form.input_0), 0)
	wayu.clear_add_form(&state)

	// e on alias gs: rename to gst (old name removed, value kept).
	state.current_view = .ALIAS_VIEW
	wayu.tui_ensure_data_loaded(&state, .ALIAS_VIEW)
	for m, i in state.row_meta[.ALIAS_VIEW] do if m.key == "gs" do state.selected_index = i
	press(&state, .Char, 'e')
	testing.expect(
		t,
		state.add_form.active && state.add_form.edit_key == "gs",
		"edit form prefilled",
	)
	testing.expect_value(t, string(state.add_form.input_1[:]), "git status")
	state.add_form.field_index = 0
	state.add_form.cursor_0 = len(state.add_form.input_0)
	type_into(&state, "t")
	wayu.handle_add_form_input(&state, {key = .Enter})
	store := read_text(sb.entries)
	testing.expectf(
		t,
		strings.contains(store, `{"name": "gst", "value": "git status"}`) &&
		!strings.contains(store, `"name": "gs"`),
		"renamed:\n%s",
		store,
	)

	// PATH edit keeps the key and position.
	wayu.show_edit_form(&state, .PATH_VIEW, "/nonexistent/wayu-tui-loader", "")
	clear(&state.add_form.input_0)
	append(&state.add_form.input_0, ..transmute([]u8)sb.dir)
	wayu.execute_add_form(&state)
	store = read_text(sb.entries)
	testing.expectf(
		t,
		strings.contains(
			store,
			strings.concatenate(
				{`{"key": "missing", "dir": "`, sb.dir, `"}`},
				context.temp_allocator,
			),
		),
		"path edited in place:\n%s",
		store,
	)
	testing.expect(
		t,
		strings.index(store, `"key": "bin"`) < strings.index(store, `"key": "missing"`),
		"order kept",
	)

	// u offers to restore the newest entries.json backup.
	state.current_view = .ALIAS_VIEW
	press(&state, .Char, 'u')
	testing.expect(
		t,
		state.delete_confirm.pending && state.delete_confirm.kind == .RESTORE,
		"u asks to restore",
	)
	press(&state, .Escape)
}

// OKAMI-267: no negative scroll on tiny terminals; "too small" guard;
// the filter footer doesn't advertise j/k (they type into the filter).
@(test)
test_tui_tiny_terminal_selection :: proc(t: ^testing.T) {
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)
	state.current_view = .COMPLETIONS_VIEW
	rows := make([dynamic]string)
	meta := make([dynamic]wayu.RowMeta)
	for s in ([]string{"a", "b", "c"}) do wayu.cache_push(&rows, &meta, strings.clone(s), s)
	wayu.tui_store_cache(&state, .COMPLETIONS_VIEW, rows, meta)
	state.terminal_width, state.terminal_height = 60, 6
	wayu.tui_state_move_selection(&state, 1, 3)
	wayu.tui_state_move_selection(&state, 1, 3)
	testing.expect_value(t, state.selected_index, 2)
	testing.expect_value(t, state.scroll_offset, 2)
	testing.expect(t, wayu.tui_too_small(&state), "below the minimum")
	state.terminal_height = 24
	testing.expect(t, !wayu.tui_too_small(&state), "normal size")
	testing.expect(
		t,
		!strings.contains(wayu.FOOTER_FILTER_ACTIVE, "j/k"),
		"filter footer must not advertise j/k",
	)
}

// OKAMI-183: hooks view rows, enable/disable through hooks.conf, test-run.
@(test)
test_tui_hooks_view :: proc(t: ^testing.T) {
	sb := sandbox_open(t, "wayu-test-tui-hooks")
	defer sandbox_close(&sb)
	conf := fmt.tprintf("%s/hooks.conf", sb.dir)
	testing.expect(
		t,
		os.write_entire_file(
			conf,
			transmute([]byte)string("# my hooks\npre_alias_add = echo adding {name}\n"),
		) ==
		nil,
	)

	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)
	state.current_view = .HOOKS_VIEW
	wayu.tui_ensure_data_loaded(&state, .HOOKS_VIEW)
	testing.expect_value(t, len(state.hooks.rows), 16)
	testing.expect_value(t, wayu.get_view_item_count(&state), 16)
	idx := -1
	for r, i in state.hooks.rows do if r.key == "pre_alias_add" do idx = i
	testing.expect(
		t,
		idx >= 0 && state.hooks.rows[idx].command == "echo adding {name}",
		"configured hook listed",
	)
	state.selected_index = idx

	press(&state, .Char, 't')
	testing.expect(t, state.detail.shown, "test-run shows its result")
	found := false
	for l in state.detail.lines do if strings.contains(l, "adding wayu_hook_test") do found = true
	testing.expect(t, found, "hook output shown")
	press(&state, .Escape)

	press(&state, .Char, ' ')
	testing.expect(
		t,
		strings.contains(read_text(conf), "# disabled: pre_alias_add = echo adding {name}"),
		read_text(conf),
	)
	wayu.tui_ensure_data_loaded(&state, .HOOKS_VIEW)
	testing.expect(t, state.hooks.rows[idx].disabled, "shown as disabled")
	cfg := wayu.load_hook_config()
	testing.expect_value(t, cfg.pre_alias_add, "")
	wayu.free_hook_config(cfg)

	press(&state, .Char, ' ')
	testing.expect(
		t,
		strings.contains(read_text(conf), "\npre_alias_add = echo adding {name}"),
		read_text(conf),
	)
}

// OKAMI-184: settings rows, session toggles.
@(test)
test_tui_settings_view :: proc(t: ^testing.T) {
	sb := sandbox_open(t, "wayu-test-tui-settings")
	defer sandbox_close(&sb)
	state := wayu.tui_state_init()
	defer wayu.tui_state_destroy(&state)
	state.current_view = .SETTINGS_VIEW
	wayu.tui_ensure_data_loaded(&state, .SETTINGS_VIEW)
	rows := wayu.SETTING_ROWS
	testing.expect_value(t, wayu.get_view_item_count(&state), len(rows))
	// OKAMI-357: the data dir (entries.json, generated files) has a row.
	has_data_dir := false
	for id in rows do if id == .DATA_DIR {
		label, value, toggles := wayu.setting_row(&state, id)
		has_data_dir = label == "Data dir" && value == wayu.wayu.data && !toggles
	}
	testing.expect(t, has_data_dir, "settings show the data dir")
	for id, i in rows do if id == .DRY_RUN do state.selected_index = i
	press(&state, .Enter)
	testing.expect(t, wayu.wayu.dry_run, "Enter turns dry-run on for the session")
	press(&state, .Enter)
	testing.expect(t, !wayu.wayu.dry_run, "and off again")
}
