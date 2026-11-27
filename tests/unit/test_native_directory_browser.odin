package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_warp_filter_and_tie_order :: proc(t: ^testing.T) {
	visits := make(map[string]wayu.Native_Dir_Visit)
	defer delete(visits)

	visits["/B/dev"] = {2, 0}
	visits["/A/Dev"] = {2, 0}
	visits["/tmp"] = {4, 0}

	rows := wayu.warp_rows(visits, {"dev"})
	testing.expect_value(t, len(rows), 2)
	if len(rows) == 2 {
		testing.expect_value(t, rows[0].dir, "/A/Dev")
		testing.expect_value(t, rows[1].dir, "/B/dev")
	}
}
