package test_wayu

import wayu "../../src"
import "core:slice"
import "core:testing"

@(test)
test_managed_function_preserves_arguments :: proc(t: ^testing.T) {
	argv := wayu.native_function_args({"bash", "/tmp/a b.bash"}, {"hello", "", "a b"})
	testing.expect(
		t,
		len(argv) >= 4 &&
		slice.equal(argv[len(argv) - 4:], []string{"/tmp/a b.bash", "hello", "", "a b"}),
	)
}
