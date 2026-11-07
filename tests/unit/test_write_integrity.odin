// test_write_integrity.odin - TOML table editor + atomic write regressions
// (OKAMI-201 CFG-04, OKAMI-202 CFG-01, OKAMI-203 CFG-03/PLG-14/GEN-25).

package test_wayu

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import wayu "../../src"

// ---------------------------------------------------------------------------
// toml_table_set / toml_table_delete
// ---------------------------------------------------------------------------

// A [paths] table in deliberate non-alphabetical (precedence) order.
@(private = "file")
PATHS_DOC :: `[shell]
type = "zsh"

[paths]
zz_brew = "/opt/homebrew/bin" # first!
aa_sys = "/usr/bin"

[env]
A = "1"
`

@(test)
test_table_set_appends_new_key_in_place :: proc(t: ^testing.T) {
	out, existed, bad := wayu.toml_table_set(PATHS_DOC, "paths", "mid", `mid = "/mid"`)
	defer delete(out)
	testing.expect_value(t, bad, 0)
	testing.expect(t, !existed)
	expected := `[shell]
type = "zsh"

[paths]
zz_brew = "/opt/homebrew/bin" # first!
aa_sys = "/usr/bin"
mid = "/mid"

[env]
A = "1"
`
	testing.expect_value(t, out, expected)
}

@(test)
test_table_set_replaces_existing_key_keeps_comment_and_position :: proc(t: ^testing.T) {
	out, existed, bad := wayu.toml_table_set(PATHS_DOC, "paths", "zz_brew", `zz_brew = "/new"`)
	defer delete(out)
	testing.expect_value(t, bad, 0)
	testing.expect(t, existed)
	testing.expect(t, strings.contains(out, "[paths]\nzz_brew = \"/new\" # first!\naa_sys = \"/usr/bin\"\n"),
		"replaced entry must stay first and keep its inline comment")
}

@(test)
test_table_delete_keeps_order_and_comments :: proc(t: ^testing.T) {
	out, removed, bad := wayu.toml_table_delete(PATHS_DOC, "paths", {"aa_sys"})
	defer delete(out)
	testing.expect_value(t, bad, 0)
	testing.expect_value(t, removed, 1)
	testing.expect(t, strings.contains(out, "[paths]\nzz_brew = \"/opt/homebrew/bin\" # first!\n\n[env]"))
}

@(test)
test_table_set_missing_table_is_appended :: proc(t: ^testing.T) {
	out, existed, bad := wayu.toml_table_set("[shell]\ntype = \"zsh\"\n", "aliases", "ll", `ll = "ls -l"`)
	defer delete(out)
	testing.expect_value(t, bad, 0)
	testing.expect(t, !existed)
	testing.expect_value(t, out, "[shell]\ntype = \"zsh\"\n\n[aliases]\nll = \"ls -l\"\n")
}

@(test)
test_table_set_header_with_comment :: proc(t: ^testing.T) {
	content := "[env]  # my vars\n# keep me\nA = \"1\"\n\n[paths]\nx = \"/x\"\n"
	out, _, bad := wayu.toml_table_set(content, "env", "B", `B = "2"`)
	defer delete(out)
	testing.expect_value(t, bad, 0)
	testing.expect_value(t, out, "[env]  # my vars\n# keep me\nA = \"1\"\nB = \"2\"\n\n[paths]\nx = \"/x\"\n")
	testing.expect(t, wayu.toml_content_is_sane(out), "edited TOML must stay sane")
}

// Values wayu doesn't model (multi-line strings, arrays, ints) must survive
// any unrelated edit byte-for-byte.
@(private = "file")
RICH_ENV :: `[env]
# certificate
CERT = """
-----BEGIN-----
abc=
[not-a-header]
-----END-----"""
LIT = '''
raw = "x"
'''
LIST = [
  "a", # one
  ["nested"],
]
N = 42
`

@(test)
test_table_set_preserves_multiline_arrays_ints :: proc(t: ^testing.T) {
	out, existed, bad := wayu.toml_table_set(RICH_ENV, "env", "NEWV", `NEWV = "1"`)
	defer delete(out)
	testing.expect_value(t, bad, 0)
	testing.expect(t, !existed, "continuation lines like `abc=` / `raw = \"x\"` are not keys")
	testing.expect_value(t, out, fmt.tprintf("%sNEWV = \"1\"\n", RICH_ENV))
}

@(test)
test_table_set_does_not_match_keys_inside_multiline_values :: proc(t: ^testing.T) {
	out, existed, bad := wayu.toml_table_set(RICH_ENV, "env", "raw", `raw = "y"`)
	defer delete(out)
	testing.expect_value(t, bad, 0)
	testing.expect(t, !existed)
	testing.expect(t, strings.contains(out, "LIT = '''\nraw = \"x\"\n'''"), "literal block must be untouched")
}

@(test)
test_table_delete_removes_whole_multiline_entry :: proc(t: ^testing.T) {
	out, removed, bad := wayu.toml_table_delete(RICH_ENV, "env", {"CERT", "LIST"})
	defer delete(out)
	testing.expect_value(t, bad, 0)
	testing.expect_value(t, removed, 2)
	testing.expect_value(t, out, "[env]\n# certificate\nLIT = '''\nraw = \"x\"\n'''\nN = 42\n")
}

@(test)
test_table_replace_multiline_entry :: proc(t: ^testing.T) {
	out, existed, bad := wayu.toml_table_set(RICH_ENV, "env", "LIST", `LIST = "flat"`)
	defer delete(out)
	testing.expect_value(t, bad, 0)
	testing.expect(t, existed)
	testing.expect(t, strings.contains(out, "]\nLIST = \"flat\"\nN = 42\n") == false)
	testing.expect(t, strings.contains(out, "'''\nLIST = \"flat\"\nN = 42\n"), "all array lines replaced by one")
}

@(test)
test_table_edit_rejects_unterminated_value :: proc(t: ^testing.T) {
	content := "[env]\nA = \"1\"\nX = \"\"\"\nnever closed\n[paths]\np = \"/p\"\n"
	out, _, bad := wayu.toml_table_set(content, "env", "B", `B = "2"`)
	testing.expect_value(t, bad, 3)
	testing.expect_value(t, out, "")
	out2, removed, bad2 := wayu.toml_table_delete(content, "env", {"A"})
	testing.expect_value(t, bad2, 3)
	testing.expect_value(t, removed, 0)
	testing.expect_value(t, out2, "")
}

@(test)
test_table_edit_ignores_other_sections :: proc(t: ^testing.T) {
	content := "[aliases]\nA = \"x\"\n\n[env]\nA = \"1\"\n"
	out, removed, _ := wayu.toml_table_delete(content, "env", {"A"})
	defer delete(out)
	testing.expect_value(t, removed, 1)
	testing.expect_value(t, out, "[aliases]\nA = \"x\"\n\n[env]\n")
}

// ---------------------------------------------------------------------------
// write_file_atomic
// ---------------------------------------------------------------------------

@(private = "file")
count_tmp_leftovers :: proc(dir: string) -> int {
	f, err := os.open(dir)
	if err != nil { return -1 }
	defer os.close(f)
	infos, rerr := os.read_dir(f, -1, context.temp_allocator)
	if rerr != nil { return -1 }
	n := 0
	for fi in infos {
		if strings.contains(fi.name, ".tmp.") { n += 1 }
	}
	return n
}

@(test)
test_write_file_atomic_creates_and_replaces :: proc(t: ^testing.T) {
	dir :: "/tmp/wayu-test-atomic-basic"
	os.remove_all(dir)
	os.make_directory(dir)
	defer os.remove_all(dir)
	path := dir + "/f.txt"

	testing.expect_value(t, wayu.write_file_atomic(path, transmute([]byte)string("one")), nil)
	testing.expect_value(t, wayu.write_file_atomic(path, transmute([]byte)string("two")), nil)
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(data), "two")
	testing.expect_value(t, count_tmp_leftovers(dir), 0)
}

@(test)
test_write_file_atomic_preserves_mode :: proc(t: ^testing.T) {
	dir :: "/tmp/wayu-test-atomic-mode"
	os.remove_all(dir)
	os.make_directory(dir)
	defer os.remove_all(dir)
	path := dir + "/secret.toml"

	testing.expect_value(t, wayu.write_file_atomic(path, transmute([]byte)string("a")), nil)
	testing.expect_value(t, os.chmod(path, os.perm_number(0o600)), nil)
	testing.expect_value(t, wayu.write_file_atomic(path, transmute([]byte)string("b")), nil)

	fi, err := os.stat(path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, fi.mode, os.perm_number(0o600))

	// A looser existing mode is kept too (the helper never changes it).
	testing.expect_value(t, os.chmod(path, os.perm_number(0o640)), nil)
	testing.expect_value(t, wayu.write_file_atomic(path, transmute([]byte)string("c")), nil)
	fi2, _ := os.stat(path, context.temp_allocator)
	testing.expect_value(t, fi2.mode, os.perm_number(0o640))
}

// New files default to 0600: wayu.toml / generated files may hold secrets.
@(test)
test_write_file_atomic_new_file_is_0600 :: proc(t: ^testing.T) {
	dir :: "/tmp/wayu-test-atomic-newmode"
	os.remove_all(dir)
	os.make_directory(dir)
	defer os.remove_all(dir)
	path := dir + "/core.zsh"

	testing.expect_value(t, wayu.write_file_atomic(path, transmute([]byte)string("x")), nil)
	fi, err := os.stat(path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, fi.mode, os.perm_number(0o600))
}

// Regression: the CLI's fixed 256KB temp arena can be exhausted by the time
// the generators write (large configs); the helper must not depend on it.
@(test)
test_write_file_atomic_survives_exhausted_temp_allocator :: proc(t: ^testing.T) {
	dir :: "/tmp/wayu-test-atomic-arena"
	os.remove_all(dir)
	os.make_directory(dir)
	defer os.remove_all(dir)
	path := dir + "/core.zsh"

	context.temp_allocator = mem.panic_allocator()
	testing.expect_value(t, wayu.write_file_atomic(path, transmute([]byte)string("ok")), nil)
	data, _ := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect_value(t, string(data), "ok")
}

@(test)
test_write_file_atomic_follows_symlink :: proc(t: ^testing.T) {
	dir :: "/tmp/wayu-test-atomic-link"
	os.remove_all(dir)
	os.make_directory(dir)
	defer os.remove_all(dir)
	real := dir + "/real.toml"
	link := dir + "/wayu.toml"

	testing.expect_value(t, wayu.write_file_atomic(real, transmute([]byte)string("old")), nil)
	testing.expect_value(t, os.symlink("real.toml", link), nil) // relative target
	testing.expect_value(t, wayu.write_file_atomic(link, transmute([]byte)string("new")), nil)

	lfi, lerr := os.lstat(link, context.temp_allocator)
	testing.expect_value(t, lerr, nil)
	testing.expect_value(t, lfi.type, os.File_Type.Symlink)
	data, _ := os.read_entire_file(real, context.temp_allocator)
	testing.expect_value(t, string(data), "new")
}
