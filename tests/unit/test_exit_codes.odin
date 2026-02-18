package test_wayu

import "core:testing"
import wayu "../../src"

// ============================================================================
// Exit Code Constants Tests
// ============================================================================

@(test)
test_exit_code_constants_values :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.EXIT_SUCCESS, 0)
	testing.expect_value(t, wayu.EXIT_GENERAL, 1)
	testing.expect_value(t, wayu.EXIT_USAGE, 64)
	testing.expect_value(t, wayu.EXIT_DATAERR, 65)
	testing.expect_value(t, wayu.EXIT_NOINPUT, 66)
	testing.expect_value(t, wayu.EXIT_CANTCREAT, 73)
	testing.expect_value(t, wayu.EXIT_IOERR, 74)
	testing.expect_value(t, wayu.EXIT_NOPERM, 77)
	testing.expect_value(t, wayu.EXIT_CONFIG, 78)
}

// ============================================================================
// error_to_exit_code Mapping Tests
// ============================================================================

@(test)
test_error_to_exit_code_file_not_found :: proc(t: ^testing.T) {
	code := wayu.error_to_exit_code(.FILE_NOT_FOUND)
	testing.expect_value(t, code, 66) // EXIT_NOINPUT
}

@(test)
test_error_to_exit_code_permission_denied :: proc(t: ^testing.T) {
	code := wayu.error_to_exit_code(.PERMISSION_DENIED)
	testing.expect_value(t, code, 77) // EXIT_NOPERM
}

@(test)
test_error_to_exit_code_file_read_error :: proc(t: ^testing.T) {
	code := wayu.error_to_exit_code(.FILE_READ_ERROR)
	testing.expect_value(t, code, 74) // EXIT_IOERR
}

@(test)
test_error_to_exit_code_file_write_error :: proc(t: ^testing.T) {
	code := wayu.error_to_exit_code(.FILE_WRITE_ERROR)
	testing.expect_value(t, code, 74) // EXIT_IOERR
}

@(test)
test_error_to_exit_code_invalid_input :: proc(t: ^testing.T) {
	code := wayu.error_to_exit_code(.INVALID_INPUT)
	testing.expect_value(t, code, 65) // EXIT_DATAERR
}

@(test)
test_error_to_exit_code_config_not_init :: proc(t: ^testing.T) {
	code := wayu.error_to_exit_code(.CONFIG_NOT_INITIALIZED)
	testing.expect_value(t, code, 78) // EXIT_CONFIG
}

@(test)
test_error_to_exit_code_dir_not_found :: proc(t: ^testing.T) {
	code := wayu.error_to_exit_code(.DIRECTORY_NOT_FOUND)
	testing.expect_value(t, code, 66) // EXIT_NOINPUT
}
