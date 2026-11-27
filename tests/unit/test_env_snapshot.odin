package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_fish_snapshot_adjacent_quotes :: proc(t: ^testing.T) {
	decoded := wayu.fish_unquote_word(`'two words'"/bin"`)
	defer delete(decoded)

	testing.expect_value(t, decoded, "two words/bin")
}
