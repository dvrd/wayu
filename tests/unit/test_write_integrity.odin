// test_write_integrity.odin - atomic write regressions
// (OKAMI-201 CFG-04, OKAMI-202 CFG-01, OKAMI-203 CFG-03/PLG-14/GEN-25).

package test_wayu

import wayu "../../src"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// write_file_atomic
// ---------------------------------------------------------------------------

@(private = "file")
count_tmp_leftovers :: proc(dir: string) -> int {
	f, err := os.open(dir)
	if err != nil {
		return -1
	}
	defer os.close(f)
	infos, rerr := os.read_dir(f, -1, context.temp_allocator)
	if rerr != nil {
		return -1
	}
	n := 0
	for fi in infos {
		if strings.contains(fi.name, ".tmp.") {
			n += 1
		}
	}
	return n
}

@(test)
test_write_file_atomic_creates_and_replaces :: proc(t: ^testing.T) {
	dir := test_tmp("wayu-test-atomic-basic")
	os.remove_all(dir)
	os.make_directory(dir)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/f.txt", dir)

	testing.expect_value(t, wayu.write_file_atomic(path, transmute([]byte)string("one")), nil)
	testing.expect_value(t, wayu.write_file_atomic(path, transmute([]byte)string("two")), nil)
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(data), "two")
	testing.expect_value(t, count_tmp_leftovers(dir), 0)
}

@(test)
test_write_file_atomic_preserves_mode :: proc(t: ^testing.T) {
	dir := test_tmp("wayu-test-atomic-mode")
	os.remove_all(dir)
	os.make_directory(dir)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/secret.toml", dir)

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
	dir := test_tmp("wayu-test-atomic-newmode")
	os.remove_all(dir)
	os.make_directory(dir)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/core.zsh", dir)

	testing.expect_value(t, wayu.write_file_atomic(path, transmute([]byte)string("x")), nil)
	fi, err := os.stat(path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, fi.mode, os.perm_number(0o600))
}

// Regression: the CLI's fixed 256KB temp arena can be exhausted by the time
// the generators write (large configs); the helper must not depend on it.
@(test)
test_write_file_atomic_survives_exhausted_temp_allocator :: proc(t: ^testing.T) {
	dir := test_tmp("wayu-test-atomic-arena")
	os.remove_all(dir)
	os.make_directory(dir)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/core.zsh", dir)

	context.temp_allocator = mem.panic_allocator()
	testing.expect_value(t, wayu.write_file_atomic(path, transmute([]byte)string("ok")), nil)
	data, _ := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect_value(t, string(data), "ok")
}

@(test)
test_write_file_atomic_follows_symlink :: proc(t: ^testing.T) {
	dir := test_tmp("wayu-test-atomic-link")
	os.remove_all(dir)
	os.make_directory(dir)
	defer os.remove_all(dir)
	real := fmt.tprintf("%s/real.toml", dir)
	link := fmt.tprintf("%s/wayu.toml", dir)

	testing.expect_value(t, wayu.write_file_atomic(real, transmute([]byte)string("old")), nil)
	testing.expect_value(t, os.symlink("real.toml", link), nil) // relative target
	testing.expect_value(t, wayu.write_file_atomic(link, transmute([]byte)string("new")), nil)

	lfi, lerr := os.lstat(link, context.temp_allocator)
	testing.expect_value(t, lerr, nil)
	testing.expect_value(t, lfi.type, os.File_Type.Symlink)
	data, _ := os.read_entire_file(real, context.temp_allocator)
	testing.expect_value(t, string(data), "new")
}
