package bld

// Command builder and execution.
// The main workhorse of bld — build commands and run them.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// A command to be executed. Dynamic array of string arguments.
Cmd :: struct {
    items:     [dynamic]string,
    allocator: mem.Allocator,
}

// Create a new empty command.
cmd_create :: proc(allocator := context.allocator) -> Cmd {
    return Cmd{
        items     = make([dynamic]string, allocator),
        allocator = allocator,
    }
}

// Append one or more arguments to a command.
cmd_append :: proc(cmd: ^Cmd, args: ..string) {
    for arg in args {
        append(&cmd.items, strings.clone(arg, cmd.allocator))
    }
}

// Append all arguments from another command.
cmd_extend :: proc(cmd: ^Cmd, other: Cmd) {
    for arg in other.items {
        append(&cmd.items, strings.clone(arg, cmd.allocator))
    }
}

// Reset the command to empty (frees cloned strings, keeps capacity).
cmd_reset :: proc(cmd: ^Cmd) {
    for arg in cmd.items {
        delete(arg, cmd.allocator)
    }
    clear(&cmd.items)
}

// Free all memory held by a command.
cmd_destroy :: proc(cmd: ^Cmd) {
    for arg in cmd.items {
        delete(arg, cmd.allocator)
    }
    delete(cmd.items)
}

// Render a command as a human-readable string for logging.
cmd_render :: proc(cmd: Cmd, allocator := context.temp_allocator) -> string {
    sb := strings.builder_make(allocator)
    for arg, i in cmd.items {
        if i > 0 do strings.write_byte(&sb, ' ')
        needs_quote := strings.contains(arg, " ") || strings.contains(arg, "'")
        if needs_quote {
            strings.write_byte(&sb, '\'')
            // Escape any single quotes inside: replace ' with '\''
            for ch in transmute([]u8)arg {
                if ch == '\'' {
                    strings.write_string(&sb, "'\\''")
                } else {
                    strings.write_byte(&sb, ch)
                }
            }
            strings.write_byte(&sb, '\'')
        } else {
            strings.write_string(&sb, arg)
        }
    }
    return strings.to_string(sb)
}

// Options for running a command.
Cmd_Run_Opt :: struct {
    // Run asynchronously, appending the process to this list.
    async:      ^Procs,
    // Maximum concurrent processes (0 = nprocs + 1).
    max_procs:  int,
    // Do not reset the command after execution.
    dont_reset: bool,
    // Redirect stdin from this file path.
    stdin_path:  string,
    // Redirect stdout to this file path.
    stdout_path: string,
    // Redirect stderr to this file path.
    stderr_path: string,
}

// Run a command with default options (synchronous, resets after).
cmd_run :: proc(cmd: ^Cmd, opt: Cmd_Run_Opt = {}) -> bool {
    if len(cmd.items) == 0 {
        log_error("Cannot run empty command")
        return false
    }

    if echo_actions {
        log_info("CMD: %s", cmd_render(cmd^))
    }

    // Build the os command slice.
    command := make([]string, len(cmd.items), context.temp_allocator)
    for arg, i in cmd.items {
        command[i] = arg
    }

    // Set up file descriptors for redirection.
    stdin_file:  ^os.File = nil
    stdout_file: ^os.File = nil
    stderr_file: ^os.File = nil

    if len(opt.stdin_path) > 0 {
        f, err := os.open(opt.stdin_path, {.Read})
        if err != nil {
            log_error("Could not open stdin file '%s': %v", opt.stdin_path, err)
            return false
        }
        stdin_file = f
    }

    if len(opt.stdout_path) > 0 {
        f, err := os.open(opt.stdout_path, {.Write, .Create, .Trunc})
        if err != nil {
            log_error("Could not open stdout file '%s': %v", opt.stdout_path, err)
            return false
        }
        stdout_file = f
    }

    if len(opt.stderr_path) > 0 {
        f, err := os.open(opt.stderr_path, {.Write, .Create, .Trunc})
        if err != nil {
            log_error("Could not open stderr file '%s': %v", opt.stderr_path, err)
            return false
        }
        stderr_file = f
    }

    desc := os.Process_Desc{
        command = command,
        stdin   = stdin_file,
        stdout  = stdout_file,
        stderr  = stderr_file,
    }

    if opt.async != nil {
        // Async mode: start and append to procs list.
        // NOTE: redirect files are tracked alongside the process so they
        // can be closed after the process finishes (in procs_wait).
        max_p := opt.max_procs > 0 ? opt.max_procs : nprocs() + 1

        // Flush if we're at capacity.
        if len(opt.async.items) >= max_p {
            if !procs_flush(opt.async) {
                if !opt.dont_reset do cmd_reset(cmd)
                return false
            }
        }

        process, err := os.process_start(desc)
        if err != nil {
            log_error("Could not start process '%s': %v", cmd.items[0], err)
            _close_redirect_files(stdin_file, stdout_file, stderr_file)
            if !opt.dont_reset do cmd_reset(cmd)
            return false
        }
        append(&opt.async.items, Tracked_Process{
            process     = process,
            stdin_file  = stdin_file,
            stdout_file = stdout_file,
            stderr_file = stderr_file,
        })
        if !opt.dont_reset do cmd_reset(cmd)
        return true
    }

    // Synchronous mode: start and wait.
    process, start_err := os.process_start(desc)
    if start_err != nil {
        log_error("Could not start process '%s': %v", cmd.items[0], start_err)
        _close_redirect_files(stdin_file, stdout_file, stderr_file)
        if !opt.dont_reset do cmd_reset(cmd)
        return false
    }

    state, wait_err := os.process_wait(process)
    _close_redirect_files(stdin_file, stdout_file, stderr_file)

    if wait_err != nil {
        log_error("Could not wait for process '%s': %v", cmd.items[0], wait_err)
        if !opt.dont_reset do cmd_reset(cmd)
        return false
    }

    if !state.success {
        log_error(
            "Command '%s' exited with code %d",
            cmd.items[0],
            state.exit_code,
        )
        if !opt.dont_reset do cmd_reset(cmd)
        return false
    }

    if !opt.dont_reset do cmd_reset(cmd)
    return true
}

// Run a command and capture its stdout as a byte slice.
cmd_run_capture :: proc(
    cmd: ^Cmd,
    allocator := context.allocator,
) -> (output: []u8, ok: bool) {
    if len(cmd.items) == 0 {
        log_error("Cannot run empty command")
        return nil, false
    }

    if echo_actions {
        log_info("CMD: %s", cmd_render(cmd^))
    }

    command := make([]string, len(cmd.items), context.temp_allocator)
    for arg, i in cmd.items {
        command[i] = arg
    }

    desc := os.Process_Desc{
        command = command,
    }

    state, stdout, stderr, err := os.process_exec(desc, allocator)
    defer delete(stderr, allocator)

    if err != nil {
        log_error("Could not execute '%s': %v", cmd.items[0], err)
        delete(stdout, allocator)
        cmd_reset(cmd)
        return nil, false
    }

    if !state.success {
        log_error("Command '%s' exited with code %d", cmd.items[0], state.exit_code)
        // Still return stdout so the caller can inspect it if they want.
        cmd_reset(cmd)
        return stdout, false
    }

    cmd_reset(cmd)
    return stdout, true
}

// Close redirect files after a process finishes.
@(private = "file")
_close_redirect_files :: proc(stdin_file, stdout_file, stderr_file: ^os.File) {
    if stdin_file  != nil do os.close(stdin_file)
    if stdout_file != nil do os.close(stdout_file)
    if stderr_file != nil do os.close(stderr_file)
}
