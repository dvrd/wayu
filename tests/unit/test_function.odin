package test_wayu

import wayu "../../src"
import "core:strings"
import "core:testing"

@(test)
test_fish_function_skeleton_delimiters :: proc(t: ^testing.T) {
	saved := wayu.wayu.shell
	defer wayu.wayu.shell = saved

	wayu.wayu.shell = .FISH
	body := wayu.function_skeleton("jump")
	defer delete(body)

	testing.expect(t, strings.contains(body, "\nfunction jump\n"))
	testing.expect(t, strings.has_suffix(body, "\nend\n"))
}
