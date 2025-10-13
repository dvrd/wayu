package test_wayu

import "core:testing"
import wayu "../src"

@(test)
test_debug_function :: proc(t: ^testing.T) {
	// Test that debug function doesn't crash
	// When DEBUG is not defined, debug() should be a no-op
	wayu.debug("test message")
	wayu.debug("test with args: %s %d", "value", 42)
	testing.expect(t, true, "debug should not crash")
}
