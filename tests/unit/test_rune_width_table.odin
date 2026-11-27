package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_rune_width_ranges_ordered_for_lookup :: proc(t: ^testing.T) {
	zero := wayu.RUNE_WIDTH_ZERO
	wide := wayu.RUNE_WIDTH_WIDE
	for ranges in ([][][2]rune{zero[:], wide[:]}) {
		for interval, i in ranges {
			testing.expect(t, interval[0] <= interval[1])
			if i > 0 {
				testing.expect(t, ranges[i - 1][1] < interval[0])
			}
		}
	}
}
