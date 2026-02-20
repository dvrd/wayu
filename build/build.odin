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
//   help      — show available targets

package main

import "core:fmt"
import "core:os"
import bld "../bld"

SRC_DIR     :: "src"
BIN_DIR     :: "bin"
BINARY_NAME :: "wayu"
TEST_DIR    :: "tests/unit"

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
		out          = fmt.tprintf("%s/%s", BIN_DIR, BINARY_NAME),
		opt          = .Speed,
	})
	if !ok {
		bld.log_error("Build failed")
		os.exit(1)
	}
	bld.log_info("Built %s/%s", BIN_DIR, BINARY_NAME)
}

do_debug :: proc() {
	bld.log_info("Building %s (debug)...", BINARY_NAME)
	bld.mkdir_if_not_exists(BIN_DIR)
	ok := bld.build({
		package_path = SRC_DIR,
		out          = fmt.tprintf("%s/%s_debug", BIN_DIR, BINARY_NAME),
		debug        = true,
	})
	if !ok {
		bld.log_error("Debug build failed")
		os.exit(1)
	}
	bld.log_info("Built %s/%s_debug", BIN_DIR, BINARY_NAME)
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

	bld.log_info("Installing to /usr/local/bin/%s...", BINARY_NAME)
	src_path := fmt.tprintf("%s/%s", BIN_DIR, BINARY_NAME)
	ok := bld.copy_file(src_path, fmt.tprintf("/usr/local/bin/%s", BINARY_NAME))
	if !ok {
		bld.log_error("Failed to copy binary to /usr/local/bin/")
		os.exit(1)
	}

	// Make executable
	cmd := bld.cmd_create(context.temp_allocator)
	bld.cmd_append(&cmd, "chmod", "+x", fmt.tprintf("/usr/local/bin/%s", BINARY_NAME))
	bld.cmd_run(&cmd)

	// Run init
	bld.log_info("Running %s init...", BINARY_NAME)
	init_ok := bld.run(
		{package_path = SRC_DIR, out = fmt.tprintf("%s/%s", BIN_DIR, BINARY_NAME), opt = .Speed},
		"init",
	)
	if !init_ok {
		bld.log_error("Init failed")
		os.exit(1)
	}

	bld.log_info("Installed successfully")
}

do_dev :: proc() {
	do_debug()

	bld.log_info("Running %s_debug...", BINARY_NAME)
	args: [dynamic]string
	defer delete(args)
	for i := 2; i < len(os.args); i += 1 {
		append(&args, os.args[i])
	}
	ok := bld.run(
		{package_path = SRC_DIR, out = fmt.tprintf("%s/%s_debug", BIN_DIR, BINARY_NAME), debug = true},
		..args[:],
	)
	if !ok {
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
	fmt.println("  test      Run unit tests")
	fmt.println("  check     Type-check only")
	fmt.println("  clean     Remove build artifacts")
	fmt.println("  install   Build + install to /usr/local/bin + wayu init")
	fmt.println("  dev       Debug build + run (extra args passed through)")
	fmt.println("  help      Show this help")
	fmt.println("")
	fmt.println("Bootstrap:")
	fmt.println("  odin build build -out:build_it && ./build_it")
}
