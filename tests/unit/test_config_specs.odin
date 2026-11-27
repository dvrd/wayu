package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_path_spec_validates_format :: proc(t: ^testing.T) {
	testing.expect(t, wayu.validate_path_entry({name = test_tmp("uncreated-path")}).valid)
	invalid := wayu.validate_path_entry({name = ""})
	defer delete(invalid.error_message)

	testing.expect(t, !invalid.valid)
}
