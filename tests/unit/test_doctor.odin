package test_wayu

import wayu "../../src"
import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"

@(private = "file")
dir_perm :: proc(path: string) -> os.Permissions {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return {}
	}
	return fi.mode
}

// wayu dirs are 0700 even under umask 000 (they hold startup code; bin/ is
// on PATH); existing ones lose group/other write only.
@(test)
test_make_wayu_dir_private_under_umask_000 :: proc(t: ^testing.T) {
	root := test_tmp("wayu_dir_modes")
	os.remove_all(root)
	defer os.remove_all(root)
	old_mask := posix.umask({})
	defer posix.umask(old_mask)

	nested := fmt.tprintf("%s/a/b/c", root)
	testing.expect_value(t, wayu.make_wayu_dir(nested), nil)
	for p in ([]string{root, fmt.tprintf("%s/a", root), fmt.tprintf("%s/a/b", root), nested}) {
		testing.expectf(t, dir_perm(p) == wayu.WAYU_DIR_MODE, "%s: %v", p, dir_perm(p))
	}

	// An existing 0777 dir keeps read/exec for everyone, loses the write bits.
	wide := fmt.tprintf("%s/wide", root)
	testing.expect_value(t, os.make_directory(wide), nil)
	testing.expect_value(t, os.chmod(wide, os.Permissions_All), nil)
	testing.expect_value(t, wayu.make_wayu_dir(wide), nil)
	testing.expect_value(
		t,
		dir_perm(wide),
		os.Permissions_All - os.Permissions{.Write_Group, .Write_Other},
	)
	// The wrapper every caller uses goes through the same helper.
	other := fmt.tprintf("%s/x/y", root)
	testing.expect_value(t, wayu.make_directory_all(other), nil)
	testing.expect_value(t, dir_perm(other), wayu.WAYU_DIR_MODE)
}

// doctor reports group/other-writable wayu dirs (not following symlinks)
// and --fix tightens them.
@(test)
test_doctor_dir_modes_check_and_fix :: proc(t: ^testing.T) {
	root := test_tmp("doctor_dir_modes")
	os.remove_all(root)
	defer os.remove_all(root)
	config := fmt.tprintf("%s/config", root)
	data := fmt.tprintf("%s/data", root)
	outside := fmt.tprintf("%s/outside", root)
	for d in ([]string{config, data, fmt.tprintf("%s/bin", data), outside}) {
		testing.expect_value(t, wayu.make_wayu_dir(d), nil)
	}
	orig_config, orig_data := wayu.wayu.config, wayu.wayu.data
	wayu.wayu.config, wayu.wayu.data = config, data
	defer {wayu.wayu.config = orig_config; wayu.wayu.data = orig_data}

	unsafe := wayu.wayu_unsafe_dirs(context.temp_allocator)
	testing.expect_value(t, len(unsafe), 0)

	bin := fmt.tprintf("%s/bin", data)
	testing.expect_value(t, os.chmod(bin, os.Permissions_All), nil)
	testing.expect_value(t, os.chmod(outside, os.Permissions_All), nil)
	// A symlink to a wide dir outside is not followed.
	link := fmt.tprintf("%s/linked", data)
	testing.expect_value(t, os.symlink(outside, link), nil)

	unsafe = wayu.wayu_unsafe_dirs(context.temp_allocator)
	testing.expect_value(t, len(unsafe), 1)
	if len(unsafe) == 1 {
		testing.expect_value(t, unsafe[0], bin)
	}

	ok, _ := wayu.doctor_fix_dir_modes()
	testing.expect(t, ok)
	testing.expect_value(t, len(wayu.wayu_unsafe_dirs(context.temp_allocator)), 0)
	testing.expect_value(t, dir_perm(outside), os.Permissions_All)
}

@(test)
test_doctor_rc_loads_wayu :: proc(t: ^testing.T) {
	testing.expect(t, wayu.rc_loads_wayu(`source "$HOME/.config/wayu/init.zsh"`))
	testing.expect(t, wayu.rc_loads_wayu(`. "$WAYU/init.bash"`))
	testing.expect(t, wayu.rc_loads_wayu(`eval "$(wayu export --eval)"`))
	testing.expect(t, wayu.rc_loads_wayu(`source "${WAYU_DATA_DIR:-$HOME/.config/wayu}/init.zsh"`))
	testing.expect(t, wayu.rc_loads_wayu("export X=1\nsource ~/.config/wayu/turbo.zsh  # fast\n"))
	testing.expect(t, !wayu.rc_loads_wayu(`# source "$HOME/.config/wayu/init.zsh"`))
	testing.expect(t, !wayu.rc_loads_wayu(`alias w=wayu`))
	testing.expect(t, !wayu.rc_loads_wayu(`source ~/.oh-my-zsh/init.zsh`))
	// OKAMI-272: a line that only mentions the file doesn't load it.
	testing.expect(t, !wayu.rc_loads_wayu(`alias e='vim ~/.config/wayu/init.zsh'`))
	testing.expect(t, !wayu.rc_loads_wayu(`alias s='source ~/.config/wayu/init.zsh'`))
	testing.expect(t, !wayu.rc_loads_wayu(`export WAYU_INIT=~/.config/wayu/init.zsh`))
	testing.expect(
		t,
		wayu.rc_loads_wayu(`[ -f ~/.config/wayu/init.zsh ] && source ~/.config/wayu/init.zsh`),
	)
	testing.expect(
		t,
		wayu.rc_loads_wayu(`if [ -r "$W/wayu/init.bash" ]; then . "$W/wayu/init.bash"; fi`),
	)
	// OKAMI-341: command prefixes are transparent.
	testing.expect(t, wayu.rc_loads_wayu(`builtin source ~/.local/share/wayu/init.zsh`))
	testing.expect(t, wayu.rc_loads_wayu(`command . ~/.local/share/wayu/init.bash`))
	testing.expect(t, wayu.rc_loads_wayu(`zsh-defer source ~/.local/share/wayu/init.zsh`))
	testing.expect(t, wayu.rc_loads_wayu(`zsh-defer -12 source ~/.local/share/wayu/init.zsh`))
	testing.expect(t, wayu.rc_loads_wayu(`[ -r "$W" ] && builtin source "$W/wayu/init.zsh"`))
	testing.expect(t, !wayu.rc_loads_wayu(`command -v source ~/.local/share/wayu/init.zsh`))
	testing.expect(t, !wayu.rc_loads_wayu(`echo builtin source ~/.local/share/wayu/init.zsh`))
	// turbo_only ignores plain init lines.
	testing.expect(t, !wayu.rc_loads_wayu(`source ~/.config/wayu/init.zsh`, turbo_only = true))
	testing.expect(t, wayu.rc_loads_wayu(`source ~/.config/wayu/turbo.zsh`, turbo_only = true))
}

// OKAMI-354: `doctor --help` lists every check from the registry.
@(test)
test_doctor_checks_have_descriptions :: proc(t: ^testing.T) {
	testing.expect(t, len(wayu.CHECKS) >= 14)
	for c in wayu.CHECKS {
		testing.expectf(t, len(c.desc) > 0, "check %s has no help description", c.name)
	}
}

// OKAMI-176: a later rc line replacing PROMPT_COMMAND drops _wayu_paths_sync.
@(test)
test_doctor_rc_prompt_command_overwrites :: proc(t: ^testing.T) {
	rc := `PROMPT_COMMAND="before"
source "$HOME/.config/wayu/init.bash"
PROMPT_COMMAND="history -a"
export PROMPT_COMMAND='x'
PROMPT_COMMAND="x;$PROMPT_COMMAND"
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}y"
PROMPT_COMMAND+=";z"
# PROMPT_COMMAND=commented
MY_PROMPT_COMMAND=other
echo "$PROMPT_COMMAND=shown"
unset PROMPT_COMMAND
declare -a PROMPT_COMMAND=(a b)
`
	got := wayu.rc_prompt_command_overwrites(rc, context.temp_allocator)
	want := []int{3, 4, 11, 12}
	testing.expectf(t, len(got) == len(want), "got %v, want %v", got, want)
	for n, i in want {
		if i < len(got) {
			testing.expect_value(t, got[i], n)
		}
	}
	// No wayu line: nothing to drop.
	testing.expect_value(
		t,
		len(wayu.rc_prompt_command_overwrites("PROMPT_COMMAND=x\n", context.temp_allocator)),
		0,
	)
}

@(test)
test_doctor_expand_path_uses_toml_env :: proc(t: ^testing.T) {
	consts := []wayu.ConfigEntry{{type = .CONSTANT, name = "WAYU_DOC_TOOLS", value = "/opt/tools"}}
	expect_expand :: proc(
		t: ^testing.T,
		path: string,
		consts: []wayu.ConfigEntry,
		want: string,
		loc := #caller_location,
	) {
		got := wayu.doctor_expand_path(path, consts)
		defer if len(got) > 0 do delete(got)
		testing.expect_value(t, got, want, loc)
	}
	expect_expand(t, "$WAYU_DOC_TOOLS/bin", consts, "/opt/tools/bin")
	expect_expand(t, "${WAYU_DOC_TOOLS}/bin", consts, "/opt/tools/bin")
	expect_expand(t, "/usr/bin", consts, "/usr/bin")
	// An unresolved variable yields "" (existence unknown, never "missing").
	expect_expand(t, "$WAYU_DOC_SURELY_UNSET_VAR/bin", consts, "")
}

// A relative entry resolves against the shell's cwd, so doctor (whose cwd is
// arbitrary) must not call it missing — --fix used to delete it.
@(test)
test_doctor_expand_path_relative_is_unresolved :: proc(t: ^testing.T) {
	consts := []wayu.ConfigEntry{{type = .CONSTANT, name = "WAYU_DOC_REL", value = "rel/dir"}}
	testing.expect_value(t, wayu.doctor_expand_path("./node_modules/.bin", consts), "")
	testing.expect_value(t, wayu.doctor_expand_path("bin", consts), "")
	testing.expect_value(t, wayu.doctor_expand_path(".", consts), "")
	// A wayu.toml constant that expands to a relative path is relative too.
	testing.expect_value(t, wayu.doctor_expand_path("$WAYU_DOC_REL/bin", consts), "")
	// ...and so is a process environment variable with a relative value.
	os.set_env("WAYU_DOC_ENV_REL", "rel/env")
	defer os.unset_env("WAYU_DOC_ENV_REL")
	testing.expect_value(t, wayu.doctor_expand_path("$WAYU_DOC_ENV_REL/bin", consts), "")
}
