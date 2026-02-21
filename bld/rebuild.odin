package bld

// Go Rebuild Urself technology for Odin.
// Automatically detects if the build script source was modified
// and rebuilds + re-executes itself.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// Check if an output file needs rebuilding based on input file modification times.
// Returns:  1 = needs rebuild, 0 = up to date, -1 = error.
needs_rebuild :: proc(output_path: string, input_paths: []string) -> int {
    output_info, out_err := os.stat(output_path, context.temp_allocator)
    if out_err != nil {
        // Output doesn't exist, needs rebuild.
        return 1
    }
    defer os.file_info_delete(output_info, context.temp_allocator)

    output_mtime := output_info.modification_time

    for input_path in input_paths {
        input_info, in_err := os.stat(input_path, context.temp_allocator)
        if in_err != nil {
            log_error("Could not stat input file '%s': %v", input_path, in_err)
            return -1
        }
        defer os.file_info_delete(input_info, context.temp_allocator)

        if time.diff(output_mtime, input_info.modification_time) > 0 {
            return 1
        }
    }

    return 0
}

// Convenience: check if output needs rebuild against a single input.
needs_rebuild1 :: proc(output_path, input_path: string) -> int {
    return needs_rebuild(output_path, {input_path})
}

// Go Rebuild Urself technology.
//
// Call this at the top of your build script's main(). It will:
// 1. Check if the source file is newer than the running binary.
// 2. If so, rebuild the binary using `odin build`.
// 3. Re-execute the new binary with the same arguments.
// 4. Exit with the new binary's exit code.
//
// Usage:
//   main :: proc() {
//       bld.go_rebuild_urself(".")  // "." = current package
//       // ... rest of build logic ...
//   }
//
// The source_path should be the package directory (e.g., ".") or a specific
// file if using -file mode.
go_rebuild_urself :: proc(source_path: string, extra_sources: ..string) {
    // Get the path to the currently running executable.
    binary_path := _get_self_exe_path() or_else ""
    if len(binary_path) == 0 {
        log_error("Could not determine executable path, skipping rebuild check")
        return
    }

    // Collect all source paths to check, expanding directories into
    // individual .odin files. Directory mtime only changes when entries
    // are added/removed, NOT when file contents change — so we must
    // stat the individual files.
    all_sources := make([dynamic]string, context.temp_allocator)
    _expand_source_path(&all_sources, source_path)
    for extra in extra_sources {
        _expand_source_path(&all_sources, extra)
    }

    // Check if rebuild is needed.
    rebuild := needs_rebuild(binary_path, all_sources[:])
    if rebuild < 0 {
        runtime.exit(1)
    }
    if rebuild == 0 {
        return // Up to date, continue with the current binary.
    }

    log_info("Build script changed, rebuilding...")

    // Rename current binary to .old.
    old_path := strings.concatenate({binary_path, ".old"}, context.temp_allocator)
    if !rename_file(binary_path, old_path) {
        runtime.exit(1)
    }

    // Rebuild using odin build.
    rebuild_cmd := cmd_create(context.temp_allocator)
    cmd_append(&rebuild_cmd, "odin", "build", source_path, "-o:speed")
    cmd_append(&rebuild_cmd, fmt.tprintf("-out:%s", binary_path))

    if !cmd_run(&rebuild_cmd, {dont_reset = true}) {
        // Rebuild failed, restore old binary.
        rename_file(old_path, binary_path)
        runtime.exit(1)
    }

    // Try to delete the old binary (best effort).
    delete_file(old_path)

    // Re-execute with original arguments and propagate exit code.
    exec_cmd := cmd_create(context.temp_allocator)
    cmd_append(&exec_cmd, binary_path)
    for arg in os.args[1:] {
        cmd_append(&exec_cmd, arg)
    }

    // Run the new binary. We need to capture success/failure and propagate
    // the exit code. cmd_run returns false on non-zero exit, but we need
    // the actual exit code. Use process_start/wait directly.
    exec_command := make([]string, len(exec_cmd.items), context.temp_allocator)
    for arg, i in exec_cmd.items {
        exec_command[i] = arg
    }

    process, start_err := os.process_start(os.Process_Desc{command = exec_command})
    if start_err != nil {
        log_error("Could not re-execute '%s': %v", binary_path, start_err)
        runtime.exit(1)
    }

    state, wait_err := os.process_wait(process)
    if wait_err != nil {
        log_error("Could not wait for re-executed process: %v", wait_err)
        runtime.exit(1)
    }

    runtime.exit(int(state.exit_code))
}

// Helper: expand a source path for rebuild checking.
// If the path is a directory, walk it and collect all .odin files.
// If it's a regular file, add it directly.
@(private = "file")
_expand_source_path :: proc(out: ^[dynamic]string, path: string) {
    ft, ok := get_file_type(path)
    if !ok {
        // Can't stat — add as-is and let needs_rebuild report the error.
        append(out, path)
        return
    }

    if ft != .Directory {
        append(out, path)
        return
    }

    // Read directory entries and collect all .odin files.
    // We avoid walk_dir here because its TEMP_GUARD frees child paths
    // before we can use them. A flat directory read is sufficient since
    // build script packages are not nested.
    f, open_err := os.open(path)
    if open_err != nil {
        log_error("Could not open directory '%s': %v", path, open_err)
        return
    }
    defer os.close(f)

    infos, read_err := os.read_all_directory(f, context.temp_allocator)
    if read_err != nil {
        log_error("Could not read directory '%s': %v", path, read_err)
        return
    }

    for info in infos {
        if info.name == "." || info.name == ".." do continue
        if file_ext(info.name) != ".odin" do continue
        append(out, fmt.tprintf("%s/%s", path, info.name))
    }
}

// Helper: get the path to the currently running executable.
@(private = "file")
_get_self_exe_path :: proc() -> (string, bool) {
    self_info, self_err := os.current_process_info({.Executable_Path}, context.temp_allocator)
    defer os.free_process_info(self_info, context.temp_allocator)
    if self_err != nil {
        return "", false
    }
    return strings.clone(self_info.executable_path, context.temp_allocator), true
}
