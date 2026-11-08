// test_plugin_security.odin - Regression tests for plugin hardening:
// symlink-safe removal, plugins.json validation on load, git option
// injection, exact ref matching, force-push updates and commit pinning.
// All git remotes are local (file://); nothing touches the network.

package test_wayu

import "core:testing"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:c/libc"
import wayu "../../src"

@(private="file")
sec_dir :: proc() -> string {
	return fmt.tprintf("/tmp/wayu_unit_plgsec_%d", os.get_pid())
}

// Run a shell command with a deterministic git identity and no signing.
@(private="file")
sh :: proc(format: string, args: ..any) -> bool {
	cmd := fmt.tprintf(format, ..args)
	full := fmt.ctprintf(
		"GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 sh -c '%s' >/dev/null 2>&1",
		cmd)
	return libc.system(full) == 0
}

@(private="file")
git_head :: proc(dir: string) -> string {
	return wayu.capture_command([]string{"git", "-C", dir, "rev-parse", "HEAD"})
}

// Fresh sandbox with a local origin repo (branch master, one commit) and
// wayu's config/data dirs pointed inside it.
@(private="file")
setup_sandbox :: proc() -> (root: string, origin: string, old_config: string, old_data: string) {
	wayu.init_shell_globals()
	root = sec_dir()
	os.remove_all(root)
	os.make_directory_all(fmt.tprintf("%s/wayu/plugins", root))
	origin = fmt.tprintf("%s/origin", root)
	sh("git init -q -b master %s && echo one > %s/p.plugin.zsh && git -C %s add . && git -C %s commit -q -m one",
		origin, origin, origin, origin)
	old_config = wayu.wayu.config
	old_data = wayu.wayu.data
	wayu.wayu.config = fmt.tprintf("%s/wayu", root)
	wayu.wayu.data = wayu.wayu.config
	return
}

@(private="file")
teardown_sandbox :: proc(root: string, old_config: string, old_data: string) {
	wayu.wayu.config = old_config
	wayu.wayu.data = old_data
	os.remove_all(root)
}

@(private="file")
write_plugins_json :: proc(content: string) {
	path := fmt.tprintf("%s/plugins.json", wayu.wayu.data)
	_ = os.write_entire_file(path, transmute([]byte)content)
}

// --- OKAMI-226: removal never follows symlinks --------------------------

@(test)
test_remove_symlinked_plugin_keeps_target :: proc(t: ^testing.T) {
	root, _, oc, od := setup_sandbox()
	defer teardown_sandbox(root, oc, od)

	target := fmt.tprintf("%s/devplug", root)
	os.make_directory(target)
	keep := fmt.tprintf("%s/devplug.plugin.zsh", target)
	_ = os.write_entire_file(keep, transmute([]byte)string("echo keep\n"))

	plugins_dir := fmt.tprintf("%s/wayu/plugins", root)
	link := fmt.tprintf("%s/devplug", plugins_dir)
	testing.expect(t, sh("ln -s %s %s", target, link), "create symlink")

	result := wayu.remove_plugin_dir_safely(link, plugins_dir)
	testing.expect_value(t, result, wayu.PluginDirRemoval.Removed)
	testing.expect(t, os.exists(keep), "symlink target contents must survive removal")
	testing.expect(t, !wayu.is_symlink(link), "the symlink itself must be gone")

	// Add-rollback path goes through the same helper.
	testing.expect(t, sh("ln -s %s %s", target, link), "recreate symlink")
	testing.expect(t, wayu.remove_cloned_plugin_dir(link, plugins_dir), "rollback removal ok")
	testing.expect(t, os.exists(keep), "rollback must not empty the target")
}

@(test)
test_remove_dir_resolving_outside_root_refused :: proc(t: ^testing.T) {
	root, _, oc, od := setup_sandbox()
	defer teardown_sandbox(root, oc, od)

	// plugins/sub is a symlink to an outside dir; plugins/sub/inner is a
	// real directory lexically inside the root but physically outside.
	outside := fmt.tprintf("%s/outside", root)
	os.make_directory_all(fmt.tprintf("%s/inner", outside))
	keep := fmt.tprintf("%s/inner/file", outside)
	_ = os.write_entire_file(keep, transmute([]byte)string("x"))
	plugins_dir := fmt.tprintf("%s/wayu/plugins", root)
	testing.expect(t, sh("ln -s %s %s/sub", outside, plugins_dir), "create symlink")

	result := wayu.remove_plugin_dir_safely(fmt.tprintf("%s/sub/inner", plugins_dir), plugins_dir)
	testing.expect_value(t, result, wayu.PluginDirRemoval.Outside)
	testing.expect(t, os.exists(keep), "directory resolving outside the root must survive")
}

@(test)
test_remove_real_plugin_dir :: proc(t: ^testing.T) {
	root, _, oc, od := setup_sandbox()
	defer teardown_sandbox(root, oc, od)

	plugins_dir := fmt.tprintf("%s/wayu/plugins", root)
	dir := fmt.tprintf("%s/real", plugins_dir)
	os.make_directory_all(fmt.tprintf("%s/nested", dir))
	testing.expect_value(t, wayu.remove_plugin_dir_safely(dir, plugins_dir), wayu.PluginDirRemoval.Removed)
	testing.expect(t, !os.exists(dir), "real plugin dir removed")
	testing.expect_value(t, wayu.remove_plugin_dir_safely(dir, plugins_dir), wayu.PluginDirRemoval.Missing)
	testing.expect_value(t, wayu.remove_plugin_dir_safely(plugins_dir, plugins_dir), wayu.PluginDirRemoval.Outside)
}

// --- OKAMI-227: plugins.json validated on load; `--` before URLs --------

@(test)
test_plugins_json_rejects_option_url :: proc(t: ^testing.T) {
	root, _, oc, od := setup_sandbox()
	defer teardown_sandbox(root, oc, od)

	write_plugins_json(`{"version":"1.0","plugins":[{"name":"p","url":"--upload-pack=touch /tmp/x;","enabled":true}]}`)
	config, ok := wayu.read_plugin_config_json()
	defer wayu.cleanup_plugin_config_json(&config)
	testing.expect(t, !ok, "a '-'-prefixed url must be rejected on load")
}

@(test)
test_plugins_json_rejects_bad_fields :: proc(t: ^testing.T) {
	root, _, oc, od := setup_sandbox()
	defer teardown_sandbox(root, oc, od)

	bad := [?]string{
		`{"plugins":[{"name":"p","url":"http://h/p.git"}]}`,
		`{"plugins":[{"name":"../x","url":"https://h/p.git"}]}`,
		`{"plugins":[{"name":"p","url":"https://h/p.git","git":{"branch":"--evil"}}]}`,
		`{"plugins":[{"name":"p","url":"https://h/p.git","shell":"nonsense"}]}`,
		`{"plugins":[{"name":"p","url":"https://h/p.git","shell":9}]}`,
		`{"plugins":[{"name":"p","url":"https://h/p.git","template":"Run"}]}`,
		`{"plugins":[{"name":"p","url":"https://h/p.git","installed_path":"-rf"}]}`,
		// A newline would break out of the loader's "# missing deps" comment.
		`{"plugins":[{"name":"p","url":"https://h/p.git","dependencies":["x\necho PWNED"]}]}`,
		`{"plugins":[{"name":"p","url":"https://h/p.git","dependencies":["../x"]}]}`,
	}
	for doc in bad {
		write_plugins_json(doc)
		config, ok := wayu.read_plugin_config_json()
		testing.expectf(t, !ok, "must reject: %s", doc)
		wayu.cleanup_plugin_config_json(&config)
	}
}

@(test)
test_plugins_json_enum_values_resolved :: proc(t: ^testing.T) {
	root, _, oc, od := setup_sandbox()
	defer teardown_sandbox(root, oc, od)

	// Lowercase (CLI vocabulary), legacy ints and Odin names all resolve.
	write_plugins_json(`{"plugins":[
		{"name":"a","url":"https://h/a.git","shell":"bash","template":"fpath","git":{"ref_type":"commit"}},
		{"name":"b","url":"https://h/b.git","shell":3,"template":1},
		{"name":"c","url":"https://h/c.git","shell":"ANY","source_type":"Local"},
	]}`)
	config, ok := wayu.read_plugin_config_json()
	defer wayu.cleanup_plugin_config_json(&config)
	testing.expect(t, ok, "valid enum spellings must load")
	if !ok || len(config.plugins) != 3 { return }
	testing.expect_value(t, config.plugins[0].shell, wayu.ShellCompat.BASH)
	testing.expect_value(t, config.plugins[0].template, wayu.PluginLoadTemplate.FPath)
	testing.expect_value(t, config.plugins[0].git.ref_type, wayu.GitRefType.Commit)
	testing.expect_value(t, config.plugins[1].shell, wayu.ShellCompat.FISH)
	testing.expect_value(t, config.plugins[1].template, wayu.PluginLoadTemplate.Path)
	testing.expect_value(t, config.plugins[2].shell, wayu.ShellCompat.ANY)
	testing.expect_value(t, config.plugins[2].source_type, wayu.PluginSourceType.Local)

	// Round trip: written as names, read back unchanged.
	testing.expect(t, wayu.write_plugin_config_json(&config), "write")
	again, ok2 := wayu.read_plugin_config_json()
	defer wayu.cleanup_plugin_config_json(&again)
	testing.expect(t, ok2, "re-read")
	if ok2 && len(again.plugins) == 3 {
		testing.expect_value(t, again.plugins[0].shell, wayu.ShellCompat.BASH)
		testing.expect_value(t, again.plugins[1].shell, wayu.ShellCompat.FISH)
	}
}

@(test)
test_option_url_cannot_inject :: proc(t: ^testing.T) {
	root, _, oc, od := setup_sandbox()
	defer teardown_sandbox(root, oc, od)

	marker := fmt.tprintf("%s/PWNED", root)
	evil := fmt.tprintf("--upload-pack=touch %s;", marker)

	remote := wayu.get_remote_commit(evil, "master")
	defer delete(remote)
	testing.expect_value(t, remote, "")
	testing.expect(t, !os.exists(marker), "ls-remote must not run an injected --upload-pack")

	// A clone with a '-'-prefixed url fails instead of running the option.
	dest := fmt.tprintf("%s/wayu/plugins/evil", root)
	testing.expect(t, !wayu.git_clone(evil, dest), "clone of option-like url must fail")
	testing.expect(t, !os.exists(marker), "git clone must not run an injected --upload-pack")

	testing.expect(t, !wayu.is_valid_git_url(evil), "option-like url is not a valid plugin url")
}

// --- OKAMI-228: exact ref matching, force-push update -------------------

@(test)
test_remote_commit_matches_exact_branch :: proc(t: ^testing.T) {
	root, origin, oc, od := setup_sandbox()
	defer teardown_sandbox(root, oc, od)

	master := git_head(origin)
	defer delete(master)
	// refs/heads/aaa/master sorts before refs/heads/master and also ends in
	// "master": the old tail match picked it and reported a bogus update.
	testing.expect(t, sh("git -C %s checkout -q -b aaa/master && git -C %s commit -q --allow-empty -m other && git -C %s tag master && git -C %s checkout -q master",
		origin, origin, origin, origin), "create decoy refs")

	url := fmt.tprintf("file://%s", origin)
	remote := wayu.get_remote_commit(url, "master")
	defer delete(remote)
	testing.expect_value(t, remote, master)

	missing := wayu.get_remote_commit(url, "no-such-branch")
	defer delete(missing)
	testing.expect_value(t, missing, "")
}

@(test)
test_update_after_force_push :: proc(t: ^testing.T) {
	root, origin, oc, od := setup_sandbox()
	defer teardown_sandbox(root, oc, od)

	dest := fmt.tprintf("%s/wayu/plugins/p", root)
	url := fmt.tprintf("file://%s", origin)
	testing.expect(t, wayu.git_clone(url, dest), "clone")

	// Normal fast-forward.
	testing.expect(t, sh("echo two >> %s/p.plugin.zsh && git -C %s commit -q -am two", origin, origin), "commit two")
	result, err := wayu.git_update(dest, "master")
	delete(err)
	testing.expect_value(t, result, wayu.GitUpdateResult.Updated)

	// Upstream rewrites history (amend + force push).
	testing.expect(t, sh("git -C %s commit -q --amend -m rewritten", origin), "amend")
	result, err = wayu.git_update(dest, "master")
	delete(err)
	testing.expect_value(t, result, wayu.GitUpdateResult.Reset)

	want := git_head(origin)
	got := git_head(dest)
	defer { delete(want); delete(got) }
	testing.expect_value(t, got, want)
}

@(test)
test_update_never_resets_dirty_checkout :: proc(t: ^testing.T) {
	root, origin, oc, od := setup_sandbox()
	defer teardown_sandbox(root, oc, od)

	dest := fmt.tprintf("%s/wayu/plugins/p", root)
	testing.expect(t, wayu.git_clone(fmt.tprintf("file://%s", origin), dest), "clone")
	testing.expect(t, sh("git -C %s commit -q --amend -m rewritten", origin), "amend")
	testing.expect(t, sh("echo local >> %s/p.plugin.zsh", dest), "local edit")

	result, err := wayu.git_update(dest, "master")
	defer delete(err)
	testing.expect_value(t, result, wayu.GitUpdateResult.Failed)
	testing.expect(t, len(err) > 0, "failure must explain why")

	data, rerr := os.read_entire_file(fmt.tprintf("%s/p.plugin.zsh", dest), context.temp_allocator)
	testing.expect(t, rerr == nil && strings.contains(string(data), "local"), "local edit must survive")
}

// A clean checkout with a local commit cannot be fast-forwarded either, but
// resetting it would silently drop that commit.
@(test)
test_update_never_resets_local_commits :: proc(t: ^testing.T) {
	root, origin, oc, od := setup_sandbox()
	defer teardown_sandbox(root, oc, od)

	dest := fmt.tprintf("%s/wayu/plugins/p", root)
	testing.expect(t, wayu.git_clone(fmt.tprintf("file://%s", origin), dest), "clone")
	testing.expect(t, sh("echo local >> %s/p.plugin.zsh && git -C %s commit -q -am local", dest, dest), "local commit")
	testing.expect(t, sh("echo two >> %s/p.plugin.zsh && git -C %s commit -q -am two", origin, origin), "upstream commit")

	before := git_head(dest)
	defer delete(before)
	result, err := wayu.git_update(dest, "master")
	defer delete(err)
	testing.expect_value(t, result, wayu.GitUpdateResult.Failed)
	testing.expect(t, strings.contains(err, "local commits"), "failure must explain why")

	after := git_head(dest)
	defer delete(after)
	testing.expect_value(t, after, before)
}

@(test)
test_update_failure_returns_stderr :: proc(t: ^testing.T) {
	root, _, oc, od := setup_sandbox()
	defer teardown_sandbox(root, oc, od)

	not_repo := fmt.tprintf("%s/wayu/plugins/not-a-repo", root)
	os.make_directory_all(not_repo)
	result, err := wayu.git_update(not_repo, "main")
	defer delete(err)
	testing.expect_value(t, result, wayu.GitUpdateResult.Failed)
	testing.expect(t, len(err) > 0, "git's stderr must be returned")
}

// --- OKAMI-229: http refused, commit pinning ------------------------------

@(test)
test_plugin_url_schemes :: proc(t: ^testing.T) {
	testing.expect(t, wayu.is_valid_git_url("https://github.com/u/r.git"), "https")
	testing.expect(t, wayu.is_valid_git_url("git@github.com:u/r.git"), "scp-style ssh")
	testing.expect(t, wayu.is_valid_git_url("ssh://git@h/u/r.git"), "ssh://")
	testing.expect(t, wayu.is_valid_git_url("file:///tmp/r"), "file://")
	testing.expect(t, !wayu.is_valid_git_url("http://github.com/u/r.git"), "http refused")
	testing.expect(t, !wayu.is_valid_git_url("git://github.com/u/r.git"), "git:// refused")
	testing.expect(t, wayu.is_insecure_git_url("http://github.com/u/r.git"), "http is insecure")
	testing.expect(t, !wayu.is_valid_git_url("https://h/r.git\n"), "control chars refused")
}

@(test)
test_split_plugin_commit_pin :: proc(t: ^testing.T) {
	url, commit := wayu.split_plugin_commit_pin("https://h/u/r.git@1a2b3c4")
	testing.expect_value(t, url, "https://h/u/r.git")
	testing.expect_value(t, commit, "1a2b3c4")

	url, commit = wayu.split_plugin_commit_pin("git@github.com:u/r.git")
	testing.expect_value(t, url, "git@github.com:u/r.git")
	testing.expect_value(t, commit, "")

	url, commit = wayu.split_plugin_commit_pin("git@github.com:u/r@deadbeef")
	testing.expect_value(t, url, "git@github.com:u/r")
	testing.expect_value(t, commit, "deadbeef")

	url, commit = wayu.split_plugin_commit_pin("syntax-highlighting@abcdef0")
	testing.expect_value(t, url, "syntax-highlighting")
	testing.expect_value(t, commit, "abcdef0")

	// Not a SHA (too short / not hex): left alone.
	url, commit = wayu.split_plugin_commit_pin("https://h/u/r@v1.0")
	testing.expect_value(t, url, "https://h/u/r@v1.0")
	testing.expect_value(t, commit, "")
}

@(test)
test_clone_at_pinned_commit :: proc(t: ^testing.T) {
	root, origin, oc, od := setup_sandbox()
	defer teardown_sandbox(root, oc, od)

	first := git_head(origin)
	defer delete(first)
	testing.expect(t, sh("echo two >> %s/p.plugin.zsh && git -C %s commit -q -am two", origin, origin), "commit two")

	dest := fmt.tprintf("%s/wayu/plugins/p", root)
	ok, err := wayu.git_clone_at_commit(fmt.tprintf("file://%s", origin), dest, first[:10])
	defer delete(err)
	testing.expectf(t, ok, "pinned clone failed: %s", err)

	got := git_head(dest)
	defer delete(got)
	testing.expect_value(t, got, first)

	// Unknown commit fails (and is never silently replaced by the tip).
	dest2 := fmt.tprintf("%s/wayu/plugins/p2", root)
	ok2, err2 := wayu.git_clone_at_commit(fmt.tprintf("file://%s", origin), dest2, "0123456789abcdef")
	defer delete(err2)
	testing.expect(t, !ok2, "clone at a missing commit must fail")
}

@(test)
test_pinned_commit_drift_detected :: proc(t: ^testing.T) {
	root, origin, oc, od := setup_sandbox()
	defer teardown_sandbox(root, oc, od)

	first := git_head(origin)
	defer delete(first)
	dest := fmt.tprintf("%s/wayu/plugins/p", root)
	testing.expect(t, wayu.git_clone(fmt.tprintf("file://%s", origin), dest), "clone")

	plugin := wayu.PluginMetadata{installed_path = dest}
	plugin.git.ref_type = .Commit
	plugin.git.pinned_ref = first
	testing.expect_value(t, wayu.plugin_pinned_commit_problem(&plugin), "")

	testing.expect(t, sh("git -C %s commit -q --allow-empty -m drift", dest), "drift")
	testing.expect(t, wayu.plugin_pinned_commit_problem(&plugin) != "", "drift from pin must be reported")
}
