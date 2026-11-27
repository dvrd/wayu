package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_scan_short_confirmation_flags :: proc(t: ^testing.T) {
	fix, preview, yes := wayu.extract_scan_flags({"--fix", "-n", "-y"})
	testing.expect(t, fix && preview && yes)
}
