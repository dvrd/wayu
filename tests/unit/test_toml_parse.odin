package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_duplicate_key_reports_second_line :: proc(t: ^testing.T) {
	ok, problem := wayu.toml_check("key=1\nkey=2\n")
	defer delete(problem.msg)

	testing.expect(t, !ok)
	testing.expect_value(t, problem.line, 2)
}
