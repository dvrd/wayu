package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_bech32_mixed_case :: proc(t: ^testing.T) {
	_, _, valid := wayu.bech32_decode("A12uEL5L")
	testing.expect(t, !valid)
}
