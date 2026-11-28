package test_wayu

import wayu "../../src"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_custom_init_template_preserved :: proc(t: ^testing.T) {
	testing.expect(t, !wayu.is_known_init_template("# user startup\nsource ./custom.zsh\n"))
}

@(test)
test_publication_outcomes :: proc(t: ^testing.T) {
	dir := test_tmp("publication")
	_ = os.make_directory(dir)
	defer os.remove_all(dir)

	previous := wayu.wayu.data
	wayu.wayu.data = dir
	defer wayu.wayu.data = previous

	path := test_tmp("publication/core.bash")
	testing.expect_value(t, wayu.write_init_file(path, "text"), .Written)
	testing.expect_value(t, wayu.write_init_file(path, "text"), .Current)
	testing.expect_value(t, wayu.write_init_file(dir, "blocked"), .Failed)
	files: wayu.Shell_Publication
	testing.expect_value(t, files[.Turbo], .Skipped)
}

// Each required artifact reports its own state, so one that fails leaves the
// others' results intact for the per-shell report.
@(test)
test_publication_states_per_artifact :: proc(t: ^testing.T) {
	dir := test_tmp("publication-artifacts")
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)

	saved := wayu.wayu
	defer wayu.wayu = saved

	wayu.wayu.data = dir
	wayu.wayu.shell = .BASH
	wayu.wayu.shell_ext = "bash"
	wayu.wayu.dry_run = false

	// init.<ext>: absent, current, user-edited (kept byte for byte), not a file.
	init := fmt.tprintf("%s/init.bash", dir)
	template := wayu.get_init_template(.BASH)
	testing.expect_value(t, wayu.sync_init_orchestrator(), .Skipped)
	testing.expect(t, os.write_entire_file(init, template) == nil)
	testing.expect_value(t, wayu.sync_init_orchestrator(), .Current)
	custom := strings.concatenate({template, "\n# local edit\n"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(init, custom) == nil)
	testing.expect_value(t, wayu.sync_init_orchestrator(), .Skipped)
	kept, read_err := os.read_entire_file_from_path(init, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(kept), custom)
	wayu.wayu.dry_run = true
	testing.expect_value(t, wayu.sync_init_orchestrator(), .Skipped)
	wayu.wayu.dry_run = false
	testing.expect(t, os.remove(init) == nil)
	testing.expect(t, os.make_directory(init) == nil)
	testing.expect_value(t, wayu.sync_init_orchestrator(), .Failed)

	// turbo.<ext> follows the same written/current/failed states as core.
	turbo := fmt.tprintf("%s/turbo.bash", dir)
	testing.expect_value(t, wayu.write_turbo_file(turbo, "text"), .Written)
	testing.expect_value(t, wayu.write_turbo_file(turbo, "text"), .Current)
	testing.expect_value(t, wayu.write_turbo_file(turbo, "newer"), .Written)
	testing.expect(t, os.remove(turbo) == nil)
	testing.expect(t, os.make_directory(turbo) == nil)
	testing.expect_value(t, wayu.write_turbo_file(turbo, "text"), .Failed)

	// path_sync.<ext> is always rewritten, or fails.
	sync := fmt.tprintf("%s/path_sync.bash", dir)
	testing.expect_value(t, wayu.write_path_sync_file(), .Written)
	testing.expect_value(t, wayu.write_path_sync_file(), .Written)
	testing.expect(t, os.remove(sync) == nil)
	testing.expect(t, os.make_directory(sync) == nil)
	testing.expect_value(t, wayu.write_path_sync_file(), .Failed)

	// The report fails for the shell when any artifact failed, whatever the rest did.
	files: wayu.Shell_Publication
	files[.Core] = .Written
	files[.Path_Sync] = .Current
	testing.expect(t, wayu.publication_report(.BASH, files))
	files[.Turbo] = .Failed
	testing.expect(t, !wayu.publication_report(.BASH, files))
}
