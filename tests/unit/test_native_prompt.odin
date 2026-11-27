package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_prompt_cache_invalidated_by_branch :: proc(t: ^testing.T) {
	cache := wayu.Native_Prompt_Cache {
		pwd    = "/repo",
		branch = "develop",
	}
	v := wayu.Native_Prompt_Values {
		pwd    = "/repo",
		branch = "develop",
	}
	testing.expect(t, wayu.native_prompt_cache_matches(&cache, v))
	v.branch = "topic"
	testing.expect(t, !wayu.native_prompt_cache_matches(&cache, v))
}
