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
