package test_wayu

// Tests for fish-shell plugin support.
// Covers:
//   - ShellCompat FISH + ANY parse/serialize round-trip
//   - plugin_compat_matches cross-shell matrix
//   - apply_load_template fish branches for all 5 templates
//   - registry sanity: fish plugins present and well-formed

import "core:testing"
import "core:strings"
import wayu "../../src"

@(test)
test_shell_compat_parse_fish_and_any :: proc(t: ^testing.T) {
	testing.expect(t, wayu.parse_shell_compat("fish") == .FISH, "parse fish → FISH")
	testing.expect(t, wayu.parse_shell_compat("FISH") == .FISH, "case-insensitive fish")
	testing.expect(t, wayu.parse_shell_compat("any")  == .ANY,  "parse any → ANY")
	testing.expect(t, wayu.parse_shell_compat("all")  == .ANY,  "parse all → ANY (alias)")
}

@(test)
test_shell_compat_to_string_fish_and_any :: proc(t: ^testing.T) {
	testing.expect(t, wayu.shell_compat_to_string(.FISH) == "fish", "FISH → fish")
	testing.expect(t, wayu.shell_compat_to_string(.ANY)  == "any",  "ANY → any")
}

@(test)
test_plugin_compat_matches_matrix :: proc(t: ^testing.T) {
	// Fish plugins in fish only.
	testing.expect(t,  wayu.plugin_compat_matches(.FISH, .FISH), "fish/fish match")
	testing.expect(t, !wayu.plugin_compat_matches(.FISH, .ZSH),  "fish plugin not in zsh")
	testing.expect(t, !wayu.plugin_compat_matches(.FISH, .BASH), "fish plugin not in bash")

	// BOTH (zsh+bash legacy) excludes fish.
	testing.expect(t,  wayu.plugin_compat_matches(.BOTH, .ZSH),  "both/zsh match")
	testing.expect(t,  wayu.plugin_compat_matches(.BOTH, .BASH), "both/bash match")
	testing.expect(t, !wayu.plugin_compat_matches(.BOTH, .FISH), "both excludes fish")

	// ANY matches every supported shell.
	testing.expect(t, wayu.plugin_compat_matches(.ANY, .ZSH),  "any/zsh")
	testing.expect(t, wayu.plugin_compat_matches(.ANY, .BASH), "any/bash")
	testing.expect(t, wayu.plugin_compat_matches(.ANY, .FISH), "any/fish")
}

@(test)
test_apply_load_template_fish_source :: proc(t: ^testing.T) {
	out := wayu.apply_load_template(.Source, "/tmp/x.fish", "x", "/tmp", .FISH)
	defer delete(out)
	testing.expect(t, out == "source \"/tmp/x.fish\"", "fish source uses plain `source` builtin")
}

@(test)
test_apply_load_template_fish_path_uses_builtin :: proc(t: ^testing.T) {
	out := wayu.apply_load_template(.Path, "", "plug", "/opt/plug/bin", .FISH)
	defer delete(out)
	testing.expect(t, out == "fish_add_path \"/opt/plug/bin\"", "fish Path uses fish_add_path")
}

@(test)
test_apply_load_template_fish_fpath :: proc(t: ^testing.T) {
	out := wayu.apply_load_template(.FPath, "", "plug", "/opt/plug/functions", .FISH)
	defer delete(out)
	expected := "set -gx fish_function_path \"/opt/plug/functions\" $fish_function_path"
	testing.expect(t, out == expected, "fish FPath maps to fish_function_path prepend")
}

@(test)
test_apply_load_template_fish_autoload_is_noop :: proc(t: ^testing.T) {
	out := wayu.apply_load_template(.Autoload, "", "mynm", "/opt/mynm", .FISH)
	defer delete(out)
	// Autoload is a zsh concept — fish autoloads from $fish_function_path.
	// We emit a comment so the generated file stays informational.
	testing.expect(
		t,
		strings.has_prefix(out, "#"),
		"fish Autoload must be emitted as a comment, never executable code",
	)
	testing.expect(t, strings.contains(out, "mynm"), "comment should mention the plugin name")
}

@(test)
test_apply_load_template_fish_eval_uses_parens :: proc(t: ^testing.T) {
	out := wayu.apply_load_template(.Eval, "/opt/plug/init", "plug", "/opt/plug", .FISH)
	defer delete(out)
	testing.expect(t, out == "eval (/opt/plug/init)", "fish eval uses parens, not $()")
}

@(test)
test_apply_load_template_zsh_unchanged :: proc(t: ^testing.T) {
	// Regression: existing zsh/bash template output must be byte-identical
	// after adding the fish branch. If this test fails, we broke zsh users.
	out := wayu.apply_load_template(.Source, "/tmp/x.zsh", "x", "/tmp", .ZSH)
	defer delete(out)
	testing.expect(t, out == "source \"/tmp/x.zsh\"", "zsh Source must keep legacy format")

	out2 := wayu.apply_load_template(.Path, "", "x", "/opt/x/bin", .ZSH)
	defer delete(out2)
	testing.expect(t, out2 == "export PATH=\"/opt/x/bin:$PATH\"", "zsh Path must keep legacy format")

	out3 := wayu.apply_load_template(.Autoload, "", "fn", "/opt", .ZSH)
	defer delete(out3)
	testing.expect(t, out3 == "autoload -Uz fn", "zsh Autoload must keep legacy format")

	out4 := wayu.apply_load_template(.Eval, "/opt/init", "x", "/opt", .ZSH)
	defer delete(out4)
	testing.expect(t, out4 == "eval \"$(/opt/init)\"", "zsh Eval must keep legacy $() form")
}

@(test)
test_registry_contains_fish_plugins :: proc(t: ^testing.T) {
	// The registry must now include at least a handful of fish-native plugins.
	fish_count := 0
	for entry in wayu.POPULAR_PLUGINS {
		if entry.info.shell == .FISH {
			fish_count += 1
			// Sanity: fish plugins must have a non-empty URL and name.
			testing.expect(t, len(entry.info.url)  > 0, "fish plugin URL must be non-empty")
			testing.expect(t, len(entry.info.name) > 0, "fish plugin name must be non-empty")
		}
	}
	testing.expect(t, fish_count >= 5, "registry should include at least 5 fish plugins")
}

@(test)
test_registry_finds_known_fish_plugins_by_key :: proc(t: ^testing.T) {
	// Spot-check: a few canonical fish plugins must be discoverable via the
	// popular_plugin_find lookup, matching the registry layout.
	keys := [?]string{"tide", "pure-fish", "nvm-fish", "bass", "z-fish"}
	for key in keys {
		info, found := wayu.popular_plugin_find(key)
		testing.expect(t, found, "known fish plugin key must resolve")
		if found {
			testing.expect(t, info.shell == .FISH, "fish plugin entry must be marked .FISH")
		}
	}
}
