package test_wayu

import wayu "../../src"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Verifies the plugin-install hook wrappers actually fire the configured
// shell command and substitute the {name} placeholder. Regression guard for
// the wiring of hook_pre_plugin_install / hook_post_plugin_install into the
// `wayu plugin add` flow (CLI + TUI).
@(test)
test_plugin_install_hooks_fire :: proc(t: ^testing.T) {
	tmp := test_tmp("wayu_test_hooks_plugin")
	os.remove_all(tmp)
	err := os.make_directory(tmp)
	testing.expect(t, err == nil, "should create temp hook config dir")
	defer os.remove_all(tmp)

	log_path := fmt.tprintf("%s/hook.log", tmp)

	// Point the global context at our temp config dir so load_hook_config()
	// reads the hooks.conf we write below.
	saved_config := wayu.wayu.config
	wayu.wayu.config = tmp
	defer wayu.wayu.config = saved_config

	hooks_conf := fmt.tprintf(
		"pre_plugin_install = \"echo PRE:{{name}} >> %s\"\npost_plugin_install = \"echo POST:{{name}} >> %s\"\n",
		log_path,
		log_path,
	)
	conf_path := fmt.tprintf("%s/hooks.conf", tmp)
	write_ok := wayu.safe_write_file(conf_path, transmute([]byte)(hooks_conf))
	testing.expect(t, write_ok, "should write hooks.conf")

	wayu.hook_pre_plugin_install("myplug")
	wayu.hook_post_plugin_install("myplug")

	content, read_ok := wayu.safe_read_file(log_path)
	testing.expect(t, read_ok, "hook should have created the log file")
	defer delete(content)
	testing.expect(
		t,
		strings.contains(string(content), "PRE:myplug"),
		"pre_plugin_install hook should run with {name} substituted",
	)
	testing.expect(
		t,
		strings.contains(string(content), "POST:myplug"),
		"post_plugin_install hook should run with {name} substituted",
	)
}

// When no hooks.conf exists, the wrappers must be safe no-ops (must not crash
// or create files).
@(test)
test_plugin_install_hooks_absent_noop :: proc(t: ^testing.T) {
	tmp := test_tmp("wayu_test_hooks_absent")
	os.remove_all(tmp)
	err := os.make_directory(tmp)
	testing.expect(t, err == nil, "should create temp hook config dir")
	defer os.remove_all(tmp)

	saved_config := wayu.wayu.config
	wayu.wayu.config = tmp
	defer wayu.wayu.config = saved_config

	// No hooks.conf written — these must not panic.
	wayu.hook_pre_plugin_install("x")
	wayu.hook_post_plugin_install("x")

	testing.expect(t, true, "absent hooks should be a safe no-op")
}

@(test)
test_hook_render_command_quotes_per_context :: proc(t: ^testing.T) {
	r1 := wayu.hook_render_command("echo {name}")
	defer delete(r1)
	testing.expect_value(t, r1, `echo "${WAYU_HOOK_NAME}"`)

	// Inside "..." a placeholder is reported (the hook is refused at load).
	r2, _, dtok := wayu.hook_render_command_ex(`echo "n={name} v={value}"`)
	defer delete(r2)
	testing.expect_value(t, dtok, "{name}")

	// Inside '...' the reference is left for an inner shell (OKAMI-230).
	r3, single, dtok3 := wayu.hook_render_command_ex(`sh -c 'echo {path} >> log'`)
	defer delete(r3)
	testing.expect_value(t, r3, `sh -c 'echo "${WAYU_HOOK_PATH}" >> log'`)
	testing.expect(t, single, "single-quoted placeholder reported")
	testing.expect_value(t, dtok3, "")
}

// A placeholder inside "..." (outside any '...') makes the hook invalid;
// unquoted, '...' and "$WAYU_HOOK_*" in double quotes stay valid.
@(test)
test_hook_double_quoted_placeholder_detection :: proc(t: ^testing.T) {
	Case :: struct {
		cmd, want: string,
	}
	cases := []Case {
		{`sh -c "echo {value}"`, "{value}"},
		{`echo "Adding {path}" >> log`, "{path}"},
		{`eval "x={name}"`, "{name}"},
		{`echo a "b" {name}`, ""},
		{`echo {path}`, ""},
		{`sh -c 'echo {path}'`, ""},
		{`sh -c 'echo "a {name}"'`, ""}, // "..." inside '...' is literal text
		{`echo "$WAYU_HOOK_NAME"`, ""},
		{`echo \"{name}\"`, ""}, // escaped quotes are not a quoted string
	}
	for c in cases {
		testing.expectf(
			t,
			wayu.hook_double_quoted_placeholder(c.cmd) == c.want,
			"%q: want %q",
			c.cmd,
			c.want,
		)
	}
}

// Load-time validation names every invalid line; a valid file reports nothing.
@(test)
test_hook_config_error_reports_lines :: proc(t: ^testing.T) {
	tmp := test_tmp("wayu_test_hooks_dquote")
	os.remove_all(tmp)
	testing.expect(t, os.make_directory(tmp) == nil)
	defer os.remove_all(tmp)

	saved_config := wayu.wayu.config
	wayu.wayu.config = tmp
	defer wayu.wayu.config = saved_config
	conf_path := fmt.tprintf("%s/hooks.conf", tmp)

	ok_conf := "# comment\npre_alias_add = echo {name}\npost_alias_add = sh -c 'echo {value}'\npre_path_add = echo \"$WAYU_HOOK_PATH\"\n"
	testing.expect(t, wayu.safe_write_file(conf_path, transmute([]byte)ok_conf))
	_, bad := wayu.hook_config_error()
	testing.expect(t, !bad, "unquoted / single-quoted / env-var hooks are valid")

	bad_conf := "# comment\npre_alias_add = echo {name}\npre_alias_add2 = x\npost_export = sh -c \"echo {value}\"\n"
	testing.expect(t, wayu.safe_write_file(conf_path, transmute([]byte)bad_conf))
	msg, bad2 := wayu.hook_config_error()
	testing.expect(t, bad2, "double-quoted placeholder must be refused")
	testing.expect(t, strings.contains(msg, "line 4: post_export"), msg)
	testing.expect(t, strings.contains(msg, "WAYU_HOOK_"), "message points to the env vars")

	config := wayu.load_hook_config()
	defer wayu.free_hook_config(config)
	testing.expect_value(t, len(config.invalid), 1)
}

// OKAMI-230: values reaching a nested shell (`sh -c '... {path}'`) stay data.
@(test)
test_hook_nested_shell_cannot_inject :: proc(t: ^testing.T) {
	tmp := test_tmp("wayu_test_hooks_nested")
	os.remove_all(tmp)
	testing.expect(t, os.make_directory(tmp) == nil)
	defer os.remove_all(tmp)

	saved_config := wayu.wayu.config
	wayu.wayu.config = tmp
	defer wayu.wayu.config = saved_config

	log_path := fmt.tprintf("%s/hook.log", tmp)
	pwned := fmt.tprintf("%s/PWNED", tmp)
	conf := fmt.tprintf("post_path_remove = sh -c 'echo rm {{path}} >> %s'\n", log_path)
	testing.expect(
		t,
		wayu.safe_write_file(fmt.tprintf("%s/hooks.conf", tmp), transmute([]byte)conf),
	)

	evil := fmt.tprintf("x$(touch %s)`touch %s`;touch %s", pwned, pwned, pwned)
	wayu.hook_post_path_remove(evil)

	content, ok := wayu.safe_read_file(log_path)
	testing.expect(t, ok, "hook should have run")
	defer delete(content)
	testing.expect(t, !os.exists(pwned), "value must not execute inside a nested shell")
	testing.expect(t, strings.contains(string(content), evil), "value passed literally")
}

// Placeholder values are data: shell metacharacters in a name/value must not
// execute, and {value} must be filled.
@(test)
test_hook_values_cannot_inject :: proc(t: ^testing.T) {
	tmp := test_tmp("wayu_test_hooks_inject")
	os.remove_all(tmp)
	testing.expect(t, os.make_directory(tmp) == nil)
	defer os.remove_all(tmp)

	saved_config := wayu.wayu.config
	wayu.wayu.config = tmp
	defer wayu.wayu.config = saved_config

	log_path := fmt.tprintf("%s/hook.log", tmp)
	pwned := fmt.tprintf("%s/PWNED", tmp)
	conf := fmt.tprintf(
		"post_alias_add = \"echo {{name}}={{value}} >> %s; echo 'q:{{name}}' >> %s\"\n",
		log_path,
		log_path,
	)
	testing.expect(
		t,
		wayu.safe_write_file(fmt.tprintf("%s/hooks.conf", tmp), transmute([]byte)conf),
	)

	evil := fmt.tprintf("x; touch %s", pwned)
	wayu.hook_post_alias_add(evil, "$(touch PWNED2) v")

	content, ok := wayu.safe_read_file(log_path)
	testing.expect(t, ok, "hook should have run")
	defer delete(content)
	testing.expect(t, !os.exists(pwned), "name must not be executed as shell code")
	testing.expect(t, strings.contains(string(content), evil), "name passed through literally")
	testing.expect(
		t,
		strings.contains(string(content), "$(touch PWNED2) v"),
		"{value} filled literally",
	)
	// Top-level '...' is not substituted (left for an inner shell).
	testing.expect(
		t,
		strings.contains(string(content), `q:"${WAYU_HOOK_NAME}"`),
		"single-quoted placeholder left as reference",
	)
}

@(test)
test_hooks_skipped_in_dry_run :: proc(t: ^testing.T) {
	tmp := test_tmp("wayu_test_hooks_dryrun")
	os.remove_all(tmp)
	testing.expect(t, os.make_directory(tmp) == nil)
	defer os.remove_all(tmp)

	saved_config := wayu.wayu.config
	wayu.wayu.config = tmp
	defer wayu.wayu.config = saved_config
	saved_dry := wayu.wayu.dry_run
	wayu.wayu.dry_run = true
	defer wayu.wayu.dry_run = saved_dry

	log_path := fmt.tprintf("%s/hook.log", tmp)
	conf := fmt.tprintf("pre_path_add = \"echo X >> %s\"\n", log_path)
	testing.expect(
		t,
		wayu.safe_write_file(fmt.tprintf("%s/hooks.conf", tmp), transmute([]byte)conf),
	)

	wayu.hook_pre_path_add("/x")
	testing.expect(t, !os.exists(log_path), "hooks must not run under --dry-run")
}

// OKAMI-186: the alias/constant hook procs are live — wired into the specs
// the generic entry handlers call. Every spec hook must be set and fire its
// hooks.conf key with {name}/{value} filled in.
@(test)
test_spec_hooks_are_wired_and_fire :: proc(t: ^testing.T) {
	tmp := test_tmp("wayu_test_hooks_specs")
	os.remove_all(tmp)
	testing.expect(t, os.make_directory(tmp) == nil)
	defer os.remove_all(tmp)

	saved_config := wayu.wayu.config
	wayu.wayu.config = tmp
	defer wayu.wayu.config = saved_config

	log_path := fmt.tprintf("%s/hook.log", tmp)
	keys := [?]string {
		"pre_alias_add",
		"post_alias_add",
		"pre_alias_remove",
		"post_alias_remove",
		"pre_constant_add",
		"post_constant_add",
		"pre_constant_remove",
		"post_constant_remove",
	}
	b := strings.builder_make(context.temp_allocator)
	for k in keys {
		fmt.sbprintf(&b, "%s = echo %s:{{name}}={{value}} >> %s\n", k, k, log_path)
	}
	testing.expect(
		t,
		wayu.safe_write_file(
			fmt.tprintf("%s/hooks.conf", tmp),
			transmute([]byte)strings.to_string(b),
		),
	)

	specs := [?]^wayu.ConfigEntrySpec{&wayu.ALIAS_SPEC, &wayu.CONSTANTS_SPEC}
	for s in specs {
		testing.expect(
			t,
			s.hook_pre_add != nil &&
			s.hook_post_add != nil &&
			s.hook_pre_remove != nil &&
			s.hook_post_remove != nil,
			"spec hooks must be wired",
		)
		s.hook_pre_add("n", "v")
		s.hook_post_add("n", "v")
		s.hook_pre_remove("n", "")
		s.hook_post_remove("n", "")
	}

	content, ok := wayu.safe_read_file(log_path)
	testing.expect(t, ok, "hooks should have written the log")
	defer if ok {
		delete(content)
	}
	for k in keys {
		testing.expectf(
			t,
			strings.contains(string(content), fmt.tprintf("%s:n=", k)),
			"%s should fire",
			k,
		)
	}
	testing.expect(
		t,
		strings.contains(string(content), "pre_alias_add:n=v"),
		"{value} filled on add",
	)
}
