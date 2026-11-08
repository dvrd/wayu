// test_plugin_regressions.odin - Regression tests for plugin bug fixes
// (rm ownership, exact lookups, dry-run side effects, resolver ownership,
// name validation, SHA comparison, load order, conflict scan, quoting).

package test_wayu

import "core:testing"
import "core:os"
import "core:strings"
import wayu "../../src"

REGRESSION_TEST_DIR :: "/tmp/wayu-test-plugin-regressions"

@(private="file")
use_regression_dir :: proc() -> (old_config: string, old_data: string) {
	wayu.init_shell_globals()
	old_config = wayu.wayu.config
	old_data = wayu.wayu.data
	os.remove_all(REGRESSION_TEST_DIR)
	os.make_directory(REGRESSION_TEST_DIR)
	wayu.wayu.config = REGRESSION_TEST_DIR
	wayu.wayu.data = REGRESSION_TEST_DIR
	return
}

@(private="file")
restore_dirs :: proc(old_config: string, old_data: string) {
	wayu.wayu.config = old_config
	wayu.wayu.data = old_data
	os.remove_all(REGRESSION_TEST_DIR)
}

// Fully-owned PluginMetadata (safe for cleanup_plugin_metadata).
@(private="file")
make_owned_plugin :: proc(name: string, installed_path: string, deps: []string = nil) -> wayu.PluginMetadata {
	p := wayu.PluginMetadata{
		name           = strings.clone(name),
		display_name   = strings.clone(name),
		url            = strings.clone("https://github.com/test/x.git"),
		enabled        = true,
		shell          = .ZSH,
		installed_path = strings.clone(installed_path),
		use            = make([dynamic]string),
		template       = .Source,
		dependencies   = make([dynamic]string),
		priority       = 100,
		profiles       = make([dynamic]string),
		git = wayu.GitMetadata{
			branch = strings.clone("main"),
			commit = strings.clone("abc1234"),
		},
	}
	for d in deps {
		append(&p.dependencies, strings.clone(d))
	}
	return p
}

@(private="file")
write_config_with :: proc(plugins: []wayu.PluginMetadata) -> bool {
	config := wayu.PluginConfigJSON{
		version      = strings.clone("1.0"),
		last_updated = wayu.get_iso8601_timestamp(),
		plugins      = make([dynamic]wayu.PluginMetadata),
	}
	defer wayu.cleanup_plugin_config_json(&config)
	for p in plugins {
		append(&config.plugins, p)
	}
	return wayu.write_plugin_config_json(&config)
}

@(private="file")
read_file_string :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return ""
	}
	return string(data)
}

// ---------------------------------------------------------------------------
// #1 + #2: rm frees exactly once, removes the exact target, keeps the rest
// ---------------------------------------------------------------------------

@(test)
test_plugin_remove_ownership_and_exact_target :: proc(t: ^testing.T) {
	old_c, old_d := use_regression_dir()
	defer restore_dirs(old_c, old_d)
	old_yes, old_dry := wayu.wayu.yes_flag, wayu.wayu.dry_run
	wayu.wayu.yes_flag = true
	wayu.wayu.dry_run = false
	defer { wayu.wayu.yes_flag = old_yes; wayu.wayu.dry_run = old_dry }

	plugins_dir :: REGRESSION_TEST_DIR + "/plugins"
	os.make_directory(plugins_dir)
	os.make_directory(plugins_dir + "/alpha")
	os.make_directory(plugins_dir + "/alpha-extra")
	os.make_directory(plugins_dir + "/beta")

	testing.expect(t, write_config_with({
		make_owned_plugin("alpha", plugins_dir + "/alpha"),
		make_owned_plugin("alpha-extra", plugins_dir + "/alpha-extra"),
		make_owned_plugin("beta", plugins_dir + "/beta"),
	}), "seed config")

	// Before the fix this double-freed config.plugins (UAF / bad free).
	wayu.handle_plugin_remove({"alpha"})

	config, ok := wayu.read_plugin_config_json()
	defer wayu.cleanup_plugin_config_json(&config)
	testing.expect(t, ok, "config readable after rm")
	testing.expect_value(t, len(config.plugins), 2)
	if len(config.plugins) == 2 {
		testing.expect_value(t, config.plugins[0].name, "alpha-extra")
		testing.expect_value(t, config.plugins[1].name, "beta")
	}
	testing.expect(t, !os.exists(plugins_dir + "/alpha"), "target dir removed")
	testing.expect(t, os.exists(plugins_dir + "/alpha-extra"), "similar-named dir kept")
	testing.expect(t, os.exists(plugins_dir + "/beta"), "other dir kept")
}

// #8: an entry whose installed_path is the plugins root (legacy empty name)
// must never wipe the root or anything outside it.
@(test)
test_plugin_remove_never_wipes_plugins_root :: proc(t: ^testing.T) {
	old_c, old_d := use_regression_dir()
	defer restore_dirs(old_c, old_d)
	old_yes, old_dry := wayu.wayu.yes_flag, wayu.wayu.dry_run
	wayu.wayu.yes_flag = true
	wayu.wayu.dry_run = false
	defer { wayu.wayu.yes_flag = old_yes; wayu.wayu.dry_run = old_dry }

	plugins_dir :: REGRESSION_TEST_DIR + "/plugins"
	os.make_directory(plugins_dir)
	os.make_directory(plugins_dir + "/keepme")
	outside :: REGRESSION_TEST_DIR + "/outside"
	os.make_directory(outside)

	testing.expect(t, write_config_with({
		make_owned_plugin("", plugins_dir),
		make_owned_plugin("evil", outside),
		make_owned_plugin("keepme", plugins_dir + "/keepme"),
	}), "seed config")

	wayu.handle_plugin_remove({""})
	wayu.handle_plugin_remove({"evil"})

	testing.expect(t, os.exists(plugins_dir + "/keepme"), "plugins root must survive rm of empty-name entry")
	testing.expect(t, os.exists(outside), "dir outside plugins root must survive")

	config, ok := wayu.read_plugin_config_json()
	defer wayu.cleanup_plugin_config_json(&config)
	testing.expect(t, ok, "config readable")
	testing.expect_value(t, len(config.plugins), 1)
}

// ---------------------------------------------------------------------------
// #3: dry-run rm / add have no side effects
// ---------------------------------------------------------------------------

@(test)
test_plugin_remove_dry_run_no_side_effects :: proc(t: ^testing.T) {
	old_c, old_d := use_regression_dir()
	defer restore_dirs(old_c, old_d)
	old_yes, old_dry := wayu.wayu.yes_flag, wayu.wayu.dry_run
	wayu.wayu.yes_flag = true
	wayu.wayu.dry_run = true
	defer { wayu.wayu.yes_flag = old_yes; wayu.wayu.dry_run = old_dry }

	plugins_dir :: REGRESSION_TEST_DIR + "/plugins"
	os.make_directory(plugins_dir)
	os.make_directory(plugins_dir + "/alpha")
	testing.expect(t, write_config_with({make_owned_plugin("alpha", plugins_dir + "/alpha")}), "seed")

	json_path :: REGRESSION_TEST_DIR + "/plugins.json"
	before := read_file_string(json_path)
	defer delete(before)

	wayu.handle_plugin_remove({"alpha"})

	after := read_file_string(json_path)
	defer delete(after)
	testing.expect(t, before == after, "dry-run rm must not rewrite plugins.json")
	testing.expect(t, os.exists(plugins_dir + "/alpha"), "dry-run rm must not delete dir")
	testing.expect(t, !os.exists(REGRESSION_TEST_DIR + "/backup"), "dry-run rm must not create backups")
}

// #3 + #4: dry-run add of a registry key: no plugins.json write, and the
// registry literals are not freed (crashed / bad-free before the fix).
@(test)
test_plugin_add_dry_run_registry_key :: proc(t: ^testing.T) {
	old_c, old_d := use_regression_dir()
	defer restore_dirs(old_c, old_d)
	old_dry := wayu.wayu.dry_run
	wayu.wayu.dry_run = true
	defer wayu.wayu.dry_run = old_dry

	wayu.handle_plugin_add({"syntax-highlighting"})
	wayu.handle_plugin_add({"https://github.com/user/custom-plugin.git"})

	testing.expect(t, !os.exists(REGRESSION_TEST_DIR + "/plugins.json"), "dry-run add must not write plugins.json")
	testing.expect(t, !os.exists(REGRESSION_TEST_DIR + "/plugins/zsh-syntax-highlighting"), "dry-run add must not clone")

	// Registry entry still intact after the add returned.
	info, found := wayu.popular_plugin_find("syntax-highlighting")
	testing.expect(t, found && info.name == "zsh-syntax-highlighting", "registry literal intact")
}

// #4: resolve_plugin returns owned strings for both registry and URL inputs.
@(test)
test_resolve_plugin_returns_owned_strings :: proc(t: ^testing.T) {
	info, ok := wayu.resolve_plugin("autosuggestions")
	testing.expect(t, ok, "registry key resolves")
	reg, _ := wayu.popular_plugin_find("autosuggestions")
	testing.expect(t, raw_data(info.name) != raw_data(reg.name), "name must be a clone, not the literal")
	wayu.plugin_info_destroy(&info) // tracking allocator flags a bad free if not owned

	arg := strings.clone("https://github.com/user/thing.git")
	defer delete(arg)
	info2, ok2 := wayu.resolve_plugin(arg)
	testing.expect(t, ok2, "url resolves")
	testing.expect(t, raw_data(info2.url) != raw_data(arg), "url must be a clone of argv")
	wayu.plugin_info_destroy(&info2)
}

// ---------------------------------------------------------------------------
// #6: identity lookups are exact; fuzzy only on explicit request, no prompt
// ---------------------------------------------------------------------------

@(test)
test_find_plugin_json_is_exact :: proc(t: ^testing.T) {
	config := wayu.PluginConfigJSON{plugins = make([dynamic]wayu.PluginMetadata)}
	defer wayu.cleanup_plugin_config_json(&config)
	append(&config.plugins, make_owned_plugin("forgit", "/tmp/x/forgit"))
	append(&config.plugins, make_owned_plugin("zsh-autosuggestions", "/tmp/x/zsa"))
	append(&config.plugins, make_owned_plugin("zsh-autocomplete", "/tmp/x/zac"))

	_, found := wayu.find_plugin_json(&config, "git")
	testing.expect(t, !found, "'git' must not match installed 'forgit'")

	p, found2 := wayu.find_plugin_json(&config, "forgit")
	testing.expect(t, found2 && p.name == "forgit", "exact match works")

	// No fuzzy resolution anywhere: a unique near-miss still fails.
	_, found3 := wayu.find_plugin_json(&config, "forgi")
	testing.expect(t, !found3, "'forgi' must not resolve to 'forgit'")
}

// CLI misses (update/enable/disable/priority/get/rm) only *suggest* names:
// `plugin disable rig` used to disable `origin`.
@(test)
test_plugin_miss_suggests_names_only :: proc(t: ^testing.T) {
	config := wayu.PluginConfigJSON{plugins = make([dynamic]wayu.PluginMetadata)}
	defer wayu.cleanup_plugin_config_json(&config)
	append(&config.plugins, make_owned_plugin("origin", "/tmp/x/origin"))

	_, found := wayu.find_plugin_json(&config, "rig")
	testing.expect(t, !found, "'rig' must not resolve to 'origin'")

	names := []string{"origin"}
	suggestions := wayu.suggest_similar_names("rig", names, wayu.GET_SUGGESTION_LIMIT, context.temp_allocator)
	testing.expect(t, len(suggestions) == 1 && suggestions[0] == "origin", "'origin' suggested for 'rig'")
}

@(test)
test_dependency_check_is_exact :: proc(t: ^testing.T) {
	config := wayu.PluginConfigJSON{plugins = make([dynamic]wayu.PluginMetadata)}
	defer wayu.cleanup_plugin_config_json(&config)
	append(&config.plugins, make_owned_plugin("forgit", "/tmp/x/forgit"))
	append(&config.plugins, make_owned_plugin("needs-git", "/tmp/x/ng", {"git"}))

	missing := wayu.validate_plugin_dependencies(&config.plugins[1], &config)
	defer {
		for m in missing { delete(m) }
		delete(missing)
	}
	testing.expect_value(t, len(missing), 1)
}

// ---------------------------------------------------------------------------
// #8: URL → name derivation and validation
// ---------------------------------------------------------------------------

@(test)
test_extract_plugin_name_trailing_slash :: proc(t: ^testing.T) {
	cases := []struct{ url, expected: string }{
		{"https://github.com/user/repo/", "repo"},
		{"https://github.com/user/repo.git/", "repo"},
		{"https://github.com/user/repo//", "repo"},
		{"git@host:repo.git", "repo"},
	}
	for c in cases {
		got := wayu.extract_plugin_name_from_url(c.url)
		testing.expectf(t, got == c.expected, "%s -> %q (want %q)", c.url, got, c.expected)
		delete(got)
	}
}

@(test)
test_is_valid_plugin_name :: proc(t: ^testing.T) {
	testing.expect(t, wayu.is_valid_plugin_name("zsh-autosuggestions"), "normal name")
	testing.expect(t, wayu.is_valid_plugin_name("z.fish"), "dotted name")
	bad := []string{"", ".", "..", "a/b", "-rf", "--yes"}
	for b in bad {
		testing.expectf(t, !wayu.is_valid_plugin_name(b), "%q must be rejected", b)
	}
}

@(test)
test_resolve_plugin_rejects_unsafe_url_names :: proc(t: ^testing.T) {
	bad := []string{"https://github.com/user/.", "https://github.com/user/..", "https://github.com/user/-rf"}
	for u in bad {
		info, ok := wayu.resolve_plugin(u)
		if ok { wayu.plugin_info_destroy(&info) }
		testing.expectf(t, !ok, "%s must not resolve", u)
	}
}

@(test)
test_is_path_inside_dir :: proc(t: ^testing.T) {
	root := "/home/u/.config/wayu/plugins"
	testing.expect(t, wayu.is_path_inside_dir("/home/u/.config/wayu/plugins/x", root), "child")
	testing.expect(t, !wayu.is_path_inside_dir(root, root), "root itself")
	testing.expect(t, !wayu.is_path_inside_dir("/home/u/.config/wayu/plugins/", root), "root with slash")
	testing.expect(t, !wayu.is_path_inside_dir("/home/u/.config/wayu/plugins/x/..", root), "dotdot back to root")
	testing.expect(t, !wayu.is_path_inside_dir("/home/u/.config/wayu/plugins-evil/x", root), "sibling prefix")
	testing.expect(t, !wayu.is_path_inside_dir("/etc", root), "outside")
	testing.expect(t, !wayu.is_path_inside_dir("", root), "empty")
}

// ---------------------------------------------------------------------------
// #10: SHA comparison tolerates abbreviation length
// ---------------------------------------------------------------------------

@(test)
test_git_commits_match_prefix :: proc(t: ^testing.T) {
	full := "0123456789abcdef0123456789abcdef01234567"
	testing.expect(t, wayu.git_commits_match("0123456", full), "7-char prefix")
	testing.expect(t, wayu.git_commits_match("012345678", full), "9-char prefix")
	testing.expect(t, wayu.git_commits_match(full, full), "identical")
	testing.expect(t, !wayu.git_commits_match("abcdef0", full), "different")
	testing.expect(t, !wayu.git_commits_match("", full), "empty local")
}

// ---------------------------------------------------------------------------
// #7: pinned refs are detected and preserved
// ---------------------------------------------------------------------------

@(test)
test_plugin_pinned_ref_detection :: proc(t: ^testing.T) {
	p := wayu.PluginMetadata{}
	pinned, _ := wayu.plugin_pinned_ref(&p)
	testing.expect(t, !pinned, "default branch-following plugin is not pinned")

	p.git.ref_type = .Tag
	p.git.tag = "v1.2.3"
	pinned2, ref2 := wayu.plugin_pinned_ref(&p)
	testing.expect(t, pinned2 && ref2 == "v1.2.3", "tag pin")

	p3 := wayu.PluginMetadata{}
	p3.git.branch = "HEAD"
	pinned3, _ := wayu.plugin_pinned_ref(&p3)
	testing.expect(t, pinned3, "detached HEAD treated as pinned")
}

// ---------------------------------------------------------------------------
// #11: deterministic load order; zsh-syntax-highlighting last
// ---------------------------------------------------------------------------

@(test)
test_load_order_deterministic_and_zsh_highlighting_last :: proc(t: ^testing.T) {
	config := wayu.PluginConfigJSON{plugins = make([dynamic]wayu.PluginMetadata)}
	defer wayu.cleanup_plugin_config_json(&config)
	names := []string{"zsh-syntax-highlighting", "p1", "p2", "p3", "p4", "p5"}
	for n in names {
		append(&config.plugins, make_owned_plugin(n, "/nonexistent"))
	}

	for _ in 0..<5 {
		order, ok := wayu.resolve_dependencies_with_priority(&config)
		testing.expect(t, ok, "resolves")
		expected := []string{"p1", "p2", "p3", "p4", "p5", "zsh-syntax-highlighting"}
		testing.expect_value(t, len(order), len(expected))
		if len(order) == len(expected) {
			for e, i in expected {
				testing.expectf(t, order[i] == e, "order[%d] = %s, want %s", i, order[i], e)
			}
		}
		for o in order { delete(o) }
		delete(order)
	}
}

// ---------------------------------------------------------------------------
// #13: conflict parsing
// ---------------------------------------------------------------------------

@(test)
test_parse_function_definition :: proc(t: ^testing.T) {
	ok_cases := []struct{ line, name: string }{
		{"foo() {", "foo"},
		{"foo () {", "foo"},
		{"function foo {", "foo"},
		{"function foo() {", "foo"},
		{"_my-fn::helper() {", "_my-fn::helper"},
	}
	for c in ok_cases {
		name, ok := wayu.parse_function_definition(c.line)
		testing.expectf(t, ok && name == c.name, "%q -> %q,%v", c.line, name, ok)
	}
	bad := []string{"reply=()", "local -a arr=()", "echo foo() bar", "x=$(foo)"}
	for b in bad {
		_, ok := wayu.parse_function_definition(b)
		testing.expectf(t, !ok, "%q must not be a function", b)
	}
}

@(test)
test_shared_env_vars_not_conflicts :: proc(t: ^testing.T) {
	old_shell := wayu.wayu.shell
	wayu.wayu.shell = .ZSH
	defer wayu.wayu.shell = old_shell

	base :: REGRESSION_TEST_DIR + "-conflicts"
	os.remove_all(base)
	os.make_directory(base)
	defer os.remove_all(base)
	os.make_directory(base + "/a")
	os.make_directory(base + "/b")
	_ = os.write_entire_file(base + "/a/a.plugin.zsh", transmute([]byte)string("export PATH=\"$HOME/bin:$PATH\"\nexport FPATH=x\nreply=()\n"))
	_ = os.write_entire_file(base + "/b/b.plugin.zsh", transmute([]byte)string("export PATH=\"/opt:$PATH\"\nfpath+=(x)\nreply=()\n"))

	config := wayu.PluginConfigJSON{plugins = make([dynamic]wayu.PluginMetadata)}
	defer wayu.cleanup_plugin_config_json(&config)
	append(&config.plugins, make_owned_plugin("a", base + "/a"))
	append(&config.plugins, make_owned_plugin("b", base + "/b"))

	wayu.detect_conflicts(&config)
	testing.expect(t, !config.plugins[0].conflicts.detected, "PATH/FPATH/reply=() must not be conflicts")
	testing.expect(t, !config.plugins[1].conflicts.detected, "PATH/FPATH/reply=() must not be conflicts")
}

// ---------------------------------------------------------------------------
// #14: loader quoting
// ---------------------------------------------------------------------------

@(test)
test_shell_quote_escapes :: proc(t: ^testing.T) {
	testing.expect_value(t, wayu.shell_quote("/a b/$x", .ZSH), "'/a b/$x'")
	testing.expect_value(t, wayu.shell_quote("it's", .ZSH), `'it'\''s'`)
	testing.expect_value(t, wayu.shell_quote("it's", .BASH), `'it'\''s'`)
	testing.expect_value(t, wayu.shell_quote(`a\b'c`, .FISH), `'a\\b\'c'`)
}
