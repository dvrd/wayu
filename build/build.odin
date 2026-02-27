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
//   release   — test + tag + push (triggers GitHub Actions → Homebrew)
//   help      — show available targets

package main

import "core:fmt"
import "core:os"
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
	case "help":
		do_help()
	case:
		bld.log_error("Unknown target: %s", target)
		do_help()
		os.exit(1)
	}
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
	bld.log_info("Running unit tests...")
	bld.mkdir_if_not_exists(BIN_DIR)
	ok := bld.test({
		package_path = TEST_DIR,
		file_mode    = true,
		opt          = .Speed,
		defines      = {
			{name = "ODIN_TEST_THREADS", value = "1"},
		},
		ignore_unused_defineables = true,
	})
	if !ok {
		bld.log_error("Tests failed")
		os.exit(1)
	}
	bld.log_info("All tests passed")
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
	if len(os.args) < 3 {
		bld.log_error("Usage: ./build_it release <version>  (e.g. v3.2.0)")
		os.exit(1)
	}

	version := os.args[2]

	// Validate format: must start with 'v' followed by digits/dots
	if len(version) < 2 || version[0] != 'v' {
		bld.log_error("Version must start with 'v' (e.g. v3.2.0), got: %s", version)
		os.exit(1)
	}

	bld.log_info("Releasing %s...", version)

	// 1. Run tests first — abort if any fail
	bld.log_info("Running tests...")
	do_test()

	// 2. Verify clean working tree
	bld.log_info("Checking working tree is clean...")
	status_cmd := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&status_cmd, "git", "diff", "--exit-code")
	if !bld.cmd_run(&status_cmd) {
		bld.log_error("Working tree has unstaged changes — commit or stash before releasing")
		os.exit(1)
	}
	staged_cmd := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&staged_cmd, "git", "diff", "--cached", "--exit-code")
	if !bld.cmd_run(&staged_cmd) {
		bld.log_error("Working tree has staged changes — commit before releasing")
		os.exit(1)
	}

	// 3. Generate CHANGELOG with git-cliff (if available)
	cliff_check := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&cliff_check, "which", "git-cliff")
	if bld.cmd_run(&cliff_check) {
		bld.log_info("Generating CHANGELOG with git-cliff...")
		cliff_cmd := bld.cmd_create(context.temp_allocator)
		bld.cmd_append(&cliff_cmd, "git-cliff", "--tag", version, "-o", "CHANGELOG.md")
		if !bld.cmd_run(&cliff_cmd) {
			bld.log_error("git-cliff failed")
			os.exit(1)
		}
		add_cmd := bld.cmd_create(context.temp_allocator)
		bld.cmd_append(&add_cmd, "git", "add", "CHANGELOG.md")
		bld.cmd_run(&add_cmd)
		commit_msg := fmt.tprintf("chore: update CHANGELOG for %s", version)
		commit_cmd := bld.cmd_create(context.temp_allocator)
		bld.cmd_append(&commit_cmd, "git", "commit", "-m", commit_msg)
		bld.cmd_run(&commit_cmd)
		push_main := bld.cmd_create(context.temp_allocator)
		bld.cmd_append(&push_main, "git", "push", "origin", "main")
		bld.cmd_run(&push_main)
	} else {
		bld.log_info("git-cliff not found — skipping CHANGELOG (install: cargo install git-cliff)")
	}

	// 4. Create git tag
	bld.log_info("Creating tag %s...", version)
	tag_cmd := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&tag_cmd, "git", "tag", version)
	if !bld.cmd_run(&tag_cmd) {
		bld.log_error("Failed to create tag %s (already exists?)", version)
		os.exit(1)
	}

	// 5. Push tag — this triggers the GitHub Actions release workflow
	bld.log_info("Pushing tag %s to origin...", version)
	push_cmd := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&push_cmd, "git", "push", "origin", version)
	if !bld.cmd_run(&push_cmd) {
		bld.log_error("Failed to push tag — rolling back local tag")
		rollback := bld.cmd_create(context.temp_allocator)
		bld.cmd_append(&rollback, "git", "tag", "-d", version)
		bld.cmd_run(&rollback)
		os.exit(1)
	}

	bld.log_info("Release %s triggered — GitHub Actions will build, publish, and update Homebrew tap", version)
	bld.log_info("Track progress at: https://github.com/dvrd/wayu/actions")
}

do_help :: proc() {
	fmt.println("wayu build system")
	fmt.println("")
	fmt.println("Usage: ./build_it <target>")
	fmt.println("")
	fmt.println("Targets:")
	fmt.println("  build     Optimized release build (default)")
	fmt.println("  debug     Debug build with symbols")
	fmt.println("  test      Run unit tests")
	fmt.println("  check     Type-check only")
	fmt.println("  clean     Remove build artifacts")
	fmt.println("  install   Build + install to /usr/local/bin + wayu init")
	fmt.println("  dev       Debug build + run (extra args passed through)")
	fmt.println("  release   Run tests, tag, and push to trigger GitHub release + Homebrew update")
	fmt.println("  help      Show this help")
	fmt.println("")
	fmt.println("Bootstrap:")
	fmt.println("  odin build build -out:build_it && ./build_it")
}
