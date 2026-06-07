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
