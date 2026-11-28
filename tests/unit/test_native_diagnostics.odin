package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_native_source_lines :: proc(t: ^testing.T) {
	s := wayu.Native_Session {
		location = {"setup.wy", 15},
	}
	source := "# skip\n\nprintf 'first\nsecond' |\n  false"
	stmts := wayu.shell_parse_statements(source, .POSIX, true)
	defer wayu.shell_statements_destroy(&stmts)

	parser := wayu.native_parser(&s, source, stmts[:])
	nodes := wayu.native_list(&parser)
	testing.expect_value(t, parser.err, "")
	testing.expect_value(t, len(nodes), 1)
	testing.expect_value(t, nodes[0].line, 17)
	testing.expect_value(t, nodes[0].pipelines[0].commands[1].line, 19)
}
