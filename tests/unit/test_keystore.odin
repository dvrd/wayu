package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_reject_unknown_backend :: proc(t: ^testing.T) {
	backend, ok := wayu.secrets_backend_parse("file")
	testing.expect(t, ok && backend == .FILE)
	_, typo := wayu.secrets_backend_parse("files")
	testing.expect(t, !typo)
}
