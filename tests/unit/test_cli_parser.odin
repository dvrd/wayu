package test_wayu

import wayu "../../src"
import "core:slice"
import "core:testing"

@(test)
test_alias_remove_preserves_operand :: proc(t: ^testing.T) {
	args := wayu.parse_args({"alias", "rm", "gs"})
	defer delete(args.args)

	testing.expect_value(t, args.action, wayu.Action.REMOVE)
	testing.expect(t, slice.equal(args.args[:], []string{"gs"}))
}
