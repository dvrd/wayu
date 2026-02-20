package bld

// Command chains (pipes).
// Equivalent to shell: cmd1 | cmd2 | cmd3

import "core:os"

// A command chain representing a pipeline of commands.
Chain :: struct {
    // Previous read-end of the pipe (feeds into the next command's stdin).
    pipe_read:   ^os.File,
    // The last command added (not yet started).
    pending:     Cmd,
    // Whether the pending command should merge stderr into stdout.
    err2out:     bool,
    // Whether we have a pending command.
    has_pending: bool,
    // Intermediate processes that need to be waited on at chain_end.
    processes:   [dynamic]os.Process,
}

Chain_Begin_Opt :: struct {
    stdin_path: string,
}

Chain_Cmd_Opt :: struct {
    err2out:    bool,
    dont_reset: bool,
}

Chain_End_Opt :: struct {
    async:       ^Procs,
    max_procs:   int,
    stdout_path: string,
    stderr_path: string,
}

// Begin a command chain.
chain_begin :: proc(chain: ^Chain, opt: Chain_Begin_Opt = {}) -> bool {
    chain.pipe_read = nil
    chain.has_pending = false
    chain.err2out = false
    chain.processes = make([dynamic]os.Process, context.temp_allocator)

    if len(opt.stdin_path) > 0 {
        f, err := os.open(opt.stdin_path, {.Read})
        if err != nil {
            log_error("Could not open stdin file '%s': %v", opt.stdin_path, err)
            return false
        }
        chain.pipe_read = f
    }

    return true
}

// Add a command to the chain.
chain_cmd :: proc(chain: ^Chain, cmd: ^Cmd, opt: Chain_Cmd_Opt = {}) -> bool {
    if chain.has_pending {
        // Start the previous command with pipe output.
        r, w, pipe_err := os.pipe()
        if pipe_err != nil {
            log_error("Could not create pipe: %v", pipe_err)
            return false
        }

        command := make([]string, len(chain.pending.items), context.temp_allocator)
        for arg, i in chain.pending.items {
            command[i] = arg
        }

        desc := os.Process_Desc{
            command = command,
            stdin   = chain.pipe_read,
            stdout  = w,
            stderr  = chain.err2out ? w : nil,
        }

        if echo_actions do log_info("PIPE: %s", cmd_render(chain.pending))

        process, err := os.process_start(desc)

        // Close write end and old read end.
        os.close(w)
        if chain.pipe_read != nil do os.close(chain.pipe_read)

        if err != nil {
            log_error("Could not start process: %v", err)
            os.close(r)
            return false
        }

        // Track intermediate process so we can wait on it in chain_end.
        append(&chain.processes, process)

        // The new read end becomes the input for the next command.
        chain.pipe_read = r
        cmd_reset(&chain.pending)
    }

    // Store this command as pending.
    chain.pending = cmd_create(context.temp_allocator)
    for arg in cmd.items {
        cmd_append(&chain.pending, arg)
    }
    chain.err2out = opt.err2out
    chain.has_pending = true

    if !opt.dont_reset do cmd_reset(cmd)
    return true
}

// End the chain, executing the final command.
chain_end :: proc(chain: ^Chain, opt: Chain_End_Opt = {}) -> bool {
    if !chain.has_pending {
        // Empty chain — nothing to do.
        if chain.pipe_read != nil do os.close(chain.pipe_read)
        return true
    }

    command := make([]string, len(chain.pending.items), context.temp_allocator)
    for arg, i in chain.pending.items {
        command[i] = arg
    }

    stdout_file: ^os.File = nil
    stderr_file: ^os.File = nil

    if len(opt.stdout_path) > 0 {
        f, err := os.open(opt.stdout_path, {.Write, .Create, .Trunc})
        if err != nil {
            log_error("Could not open stdout file '%s': %v", opt.stdout_path, err)
            return false
        }
        stdout_file = f
    }
    defer if stdout_file != nil do os.close(stdout_file)

    if len(opt.stderr_path) > 0 {
        f, err := os.open(opt.stderr_path, {.Write, .Create, .Trunc})
        if err != nil {
            log_error("Could not open stderr file '%s': %v", opt.stderr_path, err)
            return false
        }
        stderr_file = f
    }
    defer if stderr_file != nil do os.close(stderr_file)

    desc := os.Process_Desc{
        command = command,
        stdin   = chain.pipe_read,
        stdout  = stdout_file,
        stderr  = chain.err2out ? stdout_file : stderr_file,
    }

    if echo_actions do log_info("PIPE: %s", cmd_render(chain.pending))

    process, start_err := os.process_start(desc)
    if chain.pipe_read != nil do os.close(chain.pipe_read)
    chain.pipe_read = nil
    chain.has_pending = false

    if start_err != nil {
        log_error("Could not start process: %v", start_err)
        return false
    }

    if opt.async != nil {
        append(&opt.async.items, Tracked_Process{process = process})
        // Still need to wait on intermediate processes.
        for p in chain.processes {
            _, _ = os.process_wait(p)
        }
        clear(&chain.processes)
        return true
    }

    state, wait_err := os.process_wait(process)

    // Wait on all intermediate pipeline processes.
    all_ok := true
    for p in chain.processes {
        p_state, p_err := os.process_wait(p)
        if p_err != nil {
            log_error("Could not wait for pipeline process: %v", p_err)
            all_ok = false
        } else if !p_state.success {
            log_error("Pipeline process exited with code %d", p_state.exit_code)
            all_ok = false
        }
    }
    clear(&chain.processes)

    if wait_err != nil {
        log_error("Could not wait for process: %v", wait_err)
        return false
    }

    if !state.success {
        log_error("Pipeline command exited with code %d", state.exit_code)
        return false
    }

    return all_ok
}
