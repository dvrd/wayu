// test_plugin_loadable.odin - Plugin entry-file discovery, "nothing to
// load" detection, registry data, and network-git subprocess deadlines
// (OKAMI-244, OKAMI-245). Offline: only local directories and processes.

package test_wayu

import wayu "../../src"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
loadable_dir :: proc(name: string) -> string {
	// Under the per-run private root, never a fixed /tmp name.
	dir := test_tmp(fmt.tprintf("loadable_%s", name))
	os.remove_all(dir)
	os.make_directory_all(dir)
	return dir
}

@(private = "file")
touch :: proc(dir: string, files: ..string) {
	for f in files {
		_ = os.write_entire_file(fmt.tprintf("%s/%s", dir, f), transmute([]byte)string("# x\n"))
	}
}

// Base names of the files the loader would source, in order (temp alloc).
@(private = "file")
sourced :: proc(
	name: string,
	dir: string,
	shell: wayu.ShellType,
	use: []string = nil,
) -> []string {
	plugin := wayu.PluginMetadata {
		name           = name,
		installed_path = dir,
	}
	dyn_use: [dynamic]string
	defer delete(dyn_use)
	for u in use {
		append(&dyn_use, u)
	}
	plugin.use = dyn_use
	files := wayu.get_plugin_files_to_source(plugin, shell)
	defer {
		for f in files {
			delete(f)
		}
		delete(files)
	}
	out := make([]string, len(files), context.temp_allocator)
	for f, i in files {
		out[i] = strings.clone(f[strings.last_index_byte(f, '/') + 1:], context.temp_allocator)
	}
	return out
}

@(test)
test_loader_sources_only_first_entry_file :: proc(t: ^testing.T) {
	dir := loadable_dir("first")
	defer os.remove_all(dir)
	// <name>.plugin.zsh sources <name>.zsh itself: loading both ran it twice.
	touch(dir, "p.plugin.zsh", "p.zsh", "init.zsh")
	got := sourced("p", dir, .ZSH)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0], "p.plugin.zsh")
	}
}

@(test)
test_loader_zsh_theme_and_sh_entries :: proc(t: ^testing.T) {
	theme := loadable_dir("theme")
	defer os.remove_all(theme)
	touch(theme, "powerlevel10k.zsh-theme", "powerlevel9k.zsh-theme")
	got := sourced("powerlevel10k", theme, .ZSH)
	testing.expect(
		t,
		len(got) == 1 && got[0] == "powerlevel10k.zsh-theme",
		"named theme is the entry file",
	)
	testing.expect_value(t, len(sourced("powerlevel10k", theme, .BASH)), 0)

	// Unnamed theme: top-level *.zsh-theme when there is no *.zsh.
	other := loadable_dir("other_theme")
	defer os.remove_all(other)
	touch(other, "agnoster.zsh-theme")
	got = sourced("my-theme", other, .ZSH)
	testing.expect(t, len(got) == 1 && got[0] == "agnoster.zsh-theme", "fallback to *.zsh-theme")

	// rupa/z ships z.sh: usable from zsh and bash, not fish.
	z := loadable_dir("z")
	defer os.remove_all(z)
	touch(z, "z.sh", "install.sh")
	got = sourced("z", z, .ZSH)
	testing.expect(t, len(got) == 1 && got[0] == "z.sh", "zsh loads <name>.sh")
	got = sourced("z", z, .BASH)
	testing.expect(t, len(got) == 1 && got[0] == "z.sh", "bash loads <name>.sh")
	testing.expect_value(t, len(sourced("z", z, .FISH)), 0)
}

@(test)
test_loadable_shells_and_compat :: proc(t: ^testing.T) {
	// Nothing loadable: a binary tool's source repo.
	tool := loadable_dir("tool")
	defer os.remove_all(tool)
	touch(tool, "README.md", "install.sh", "Cargo.toml")
	shells := wayu.plugin_loadable_shells("tool", tool, nil)
	testing.expect_value(t, shells, bit_set[wayu.ShellType]{})
	_, ok := wayu.shell_compat_from_loadable(shells)
	testing.expect(t, !ok, "nothing loadable must not yield a compat")
	testing.expect(
		t,
		!wayu.plugin_compat_loads_any(.BOTH, shells),
		"registry plugin with nothing to load",
	)

	// --use rescues it, and the glob's extension decides the shell.
	shells = wayu.plugin_loadable_shells("tool", tool, []string{"install.sh"})
	compat, ok2 := wayu.shell_compat_from_loadable(shells)
	testing.expect(t, ok2 && compat == .BOTH, ".sh via --use loads in zsh and bash")
	shells = wayu.plugin_loadable_shells("tool", tool, []string{"*.nope"})
	testing.expect_value(t, shells, bit_set[wayu.ShellType]{})

	// zsh-only repo → ZSH; fish-only → FISH; zsh + fish → ANY.
	zsh_only := loadable_dir("zsh_only")
	defer os.remove_all(zsh_only)
	touch(zsh_only, "zp.plugin.zsh")
	compat, _ = wayu.shell_compat_from_loadable(wayu.plugin_loadable_shells("zp", zsh_only, nil))
	testing.expect_value(t, compat, wayu.ShellCompat.ZSH)

	fish_only := loadable_dir("fish_only")
	defer os.remove_all(fish_only)
	os.make_directory(fmt.tprintf("%s/conf.d", fish_only))
	touch(fish_only, "conf.d/fp.fish")
	fish_shells := wayu.plugin_loadable_shells("fp", fish_only, nil)
	compat, _ = wayu.shell_compat_from_loadable(fish_shells)
	testing.expect_value(t, compat, wayu.ShellCompat.FISH)
	// A registry entry marked zsh/bash with only fish files loads nowhere.
	testing.expect(
		t,
		!wayu.plugin_compat_loads_any(.BOTH, fish_shells),
		"BOTH cannot load fish-only files",
	)

	touch(zsh_only, "zp.fish")
	compat, _ = wayu.shell_compat_from_loadable(wayu.plugin_loadable_shells("zp", zsh_only, nil))
	testing.expect_value(t, compat, wayu.ShellCompat.ANY)
}

@(test)
test_use_glob_validation :: proc(t: ^testing.T) {
	testing.expect(t, wayu.is_valid_use_glob("*.zsh"), "glob")
	testing.expect(t, wayu.is_valid_use_glob("theme.zsh-theme"), "name")
	testing.expect(t, !wayu.is_valid_use_glob(""), "empty")
	testing.expect(t, !wayu.is_valid_use_glob(".."), "dotdot")
	testing.expect(t, !wayu.is_valid_use_glob("lib/x.zsh"), "slash")
	testing.expect(t, !wayu.is_valid_use_glob("a\nb"), "newline")
}

// Registry data (PLG-10): unique keys and install names, cloneable
// https://github.com/<owner>/<repo>.git URLs.
@(test)
test_registry_entries_unique_and_cloneable :: proc(t: ^testing.T) {
	keys := make(map[string]bool, context.temp_allocator)
	names := make(map[string]bool, context.temp_allocator)
	urls := make(map[string]bool, context.temp_allocator)
	for entry in wayu.POPULAR_PLUGINS {
		testing.expectf(t, !(entry.key in keys), "duplicate registry key %s", entry.key)
		testing.expectf(
			t,
			!(entry.info.name in names),
			"duplicate install name %s",
			entry.info.name,
		)
		testing.expectf(t, !(entry.info.url in urls), "duplicate url %s", entry.info.url)
		keys[entry.key] = true
		names[entry.info.name] = true
		urls[entry.info.url] = true

		testing.expectf(
			t,
			wayu.is_valid_plugin_name(entry.info.name),
			"invalid name %s",
			entry.info.name,
		)
		url := entry.info.url
		ok := strings.has_prefix(url, "https://github.com/") && strings.has_suffix(url, ".git")
		if ok {
			path := url[len("https://github.com/"):len(url) - len(".git")]
			parts := strings.split(path, "/", context.temp_allocator)
			ok = len(parts) == 2 && len(parts[0]) > 0 && len(parts[1]) > 0
		}
		testing.expectf(
			t,
			ok,
			"%s: url %s is not https://github.com/<owner>/<repo>.git",
			entry.key,
			url,
		)
	}

	// pure (zsh) and pure-fish install to different directories.
	zsh_pure, _ := wayu.popular_plugin_find("pure")
	fish_pure, _ := wayu.popular_plugin_find("pure-fish")
	testing.expect(t, zsh_pure.name != fish_pure.name, "pure and pure-fish must not share a name")

	// Binary tools are not plugins.
	for key in ([]string {
			"starship",
			"zoxide",
			"fzf",
			"ripgrep",
			"direnv",
			"zsh-dotenv",
			"zsh-history-enquirer",
		}) {
		_, found := wayu.popular_plugin_find(key)
		testing.expectf(t, !found, "registry must not list %s", key)
	}
}

// --- OKAMI-245: subprocess deadline -------------------------------------

@(test)
test_run_command_timeout_kills_hung_process_group :: proc(t: ^testing.T) {
	start := time.tick_now()
	// The background sleep keeps the pipes open: only killing the whole
	// process group lets the call return at the deadline.
	r := wayu.run_command_timeout([]string{"sh", "-c", "sleep 30 & sleep 30"}, 300)
	defer wayu.command_result_destroy(&r)
	elapsed := time.duration_seconds(time.tick_since(start))
	testing.expect(t, r.timed_out, "must report the timeout")
	testing.expect(t, !r.ok, "a timed-out command is not ok")
	testing.expectf(t, elapsed < 5, "returned after %.1fs, deadline was 0.3s", elapsed)
}

@(test)
test_run_command_timeout_captures_output_and_env :: proc(t: ^testing.T) {
	r := wayu.run_command_timeout(
		[]string {
			"sh",
			"-c",
			"echo out; echo err >&2; printf '%s|%s' \"$WAYU_UNIT_DEFAULT\" \"$GIT_TERMINAL_PROMPT\" >&2; exit 3",
		},
		10_000,
		[]wayu.Env_Default{{"WAYU_UNIT_DEFAULT", "dflt"}},
	)
	defer wayu.command_result_destroy(&r)
	testing.expect(t, !r.ok && !r.timed_out, "exit 3 is a failure, not a timeout")
	testing.expect_value(t, r.stdout, "out")
	testing.expect_value(t, r.stderr, "err\ndflt|0")

	ok := wayu.run_command_timeout([]string{"true"}, 0)
	defer wayu.command_result_destroy(&ok)
	testing.expect(t, ok.ok, "true succeeds without a deadline")

	missing := wayu.run_command_timeout([]string{"/nonexistent/wayu-unit-binary"}, 1000)
	defer wayu.command_result_destroy(&missing)
	testing.expect(t, !missing.ok && !missing.timed_out, "missing binary fails fast")
}
