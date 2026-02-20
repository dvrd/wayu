package bld

// Process management for async command execution.

import "core:mem"
import "core:os"
import "core:sys/posix"

// A tracked process with optional redirect files that need closing.
Tracked_Process :: struct {
    process:     os.Process,
    stdin_file:  ^os.File,
    stdout_file: ^os.File,
    stderr_file: ^os.File,
}

// A list of running processes for async execution.
Procs :: struct {
    items:     [dynamic]Tracked_Process,
    allocator: mem.Allocator,
}

// Create a new process list.
procs_create :: proc(allocator := context.allocator) -> Procs {
    return Procs{
        items     = make([dynamic]Tracked_Process, allocator),
        allocator = allocator,
    }
}

// Free all memory held by a process list.
procs_destroy :: proc(procs: ^Procs) {
    delete(procs.items)
}

// Wait for all processes to finish. Returns false if any process failed.
// Closes redirect files after each process completes.
procs_wait :: proc(procs: Procs) -> bool {
    all_ok := true
    for tp in procs.items {
        state, err := os.process_wait(tp.process)
        // Close redirect files now that the process is done.
        if tp.stdin_file  != nil do os.close(tp.stdin_file)
        if tp.stdout_file != nil do os.close(tp.stdout_file)
        if tp.stderr_file != nil do os.close(tp.stderr_file)
        if err != nil {
            log_error("Could not wait for process (pid %d): %v", tp.process.pid, err)
            all_ok = false
        } else if !state.success {
            log_error("Process (pid %d) exited with code %d", tp.process.pid, state.exit_code)
            all_ok = false
        }
    }
    return all_ok
}

// Wait for all processes and reset the list. Returns false if any failed.
procs_flush :: proc(procs: ^Procs) -> bool {
    ok := procs_wait(procs^)
    clear(&procs.items)
    return ok
}

// _SC_NPROCESSORS_ONLN is a non-standard extension not in the posix.SC enum.
// We define the platform-specific constant here.
when ODIN_OS == .Darwin {
    @(private = "file")
    _SC_NPROCESSORS_ONLN :: posix.SC(503)
} else when ODIN_OS == .Linux {
    @(private = "file")
    _SC_NPROCESSORS_ONLN :: posix.SC(84)
} else when ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
    @(private = "file")
    _SC_NPROCESSORS_ONLN :: posix.SC(35)
}

// Get the number of logical processors on the machine.
nprocs :: proc() -> int {
    when ODIN_OS == .Darwin || ODIN_OS == .Linux || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
        result := posix.sysconf(_SC_NPROCESSORS_ONLN)
        if result > 0 do return int(result)
        return 4
    } else {
        return 4
    }
}
