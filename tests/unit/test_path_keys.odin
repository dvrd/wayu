// test_path_keys.odin - Unit tests for derive_path_key + sanitize_path_key.

package test_wayu

import "core:testing"
import wayu "../../src"

@(test)
test_sanitize_path_key_basic :: proc(t: ^testing.T) {
	cases := []struct{ input, want: string }{
		{"odin",       "odin"},
		{"Odin",       "odin"},
		{"my-tool",    "my_tool"},
		{"foo.bar",    "foo_bar"},
		{"_local",     "_local"},
		{"",           ""},
	}
	for c in cases {
		got := wayu.sanitize_path_key(c.input)
		defer if len(got) > 0 { delete(got) }
		testing.expectf(t, got == c.want,
			"sanitize_path_key(%q) = %q, want %q", c.input, got, c.want)
	}
}

@(test)
test_sanitize_path_key_hidden_prefix :: proc(t: ^testing.T) {
	cases := []struct{ input, want: string }{
		{".local",   "hidden_local"},
		{".cargo",   "hidden_cargo"},
		{".config",  "hidden_config"},
		{"..foo",    "hidden_foo"},     // double dots collapse
		{".foo.bar", "hidden_foo_bar"}, // internal dot becomes _
		{".",        ""},               // bare dot has no useful name
		{"..",       ""},
	}
	for c in cases {
		got := wayu.sanitize_path_key(c.input)
		defer if len(got) > 0 { delete(got) }
		testing.expectf(t, got == c.want,
			"sanitize_path_key(%q) = %q, want %q", c.input, got, c.want)
	}
}

@(test)
test_derive_path_key_common_basenames :: proc(t: ^testing.T) {
	taken := make(map[string]bool); defer delete(taken)

	// `bin` is common — must be disambiguated by the parent dir name.
	cases := []struct{ path, want: string }{
		{"/usr/local/bin",        "local_bin"},
		{"/opt/homebrew/bin",     "homebrew_bin"},
		{"/Users/me/.cargo/bin",  "hidden_cargo_bin"},
		{"/Users/me/dev/Odin",    "odin"},
		{"/Users/me/.local",      "hidden_local"},
		{"/Users/me/.config",     "hidden_config"},
	}
	for c in cases {
		got := wayu.derive_path_key(c.path, taken)
		defer delete(got)
		testing.expectf(t, got == c.want,
			"derive_path_key(%q) = %q, want %q", c.path, got, c.want)
	}
}

@(test)
test_derive_path_key_collision :: proc(t: ^testing.T) {
	taken := make(map[string]bool); defer delete(taken)

	first := wayu.derive_path_key("/Users/me/dev/Odin", taken)
	defer delete(first)
	testing.expect(t, first == "odin", "first odin key should be `odin`")
	taken[first] = true

	second := wayu.derive_path_key("/Users/me/work/Odin", taken)
	defer delete(second)
	testing.expectf(t, second == "odin_2",
		"colliding odin key should be `odin_2`, got %q", second)
}

@(test)
test_parse_path_arg :: proc(t: ^testing.T) {
	{
		name, path, explicit := wayu.parse_path_arg("/usr/local/bin")
		testing.expect(t, !explicit, "bare path should not be explicit")
		testing.expect(t, name == "" && path == "/usr/local/bin", "bare path round-trip")
	}
	{
		name, path, explicit := wayu.parse_path_arg("local_bin=/usr/local/bin")
		testing.expect(t, explicit, "name=path should be explicit")
		testing.expect(t, name == "local_bin", "name component")
		testing.expect(t, path == "/usr/local/bin", "path component")
	}
	{
		// LHS contains a slash → not a valid identifier → treat as bare path.
		name, path, explicit := wayu.parse_path_arg("/path/with=eq/in/it")
		testing.expect(t, !explicit, "slash in LHS disqualifies name=path form")
		testing.expect(t, path == "/path/with=eq/in/it", "kept as bare path")
		_ = name
	}
}
