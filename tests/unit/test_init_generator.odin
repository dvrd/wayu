package test_wayu

import wayu "../../src"
import "core:os"
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
