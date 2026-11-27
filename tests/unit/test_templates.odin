package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_template_requires_exact_name :: proc(t: ^testing.T) {
	testing.expect(t, wayu.template_exists("developer"))
	testing.expect(t, !wayu.template_exists("dev"))
}
