// wayu build script — replaces Taskfile.yml
//
// Bootstrap:
//   odin build build -out:build_it && ./build_it <target>
//
// Targets:
//   build     — optimized release build (default)
//   debug     — debug build with symbols
//   test      — run unit tests
//   check     — type-check only
//   clean     — remove build artifacts
//   install   — build + copy to $PREFIX/bin (default ~/.local/bin) + wayu init;
//               refuses while Homebrew manages wayu unless --force
//   dev       — debug build + run with remaining args
//   release   — test + commit + tag + atomic push of main and the tag
//               (the push to main runs bump.yml: CI, then publish + Homebrew)
//   docs      — sync docs/index.html + README.md version from src/main.odin
//               (--check: verify only, exit 1 on drift)
//   help      — show available targets

package main

import bld "../bld"
import "core:fmt"
import "core:os"
import "core:strings"

SRC_DIR :: "src"
BIN_DIR :: "bin"
BINARY_NAME :: "wayu"
TEST_DIR :: "tests/unit"

// Computed paths — avoids repeating fmt.tprintf("%s/%s", ...) everywhere.
bin_path :: proc() -> string {
	return fmt.tprintf("%s/%s", BIN_DIR, BINARY_NAME)
}

debug_path :: proc() -> string {
	return fmt.tprintf("%s/%s_debug", BIN_DIR, BINARY_NAME)
}

main :: proc() {
	bld.go_rebuild_urself("build", "bld")

	target := "build"
	if len(os.args) > 1 {
		target = os.args[1]
	}

	switch target {
	case "build", "debug", "test", "check", "install", "dev", "release":
		warn_if_odin_unpinned()
	}

	switch target {
	case "build":
		do_build()
	case "debug":
		do_debug()
	case "test":
		do_test()
	case "check":
		do_check()
	case "clean":
		do_clean()
	case "install":
		do_install()
	case "dev":
		do_dev()
	case "release":
		do_release()
	case "docs":
		sync_docs_version()
	case "help":
		do_help()
	case:
		bld.log_error("Unknown target: %s", target)
		do_help()
		os.exit(1)
	}
}

// The Odin release wayu is built and released with (CI + release builds).
ODIN_PIN_FILE :: ".github/odin-release"

// Warn (never fail) when the local `odin` isn't the pinned release series.
// Release tags look like dev-2026-11a while `odin version` prints
// dev-2026-11:<hash>, so the comparison is on the dev-YYYY-MM series.
warn_if_odin_unpinned :: proc() {
	data, err := os.read_entire_file_from_path(ODIN_PIN_FILE, context.temp_allocator)
	if err != nil {
		return
	}
	pin := strings.trim_space(string(data))
	series := strings.trim_right(pin, "abcdefghijklmnopqrstuvwxyz")
	if series == "" {
		return
	}

	cmd := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&cmd, "odin", "version")
	out, ok := bld.cmd_run_capture(&cmd, context.temp_allocator)
	if !ok {
		return
	}
	have := strings.trim_space(string(out))
	if strings.contains(have, series) {
		return
	}
	bld.log_warn("Odin is '%s' but wayu pins %s (see %s).", have, pin, ODIN_PIN_FILE)
	bld.log_warn("Install it from https://github.com/odin-lang/Odin/releases/tag/%s", pin)
}

// bump.yml's "Install git-cliff" step pins CLIFF_VERSION; a local release
// must use the same git-cliff, or the version bump and CHANGELOG can differ
// from what CI would produce.
CLIFF_PIN_FILE :: ".github/workflows/bump.yml"

// Exit unless `git-cliff --version` is the version bump.yml pins.
require_pinned_git_cliff :: proc() {
	data, err := os.read_entire_file_from_path(CLIFF_PIN_FILE, context.temp_allocator)
	if err != nil {
		bld.log_error("Cannot read %s for the pinned git-cliff version", CLIFF_PIN_FILE)
		os.exit(1)
	}
	pin := ""
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "CLIFF_VERSION:") {
			pin = strings.trim_space(l[len("CLIFF_VERSION:"):])
			break
		}
	}
	if pin == "" {
		bld.log_error("No CLIFF_VERSION in %s", CLIFF_PIN_FILE)
		os.exit(1)
	}

	cmd := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&cmd, "git-cliff", "--version")
	out, ok := bld.cmd_run_capture(&cmd, context.temp_allocator)
	have := strings.trim_space(string(out))
	if !ok || have != fmt.tprintf("git-cliff %s", pin) {
		bld.log_error(
			"git-cliff is '%s' but releases use git-cliff %s (CLIFF_VERSION in %s)",
			have,
			pin,
			CLIFF_PIN_FILE,
		)
		bld.log_error("Install it from https://github.com/orhun/git-cliff/releases/tag/v%s", pin)
		os.exit(1)
	}
}

// The oldest macOS the binaries run on (LC_BUILD_VERSION minos). Without
// -minimum-os-version Odin stamps the build host's version, so a release
// built on a new runner refused to start on older macOS. CI checks the
// released binary against this file (.github/scripts/check-macos-minos.sh).
MACOS_MIN_VERSION_FILE :: ".github/macos-minimum-version"

// Extra compiler flags for this host: -minimum-os-version on macOS.
platform_flags :: proc() -> []string {
	when ODIN_OS == .Darwin {
		data, err := os.read_entire_file_from_path(MACOS_MIN_VERSION_FILE, context.temp_allocator)
		version := strings.trim_space(string(data))
		if err != nil || version == "" {
			bld.log_error("Cannot read the macOS minimum version from %s", MACOS_MIN_VERSION_FILE)
			os.exit(1)
		}
		flags := make([]string, 1, context.temp_allocator)
		flags[0] = fmt.tprintf("-minimum-os-version:%s", version)
		return flags
	} else {
		return nil
	}
}

do_build :: proc() {
	bld.log_info("Building %s (optimized)...", BINARY_NAME)
	bld.mkdir_if_not_exists(BIN_DIR)
	ok := bld.build(
		{package_path = SRC_DIR, out = bin_path(), opt = .Speed, extra_flags = platform_flags()},
	)
	if !ok {
		bld.log_error("Build failed")
		os.exit(1)
	}
	bld.log_info("Built %s", bin_path())
}

do_debug :: proc() {
	bld.log_info("Building %s (debug)...", BINARY_NAME)
	bld.mkdir_if_not_exists(BIN_DIR)
	ok := bld.build(
		{package_path = SRC_DIR, out = debug_path(), debug = true, extra_flags = platform_flags()},
	)
	if !ok {
		bld.log_error("Debug build failed")
		os.exit(1)
	}
	bld.log_info("Built %s", debug_path())
}

do_test :: proc() {
	// `./build_it test NAME[,NAME...]` runs only those tests
	// (package-qualified names, e.g. test_wayu.test_path_add).
	names := os.args[2] if len(os.args) > 2 else ""
	if !run_unit_tests(names) {
		bld.log_error("Tests failed")
		os.exit(1)
	}
	bld.log_info("All tests passed")
}

// Run the unit tests with HOME sandboxed, then restore HOME and remove the
// sandbox before returning. Returns instead of exiting so the restore and
// cleanup always run; do_release runs git afterwards and needs the real HOME
// for ~/.gitconfig (identity, commit signing, credential helper).
run_unit_tests :: proc(names := "") -> bool {
	bld.log_info("Running unit tests...")
	bld.mkdir_if_not_exists(BIN_DIR)
	// Sandbox HOME so no test can ever write into the real ~/.config/wayu
	// (several tests swap the global config dir; a missed restore used to
	// leak fixture plugins into the user's plugins.json).
	test_home, home_ok := make_private_tmp_dir("wayu_unit_home_*")
	if !home_ok {
		return false
	}
	real_home, had_home := os.lookup_env("HOME", context.temp_allocator)
	os.set_env("HOME", test_home)
	// Tests put scratch files under this per-run root (tests/unit/test_tmp.odin),
	// removed with the sandbox: concurrent runs never share a /tmp path.
	os.set_env("WAYU_TEST_TMPDIR", fmt.tprintf("%s/tmp", test_home))
	defer {
		if had_home {
			os.set_env("HOME", real_home)
		} else {
			os.unset_env("HOME")
		}
		os.unset_env("WAYU_TEST_TMPDIR")
		remove_private_tmp_dir(test_home)
	}
	// The test runner reports progress, per-test logs, leaks and the names of
	// failed tests on stderr, which is passed through. The tested code's own
	// stdout (CLI output, TUI escape sequences — some query the terminal and
	// would inject replies into its input) goes to a log, shown on failure.
	stdout_log := fmt.tprintf("%s/unit-tests.stdout.log", test_home)
	defines := make([dynamic]bld.Define, context.temp_allocator)
	append(&defines, bld.Define{name = "ODIN_TEST_THREADS", value = "1"})
	// A leak or bad free (tracking allocator, on by default) fails the
	// test instead of only printing a warning.
	append(&defines, bld.Define{name = "ODIN_TEST_FAIL_ON_BAD_MEMORY", value = "true"})
	if len(names) > 0 {
		append(&defines, bld.Define{name = "ODIN_TEST_NAMES", value = names})
	}
	ok := bld.test(
	{
		package_path              = TEST_DIR,
		// Per-run binary: odin test otherwise writes ./unit in the cwd, which
		// concurrent runs in one checkout would overwrite mid-run.
		out                       = fmt.tprintf("%s/wayu_unit_tests", test_home),
		file_mode                 = true,
		opt                       = .Speed,
		defines                   = defines[:],
		ignore_unused_defineables = true,
	},
	{stdout_path = stdout_log},
	)
	if !ok {
		show_test_stdout(stdout_log)
	}
	return ok
}

// A fresh private scratch dir: mkdtemp under $TMPDIR (else /tmp), then 0700.
// Never a fixed, guessable /tmp name: another local user could create it
// first (or a symlink in its place) and have our writes, or the cleanup's
// remove_all, land on files they choose. Logs and returns false on failure.
make_private_tmp_dir :: proc(pattern: string) -> (string, bool) {
	dir, err := os.make_directory_temp("", pattern, context.temp_allocator)
	if err != nil {
		bld.log_error("Cannot create a private temp dir (%s): %v", pattern, err)
		return "", false
	}
	if os.chmod(dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		bld.log_error("Cannot make %s private", dir)
		remove_private_tmp_dir(dir)
		return "", false
	}
	return dir, true
}

// Remove a dir made by make_private_tmp_dir, only while it is still a plain
// directory: remove_all follows a symlink at the top, so a path swapped for a
// link is left alone.
remove_private_tmp_dir :: proc(dir: string) {
	fi, err := os.lstat(dir, context.temp_allocator)
	if err != nil {
		return
	}
	if fi.type != .Directory {
		bld.log_error("Not removing %s: no longer a plain directory", dir)
		return
	}
	os.remove_all(dir)
}

// On failure: keep the tested code's stdout as bin/unit-tests.stdout.log
// (the sandbox is removed) and print its tail.
show_test_stdout :: proc(stdout_log: string) {
	TAIL_LINES :: 40
	kept := fmt.tprintf("%s/unit-tests.stdout.log", BIN_DIR)
	data, err := os.read_entire_file_from_path(stdout_log, context.temp_allocator)
	if err != nil || len(data) == 0 {
		return
	}
	_ = os.write_entire_file(kept, data)
	lines := strings.split_lines(strings.trim_right(string(data), "\n"), context.temp_allocator)
	from := max(0, len(lines) - TAIL_LINES)
	fmt.eprintfln("---- last %d lines of test stdout (full log: %s) ----", len(lines) - from, kept)
	for line in lines[from:] {
		// Show escape sequences instead of sending them: some (cursor
		// position queries) make the terminal type a reply into its input.
		safe, _ := strings.replace_all(line, "\x1b", "^[", context.temp_allocator)
		fmt.eprintln(safe)
	}
	fmt.eprintln("---- end of test stdout ----")
}

// Run `git <args>`; true on exit status 0.
git_ok :: proc(args: ..string) -> bool {
	cmd := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&cmd, "git")
	bld.cmd_append(&cmd, ..args)
	return bld.cmd_run(&cmd)
}

// Run `git <args>`; abort the release naming `what` on failure.
git_must :: proc(what: string, args: ..string) {
	if !git_ok(..args) {
		bld.log_error("%s failed — aborting release", what)
		os.exit(1)
	}
}

// Run `git <args>` and return its trimmed stdout.
git_output :: proc(args: ..string) -> (out: string, ok: bool) {
	tmp_dir, dir_ok := make_private_tmp_dir("wayu_build_git_*")
	if !dir_ok {
		return "", false
	}
	defer remove_private_tmp_dir(tmp_dir)
	tmp := fmt.tprintf("%s/out", tmp_dir)
	cmd := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&cmd, "git")
	bld.cmd_append(&cmd, ..args)
	if !bld.cmd_run(&cmd, {stdout_path = tmp}) {
		return "", false
	}
	data, err := os.read_entire_file_from_path(tmp, context.temp_allocator)
	if err != nil {
		return "", false
	}
	return strings.trim_space(string(data)), true
}

do_check :: proc() {
	bld.log_info("Checking code...")
	ok := bld.check({package_path = SRC_DIR})
	if !ok {
		bld.log_error("Check failed")
		os.exit(1)
	}
	bld.log_info("Check passed")
}

do_clean :: proc() {
	bld.log_info("Cleaning build artifacts...")
	bld.remove_all(BIN_DIR)
	bld.mkdir_if_not_exists(BIN_DIR)
	bld.log_info("Clean complete")
}

// Install directory: $PREFIX/bin when PREFIX is set, else ~/.local/bin.
// Never /usr/local/bin by default: it is root-owned on many Macs (and
// `sudo ./build_it install` would then run `wayu init` as root), and on
// Apple Silicon Homebrew's /opt/homebrew/bin precedes it on PATH.
install_dir :: proc() -> (dir: string, ok: bool) {
	if prefix, found := os.lookup_env("PREFIX", context.temp_allocator); found && len(prefix) > 0 {
		return fmt.tprintf("%s/bin", strings.trim_right(prefix, "/")), true
	}
	home, found := os.lookup_env("HOME", context.temp_allocator)
	if !found || len(home) == 0 {
		return "", false
	}
	return fmt.tprintf("%s/.local/bin", home), true
}

// A wayu installed by Homebrew: <prefix>/bin/wayu is a symlink into
// <prefix>/Cellar/wayu/. Returns the link path, "" when there is none.
homebrew_wayu :: proc() -> string {
	prefixes := make([dynamic]string, context.temp_allocator)
	if p, found := os.lookup_env("HOMEBREW_PREFIX", context.temp_allocator); found && len(p) > 0 {
		append(&prefixes, p)
	}
	append(&prefixes, "/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew")
	for prefix in prefixes {
		link := fmt.tprintf("%s/bin/%s", prefix, BINARY_NAME)
		target, err := os.read_link(link, context.temp_allocator)
		if err == nil && strings.contains(target, "Cellar/wayu/") {
			return link
		}
	}
	return ""
}

// The first executable `wayu` on $PATH ("" when none).
wayu_on_path :: proc() -> string {
	path_env, _ := os.lookup_env("PATH", context.temp_allocator)
	for dir in strings.split(path_env, ":", context.temp_allocator) {
		if len(dir) == 0 {
			continue
		}
		candidate := fmt.tprintf("%s/%s", strings.trim_right(dir, "/"), BINARY_NAME)
		if fi, err := os.stat(candidate, context.temp_allocator);
		   err == nil && fi.type != .Directory {
			return candidate
		}
	}
	return ""
}

// install [--force]: build, copy to install_dir() via temp file + rename
// (never rewrite a signed binary in place: macOS kills it on next exec),
// then `wayu init`. Refuses while Homebrew manages a wayu unless --force.
do_install :: proc() {
	force := false
	for i := 2; i < len(os.args); i += 1 {
		switch os.args[i] {
		case "--force":
			force = true
		case:
			bld.log_error(
				"Unknown install option '%s' (usage: ./build_it install [--force])",
				os.args[i],
			)
			os.exit(1)
		}
	}

	dir, dir_ok := install_dir()
	if !dir_ok {
		bld.log_error("Neither PREFIX nor HOME is set; cannot choose an install directory")
		os.exit(1)
	}
	install_path := fmt.tprintf("%s/%s", dir, BINARY_NAME)

	if brew := homebrew_wayu(); len(brew) > 0 && !force {
		bld.log_error("wayu is installed by Homebrew (%s).", brew)
		bld.log_error("A second, dev-built wayu would fight it for PATH precedence and")
		bld.log_error("Homebrew upgrades would not touch it. Either:")
		bld.log_error("  brew uninstall wayu && ./build_it install")
		bld.log_error("  ./build_it install --force     # install to %s anyway", install_path)
		bld.log_error("  ./build_it && ./bin/wayu ...   # or just run the build in place")
		os.exit(1)
	}

	do_build()

	if !os.is_dir(dir) {
		if err := os.make_directory_all(dir); err != nil {
			bld.log_error("Cannot create %s: %v", dir, err)
			os.exit(1)
		}
	}

	bld.log_info("Installing to %s...", install_path)
	tmp_path := fmt.tprintf("%s/.%s.install-%d", dir, BINARY_NAME, os.get_pid())
	if !bld.copy_file(bin_path(), tmp_path) {
		os.remove(tmp_path)
		bld.log_error(
			"Failed to copy the binary into %s (permissions? set PREFIX to another directory)",
			dir,
		)
		os.exit(1)
	}
	// copy_file doesn't preserve permissions; 0755 before it becomes visible.
	if err := os.chmod(tmp_path, os.perm_number(0o755)); err != nil {
		os.remove(tmp_path)
		bld.log_error("Failed to make %s executable: %v", tmp_path, err)
		os.exit(1)
	}
	// rename() replaces the old binary atomically (new inode).
	if err := os.rename(tmp_path, install_path); err != nil {
		os.remove(tmp_path)
		bld.log_error("Failed to install %s: %v", install_path, err)
		os.exit(1)
	}

	// Run the already-built binary instead of recompiling from source.
	bld.log_info("Running %s init...", BINARY_NAME)
	init_cmd := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&init_cmd, bin_path(), "init")
	if !bld.cmd_run(&init_cmd) {
		bld.log_error("Init failed")
		os.exit(1)
	}

	bld.log_info("Installed %s", install_path)
	// Say so when a shell would not run what was just installed.
	if found := wayu_on_path(); found == "" {
		bld.log_warn("%s is not on your PATH; add it to use the installed wayu", dir)
	} else if found != install_path {
		bld.log_warn(
			"`wayu` on your PATH is %s, which shadows %s; put %s earlier in PATH",
			found,
			install_path,
			dir,
		)
	}
}

do_dev :: proc() {
	do_debug()

	bld.log_info("Running %s...", debug_path())

	// Run the already-built debug binary instead of recompiling.
	// Pass remaining args (os.args[2:]) directly — no dynamic array needed.
	cmd := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&cmd, debug_path())
	for i := 2; i < len(os.args); i += 1 {
		bld.cmd_append(&cmd, os.args[i])
	}
	if !bld.cmd_run(&cmd) {
		os.exit(1)
	}
}

do_release :: proc() {
	version: string

	// Check if git-cliff is available
	cliff_check := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&cliff_check, "which", "git-cliff")
	cliff_available := bld.cmd_run(&cliff_check)
	if cliff_available {
		require_pinned_git_cliff()
	}

	if len(os.args) >= 3 {
		// Version provided explicitly
		version = os.args[2]
		// Validate format: must start with 'v' followed by digits/dots
		if len(version) < 2 || version[0] != 'v' {
			bld.log_error("Version must start with 'v' (e.g. v3.2.0), got: %s", version)
			os.exit(1)
		}
	} else {
		// Auto-detect next version via git-cliff --bumped-version
		if !cliff_available {
			bld.log_error(
				"git-cliff not found — either install it (cargo install git-cliff) or provide an explicit version: ./build_it release <version>",
			)
			os.exit(1)
		}
		bld.log_info("Auto-detecting next version with git-cliff...")
		tmp_dir, dir_ok := make_private_tmp_dir("wayu_next_version_*")
		if !dir_ok {
			os.exit(1)
		}
		defer remove_private_tmp_dir(tmp_dir)
		tmp_file := fmt.tprintf("%s/version", tmp_dir)
		bump_cmd := bld.cmd_create(context.temp_allocator)
		bld.cmd_append(&bump_cmd, "git-cliff", "--bumped-version")
		if !bld.cmd_run(&bump_cmd, {stdout_path = tmp_file}) {
			bld.log_error("git-cliff --bumped-version failed")
			os.exit(1)
		}
		raw, read_err := os.read_entire_file_from_path(tmp_file, context.allocator)
		if read_err != nil {
			bld.log_error("Failed to read version from %s", tmp_file)
			os.exit(1)
		}
		version = strings.trim_space(string(raw))
		if len(version) < 2 || version[0] != 'v' {
			bld.log_error("git-cliff returned unexpected version: %s", version)
			os.exit(1)
		}
		bld.log_info("Auto-detected next version: %s", version)
	}

	bld.log_info("Releasing %s...", version)

	// 1. Preflight — everything checkable before touching any file.
	bld.log_info("Checking working tree is clean...")
	if !git_ok("diff", "--exit-code") {
		bld.log_error("Working tree has unstaged changes — commit or stash before releasing")
		os.exit(1)
	}
	if !git_ok("diff", "--cached", "--exit-code") {
		bld.log_error("Working tree has staged changes — commit before releasing")
		os.exit(1)
	}
	branch, branch_ok := git_output("rev-parse", "--abbrev-ref", "HEAD")
	if !branch_ok || branch != "main" {
		bld.log_error("Releases are cut from main (current branch: %s)", branch)
		os.exit(1)
	}
	git_must("git fetch origin", "fetch", "--tags", "origin", "main")
	if !git_ok("merge-base", "--is-ancestor", "origin/main", "HEAD") {
		bld.log_error("Local main is behind or diverged from origin/main — pull/rebase first")
		os.exit(1)
	}
	if git_ok("rev-parse", "-q", "--verify", fmt.tprintf("refs/tags/%s", version)) {
		bld.log_error("Tag %s already exists", version)
		os.exit(1)
	}

	// 2. Run tests — abort if any fail.
	home_before, _ := os.lookup_env("HOME", context.temp_allocator)
	if !run_unit_tests() {
		bld.log_error("Tests failed — aborting release")
		os.exit(1)
	}
	// The git commands below must see the real HOME (identity, signing, credentials).
	home_after, _ := os.lookup_env("HOME", context.temp_allocator)
	if home_after != home_before {
		bld.log_error(
			"HOME not restored after tests (%s, expected %s) — aborting release",
			home_after,
			home_before,
		)
		os.exit(1)
	}

	// 3. Generate CHANGELOG and update VERSION in src/main.odin
	if !cliff_available {
		bld.log_error(
			"git-cliff not found — cannot generate CHANGELOG (install: cargo install git-cliff)",
		)
		os.exit(1)
	}

	// 3a. Generate CHANGELOG with git-cliff
	bld.log_info("Generating CHANGELOG with git-cliff...")
	cliff_cmd := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&cliff_cmd, "git-cliff", "--tag", version, "-o", "CHANGELOG.md")
	if !bld.cmd_run(&cliff_cmd) {
		bld.log_error("git-cliff failed")
		os.exit(1)
	}

	// 3a'. Name docs/UPGRADING.md's "## Unreleased" section after the version
	//      (the release notes take their upgrade notes from it), like bump.yml.
	upgrading_cmd := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&upgrading_cmd, ".github/scripts/upgrading-version.sh", version)
	if !bld.cmd_run(&upgrading_cmd) {
		bld.log_error("upgrading-version.sh failed")
		os.exit(1)
	}

	// 3b. Update VERSION in src/main.odin
	bld.log_info("Updating VERSION in src/main.odin...")
	main_odin_path := "src/main.odin"
	main_odin_data, read_err := os.read_entire_file_from_path(main_odin_path, context.allocator)
	if read_err != nil {
		bld.log_error("Failed to read %s", main_odin_path)
		os.exit(1)
	}
	main_odin_src := string(main_odin_data)

	// Strip leading 'v' to get bare version number (e.g. "3.2.0")
	version_bare := version[1:]

	// Find and replace the existing VERSION line
	// Pattern: VERSION :: "X.Y.Z" — we replace everything between the quotes
	old_prefix := `VERSION :: "`
	start_idx := strings.index(main_odin_src, old_prefix)
	if start_idx == -1 {
		bld.log_error("Could not find VERSION :: line in %s", main_odin_path)
		os.exit(1)
	}
	quote_start := start_idx + len(old_prefix)
	quote_end := strings.index(main_odin_src[quote_start:], `"`)
	if quote_end == -1 {
		bld.log_error("Malformed VERSION line in %s", main_odin_path)
		os.exit(1)
	}
	old_version := main_odin_src[quote_start:quote_start + quote_end]
	old_version_line := fmt.tprintf(`VERSION :: "%s"`, old_version)
	new_version_line := fmt.tprintf(`VERSION :: "%s"`, version_bare)

	updated_src, _ := strings.replace(main_odin_src, old_version_line, new_version_line, 1)
	write_err := os.write_entire_file(main_odin_path, transmute([]byte)updated_src)
	if write_err != nil {
		bld.log_error("Failed to write updated %s", main_odin_path)
		os.exit(1)
	}
	bld.log_info("Updated VERSION from %s to %s", old_version, version_bare)

	// 3c. Sync version into docs/index.html and README.md
	sync_docs_version_str(version_bare)

	// 3d. Commit CHANGELOG.md, src/main.odin, docs, and README together
	git_must(
		"git add",
		"add",
		"CHANGELOG.md",
		"src/main.odin",
		"docs/index.html",
		"docs/UPGRADING.md",
		"README.md",
	)
	git_must("git commit", "commit", "-m", fmt.tprintf("chore: release %s", version))

	// 4. Tag the release commit.
	bld.log_info("Creating tag %s...", version)
	git_must(fmt.tprintf("git tag %s", version), "tag", version)

	// 5. Push main and the tag atomically: both land or neither does, so
	//    origin never has a tag without its release commit (or vice versa).
	//    The push to main runs bump.yml (CI gate, then publish + Homebrew).
	bld.log_info("Pushing main + %s to origin...", version)
	if !git_ok("push", "--atomic", "origin", "main", fmt.tprintf("refs/tags/%s", version)) {
		bld.log_error("Push failed — nothing was pushed. Deleting local tag %s.", version)
		git_ok("tag", "-d", version)
		bld.log_error("The release commit is still local; undo with: git reset --hard HEAD~1")
		os.exit(1)
	}

	bld.log_info(
		"Release %s pushed — bump.yml will run CI, then build, publish, and update the Homebrew tap",
		version,
	)
	bld.log_info("Track progress at: https://github.com/dvrd/wayu/actions")
}

// ---------------------------------------------------------------------------
// docs — sync version from src/main.odin into docs + README
// ---------------------------------------------------------------------------

// Read the current VERSION from src/main.odin.
read_source_version :: proc() -> string {
	data, err := os.read_entire_file_from_path("src/main.odin", context.temp_allocator)
	if err != nil {
		bld.log_error("Failed to read src/main.odin")
		os.exit(1)
	}
	src := string(data)
	prefix :: `VERSION :: "`
	start := strings.index(src, prefix)
	if start == -1 {
		bld.log_error("VERSION line not found in src/main.odin")
		os.exit(1)
	}
	after := src[start + len(prefix):]
	end := strings.index(after, `"`)
	if end == -1 {
		bld.log_error("Malformed VERSION line")
		os.exit(1)
	}
	return after[:end]
}

// Where the release version appears outside src/main.odin. Only an X.Y.Z
// directly after one of these prefixes is rewritten or checked, so other
// version numbers in prose ("upgrading from 4.3.4") are never touched.
// A `required` anchor must be present, or the file's layout changed and the
// table needs updating.
Version_Anchor :: struct {
	path:     string,
	prefix:   string,
	required: bool,
}

VERSION_ANCHORS :: [?]Version_Anchor {
	{"README.md", "**v", true}, // **vX.Y.Z** under the title
	{"docs/index.html", `class="ver">v`, true}, // hero badge, announcement bar, footer
	{"docs/index.html", `">v`, false}, // any other ">vX.Y.Z" text
	{"docs/index.html", "wayu ", false}, // terminal demo "wayu X.Y.Z installed"
}

VERSION_FILES :: [?]string{"README.md", "docs/index.html"}

// Length of the X.Y.Z at the start of s, or 0 when s doesn't start with one.
semver_len :: proc(s: string) -> int {
	i := 0
	for part in 0 ..< 3 {
		start := i
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i += 1
		}
		if i == start {
			return 0
		}
		if part < 2 {
			if i >= len(s) || s[i] != '.' {
				return 0
			}
			i += 1
		}
	}
	return i
}

// Replace the X.Y.Z after every occurrence of prefix with new_ver. Returns the
// rewritten content and how many anchored versions were found; versions that
// differed from new_ver are appended to stale.
rewrite_anchored_versions :: proc(
	content, prefix, new_ver: string,
	stale: ^[dynamic]string,
) -> (
	out: string,
	found: int,
) {
	b := strings.builder_make(context.temp_allocator)
	rest := content
	for {
		idx := strings.index(rest, prefix)
		if idx == -1 {
			break
		}
		after := idx + len(prefix)
		strings.write_string(&b, rest[:after])
		rest = rest[after:]
		n := semver_len(rest)
		if n == 0 {
			continue
		}
		found += 1
		if rest[:n] != new_ver {
			append(stale, rest[:n])
		}
		strings.write_string(&b, new_ver)
		rest = rest[n:]
	}
	strings.write_string(&b, rest)
	return strings.to_string(b), found
}

// Sync README.md + docs/index.html to new_ver, or with check only report
// drift. Returns false when check finds a stale version.
sync_docs_version_str :: proc(new_ver: string, check := false) -> bool {
	ok := true
	for path in VERSION_FILES {
		data, err := os.read_entire_file_from_path(path, context.temp_allocator)
		if err != nil {
			bld.log_error("Failed to read %s", path)
			os.exit(1)
		}
		content := string(data)
		stale := make([dynamic]string, context.temp_allocator)
		for anchor in VERSION_ANCHORS {
			if anchor.path != path {
				continue
			}
			found: int
			content, found = rewrite_anchored_versions(content, anchor.prefix, new_ver, &stale)
			if anchor.required && found == 0 {
				bld.log_error(
					"%s: version marker '%sX.Y.Z' not found (update VERSION_ANCHORS in build/build.odin)",
					path,
					anchor.prefix,
				)
				os.exit(1)
			}
		}

		switch {
		case len(stale) == 0:
			bld.log_info("%s at v%s", path, new_ver)
		case check:
			bld.log_error(
				"%s says v%s but src/main.odin VERSION is %s — run ./build_it docs",
				path,
				stale[0],
				new_ver,
			)
			ok = false
		case:
			if os.write_entire_file(path, transmute([]byte)content) != nil {
				bld.log_error("Failed to write %s", path)
				os.exit(1)
			}
			bld.log_info("%s: v%s → v%s (%d replacements)", path, stale[0], new_ver, len(stale))
		}
	}
	return ok
}

// `./build_it docs [--check]`: sync README + docs to VERSION in src/main.odin.
// --check writes nothing and exits 1 on drift (CI "Release Readiness");
// bump.yml runs the plain form before committing a release.
sync_docs_version :: proc() {
	check := false
	for i := 2; i < len(os.args); i += 1 {
		switch os.args[i] {
		case "--check":
			check = true
		case:
			bld.log_error(
				"Unknown docs option '%s' (usage: ./build_it docs [--check])",
				os.args[i],
			)
			os.exit(1)
		}
	}
	if !sync_docs_version_str(read_source_version(), check) {
		os.exit(1)
	}
}

do_help :: proc() {
	fmt.println("wayu build system")
	fmt.println("")
	fmt.println("Usage: ./build_it <target>")
	fmt.println("")
	fmt.println("Targets:")
	fmt.println("  build     Optimized release build (default)")
	fmt.println("  debug     Debug build with symbols")
	fmt.println("  test      Run unit tests (optional: NAME[,NAME] to run only those)")
	fmt.println("  check     Type-check only")
	fmt.println("  clean     Remove build artifacts")
	fmt.println(
		"  install   Build + install to $PREFIX/bin (default ~/.local/bin) + wayu init [--force]",
	)
	fmt.println("  dev       Debug build + run (extra args passed through)")
	fmt.println("  release   Run tests, commit + tag, push to main (bump.yml publishes after CI)")
	fmt.println(
		"  docs      Sync docs/index.html + README.md version from src/main.odin [--check]",
	)
	fmt.println("  help      Show this help")
	fmt.println("")
	fmt.println("Bootstrap:")
	fmt.println("  odin build build -out:build_it && ./build_it")
}
