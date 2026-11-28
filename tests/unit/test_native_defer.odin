package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_deferred_arguments_round_trip :: proc(t: ^testing.T) {
	session: wayu.Native_Session
	defer delete(session.deferred)

	args := []string{"echo", "", "two words", "$HOME", "a'b", "x; exit 42"}
	testing.expect_value(t, wayu.native_register_defer(&session, args, nil), 0)
	cleanup := session.deferred[0]
	defer delete(cleanup.command)

	defer delete(cleanup.location.path)

	tokens := wayu.shell_parse_statements(cleanup.command, .POSIX, true)
	defer wayu.shell_statements_destroy(&tokens)

	testing.expect_value(t, len(tokens), 1)
	testing.expect_value(t, len(tokens[0].tokens), len(args))
	for arg, i in args {
		testing.expect_value(t, tokens[0].tokens[i].word.text, arg)
	}
}
