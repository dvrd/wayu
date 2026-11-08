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
//   install   — build + copy to /usr/local/bin + wayu init
//   dev       — debug build + run with remaining args
//   release   — test + commit + tag + atomic push of main and the tag
//               (the push to main runs bump.yml: CI, then publish + Homebrew)
//   docs      — sync docs/index.html + README.md version from src/main.odin
//   help      — show available targets

package main

import "core:fmt"
import "core:os"
import "core:strings"
import bld "../bld"

SRC_DIR     :: "src"
BIN_DIR     :: "bin"
BINARY_NAME :: "wayu"
TEST_DIR    :: "tests/unit"

// Computed paths — avoids repeating fmt.tprintf("%s/%s", ...) everywhere.
bin_path :: proc() -> string {
	return fmt.tprintf("%s/%s", BIN_DIR, BINARY_NAME)
}

debug_path :: proc() -> string {
	return fmt.tprintf("%s/%s_debug", BIN_DIR, BINARY_NAME)
}

main :: proc() {
	bld.go_rebuild_urself("build")

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
	if err != nil { return }
	pin := strings.trim_space(string(data))
	series := strings.trim_right(pin, "abcdefghijklmnopqrstuvwxyz")
	if series == "" { return }

	cmd := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&cmd, "odin", "version")
	out, ok := bld.cmd_run_capture(&cmd, context.temp_allocator)
	if !ok { return }
	have := strings.trim_space(string(out))
	if strings.contains(have, series) { return }
	bld.log_warn("Odin is '%s' but wayu pins %s (see %s).", have, pin, ODIN_PIN_FILE)
	bld.log_warn("Install it from https://github.com/odin-lang/Odin/releases/tag/%s", pin)
}

do_build :: proc() {
	bld.log_info("Building %s (optimized)...", BINARY_NAME)
	bld.mkdir_if_not_exists(BIN_DIR)
	ok := bld.build({
		package_path = SRC_DIR,
		out          = bin_path(),
		opt          = .Speed,
	})
	if !ok {
		bld.log_error("Build failed")
		os.exit(1)
	}
	bld.log_info("Built %s", bin_path())
}

do_debug :: proc() {
	bld.log_info("Building %s (debug)...", BINARY_NAME)
	bld.mkdir_if_not_exists(BIN_DIR)
	ok := bld.build({
		package_path = SRC_DIR,
		out          = debug_path(),
		debug        = true,
	})
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
	test_home := fmt.tprintf("/tmp/wayu_unit_home_%d", os.get_pid())
	os.remove_all(test_home)
	os.make_directory_all(test_home)
	real_home, had_home := os.lookup_env("HOME", context.temp_allocator)
	os.set_env("HOME", test_home)
	defer {
		if had_home {
			os.set_env("HOME", real_home)
		} else {
			os.unset_env("HOME")
		}
		os.remove_all(test_home)
	}
	// The test runner reports progress, per-test logs, leaks and the names of
	// failed tests on stderr, which is passed through. The tested code's own
	// stdout (CLI output, TUI escape sequences — some query the terminal and
	// would inject replies into its input) goes to a log, shown on failure.
	stdout_log := fmt.tprintf("%s/unit-tests.stdout.log", test_home)
	defines := make([dynamic]bld.Define, context.temp_allocator)
	append(&defines, bld.Define{name = "ODIN_TEST_THREADS", value = "1"})
	if len(names) > 0 {
		append(&defines, bld.Define{name = "ODIN_TEST_NAMES", value = names})
	}
	ok := bld.test({
		package_path = TEST_DIR,
		file_mode    = true,
		opt          = .Speed,
		defines      = defines[:],
		ignore_unused_defineables = true,
	}, {stdout_path = stdout_log})
	if !ok {
		show_test_stdout(stdout_log)
	}
	return ok
}

// On failure: keep the tested code's stdout as bin/unit-tests.stdout.log
// (the sandbox is removed) and print its tail.
show_test_stdout :: proc(stdout_log: string) {
	TAIL_LINES :: 40
	kept := fmt.tprintf("%s/unit-tests.stdout.log", BIN_DIR)
	data, err := os.read_entire_file_from_path(stdout_log, context.temp_allocator)
	if err != nil || len(data) == 0 { return }
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
	tmp := fmt.tprintf("/tmp/wayu_build_git_%d", os.get_pid())
	defer os.remove(tmp)
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

do_install :: proc() {
	do_build()

	install_path := fmt.tprintf("/usr/local/bin/%s", BINARY_NAME)
	bld.log_info("Installing to %s...", install_path)

	ok := bld.copy_file(bin_path(), install_path)
	if !ok {
		bld.log_error("Failed to copy binary to /usr/local/bin/")
		os.exit(1)
	}

	// copy_file doesn't preserve permissions — make executable.
	chmod := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&chmod, "chmod", "+x", install_path)
	bld.cmd_run(&chmod)

	// Run the already-built binary instead of recompiling from source.
	bld.log_info("Running %s init...", BINARY_NAME)
	init_cmd := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&init_cmd, bin_path(), "init")
	if !bld.cmd_run(&init_cmd) {
		bld.log_error("Init failed")
		os.exit(1)
	}

	bld.log_info("Installed successfully")
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
			bld.log_error("git-cliff not found — either install it (cargo install git-cliff) or provide an explicit version: ./build_it release <version>")
			os.exit(1)
		}
		bld.log_info("Auto-detecting next version with git-cliff...")
		tmp_file := "/tmp/wayu_next_version"
		bump_cmd := bld.cmd_create(context.temp_allocator)
		bld.cmd_append(&bump_cmd, "sh", "-c", fmt.tprintf("git-cliff --bumped-version > %s", tmp_file))
		if !bld.cmd_run(&bump_cmd) {
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
		bld.log_error("HOME not restored after tests (%s, expected %s) — aborting release", home_after, home_before)
		os.exit(1)
	}

	// 3. Generate CHANGELOG and update VERSION in src/main.odin
	if !cliff_available {
		bld.log_error("git-cliff not found — cannot generate CHANGELOG (install: cargo install git-cliff)")
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
	quote_end   := strings.index(main_odin_src[quote_start:], `"`)
	if quote_end == -1 {
		bld.log_error("Malformed VERSION line in %s", main_odin_path)
		os.exit(1)
	}
	old_version := main_odin_src[quote_start : quote_start + quote_end]
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
	git_must("git add", "add", "CHANGELOG.md", "src/main.odin", "docs/index.html", "README.md")
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

	bld.log_info("Release %s pushed — bump.yml will run CI, then build, publish, and update the Homebrew tap", version)
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

// Generic version sync: find old_ver via marker string, replace all old→new.
sync_file_version :: proc(path: string, marker: string, new_ver: string) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		bld.log_error("Failed to read %s", path)
		os.exit(1)
	}
	content := string(data)

	idx := strings.index(content, marker)
	if idx == -1 {
		bld.log_error("Could not find version marker in %s", path)
		os.exit(1)
	}
	old_start := idx + len(marker)
	// Find the end delimiter: first char that isn't part of a semver
	old_end := 0
	for old_end < len(content[old_start:]) {
		c := content[old_start + old_end]
		if c >= '0' && c <= '9' || c == '.' {
			old_end += 1
		} else {
			break
		}
	}
	if old_end == 0 {
		bld.log_error("Malformed version after marker in %s", path)
		os.exit(1)
	}
	old_ver := content[old_start : old_start + old_end]

	if old_ver == new_ver {
		bld.log_info("%s already at v%s", path, new_ver)
		return
	}

	updated, _ := strings.replace_all(content, old_ver, new_ver)
	werr := os.write_entire_file(path, transmute([]byte)updated)
	if werr != nil {
		bld.log_error("Failed to write %s", path)
		os.exit(1)
	}

	count := strings.count(content, old_ver)
	bld.log_info("%s: %s → %s (%d replacements)", path, old_ver, new_ver, count)
}

// Sync version into docs/index.html and README.md.
sync_docs_version_str :: proc(new_ver: string) {
	// docs/index.html — anchor on the nav badge aria-label
	sync_file_version("docs/index.html", `aria-label="Version `, new_ver)
	// README.md — anchor on the bold version tag at the top
	sync_file_version("README.md", "**v", new_ver)
}

// Standalone entry point: read VERSION from source, patch docs + README.
sync_docs_version :: proc() {
	ver := read_source_version()
	sync_docs_version_str(ver)
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
	fmt.println("  install   Build + install to /usr/local/bin + wayu init")
	fmt.println("  dev       Debug build + run (extra args passed through)")
	fmt.println("  release   Run tests, commit + tag, push to main (bump.yml publishes after CI)")
	fmt.println("  docs      Sync docs/index.html + README.md version from src/main.odin")
	fmt.println("  help      Show this help")
	fmt.println("")
	fmt.println("Bootstrap:")
	fmt.println("  odin build build -out:build_it && ./build_it")
}
