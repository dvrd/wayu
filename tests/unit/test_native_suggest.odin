package test_wayu

import wayu "../../src"
import "core:testing"

@(test)
test_explicit_suggestion_setting_overrides_legacy_key :: proc(t: ^testing.T) {
	cfg := wayu.Native_Suggest_Config {
		enabled = true,
	}
	wayu.native_suggest_configure(
		&cfg,
		"[settings]\nautosuggest = true\n[autosuggest]\nenabled = false\n",
	)
	testing.expect(t, !cfg.enabled)
}
