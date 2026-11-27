package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_quoted_operator_stays_in_word :: proc(t: ^testing.T) {
	parts := wayu.shell_parse_statements(`echo "a|b"|cat`, .POSIX)
	defer wayu.shell_statements_destroy(&parts)

	testing.expect_value(t, len(parts), 1)
	if len(parts) != 1 do return
	tokens := parts[0].tokens
	testing.expect_value(t, len(tokens), 4)
	if len(tokens) != 4 do return
	testing.expect_value(t, tokens[1].word.text, "a|b")
	testing.expect_value(t, tokens[2].op, "|")
}
