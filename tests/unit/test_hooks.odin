package test_wayu

import "core:testing"
import "core:os"
import "core:strings"
import "core:fmt"
import wayu "../../src"

// Verifies the plugin-install hook wrappers actually fire the configured
// shell command and substitute the {name} placeholder. Regression guard for
// the wiring of hook_pre_plugin_install / hook_post_plugin_install into the
// `wayu plugin add` flow (CLI + TUI).
@(test)
test_plugin_install_hooks_fire :: proc(t: ^testing.T) {
	tmp := "/tmp/wayu_test_hooks_plugin"
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
	tmp := "/tmp/wayu_test_hooks_absent"
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

	r2 := wayu.hook_render_command(`echo "n={name} v={value}"`)
	defer delete(r2)
	testing.expect_value(t, r2, `echo "n=${WAYU_HOOK_NAME} v=${WAYU_HOOK_VALUE}"`)

	// Inside '...' the reference is left for an inner shell (OKAMI-230).
	r3, single := wayu.hook_render_command_ex(`sh -c 'echo {path} >> log'`)
	defer delete(r3)
	testing.expect_value(t, r3, `sh -c 'echo "${WAYU_HOOK_PATH}" >> log'`)
	testing.expect(t, single, "single-quoted placeholder reported")
}

// OKAMI-230: values reaching a nested shell (`sh -c '... {path}'`) stay data.
@(test)
test_hook_nested_shell_cannot_inject :: proc(t: ^testing.T) {
	tmp := "/tmp/wayu_test_hooks_nested"
	os.remove_all(tmp)
	testing.expect(t, os.make_directory(tmp) == nil)
	defer os.remove_all(tmp)

	saved_config := wayu.wayu.config
	wayu.wayu.config = tmp
	defer wayu.wayu.config = saved_config

	log_path := fmt.tprintf("%s/hook.log", tmp)
	pwned := fmt.tprintf("%s/PWNED", tmp)
	conf := fmt.tprintf("post_path_remove = sh -c 'echo rm {{path}} >> %s'\n", log_path)
	testing.expect(t, wayu.safe_write_file(fmt.tprintf("%s/hooks.conf", tmp), transmute([]byte)conf))

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
	tmp := "/tmp/wayu_test_hooks_inject"
	os.remove_all(tmp)
	testing.expect(t, os.make_directory(tmp) == nil)
	defer os.remove_all(tmp)

	saved_config := wayu.wayu.config
	wayu.wayu.config = tmp
	defer wayu.wayu.config = saved_config

	log_path := fmt.tprintf("%s/hook.log", tmp)
	pwned := fmt.tprintf("%s/PWNED", tmp)
	conf := fmt.tprintf("post_alias_add = \"echo {{name}}={{value}} >> %s; echo 'q:{{name}}' >> %s\"\n", log_path, log_path)
	testing.expect(t, wayu.safe_write_file(fmt.tprintf("%s/hooks.conf", tmp), transmute([]byte)conf))

	evil := fmt.tprintf("x; touch %s", pwned)
	wayu.hook_post_alias_add(evil, "$(touch PWNED2) v")

	content, ok := wayu.safe_read_file(log_path)
	testing.expect(t, ok, "hook should have run")
	defer delete(content)
	testing.expect(t, !os.exists(pwned), "name must not be executed as shell code")
	testing.expect(t, strings.contains(string(content), evil), "name passed through literally")
	testing.expect(t, strings.contains(string(content), "$(touch PWNED2) v"), "{value} filled literally")
	// Top-level '...' is not substituted (left for an inner shell).
	testing.expect(t, strings.contains(string(content), `q:"${WAYU_HOOK_NAME}"`), "single-quoted placeholder left as reference")
}

@(test)
test_hooks_skipped_in_dry_run :: proc(t: ^testing.T) {
	tmp := "/tmp/wayu_test_hooks_dryrun"
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
	testing.expect(t, wayu.safe_write_file(fmt.tprintf("%s/hooks.conf", tmp), transmute([]byte)conf))

	wayu.hook_pre_path_add("/x")
	testing.expect(t, !os.exists(log_path), "hooks must not run under --dry-run")
}
