package wayu

import "base:intrinsics"
import "core:c"
import "core:strings"
import "core:sys/posix"
import "core:time"

// ── Interrupt guard ─────────────────────────────────────────────────────
// Most children run in their own session / process group (no terminal, so
// git and shells cannot prompt), so a Ctrl-C, SIGTERM or SIGHUP aimed at
// wayu never reaches them: killed mid-clone, wayu used to leave git running
// and a partial clone behind. While a child runs, these signals are caught:
// the handler SIGKILLs the child's group (async-signal-safe: kill/killpg
// and an atomic store only), then either chains to the handler that was
// installed before (the TUI's / watcher's terminal and PID file cleanup,
// which re-raise) or records the signal; when the runner has reaped the
// child it calls subprocess_interrupt_cleanup and exits with 128 + signal.
// A signal the process ignored (nohup) stays ignored and spares the child.

CHILD_GUARD_SIGNALS :: [3]posix.Signal{.SIGINT, .SIGTERM, .SIGHUP}

// Run (outside signal context) before an interrupted run exits: e.g. the
// removal of a partial plugin clone. nil when there is nothing to undo.
subprocess_interrupt_cleanup: proc()

@(private = "file")
_guard_busy: i32 // 1 while one runner owns the guard (others run unguarded)
@(private = "file")
_guard_pid: posix.pid_t // child to kill, 0 before fork / after reap
@(private = "file")
_guard_group: bool // the child leads its own process group
@(private = "file")
_guard_signal: i32 // the signal caught, 0 = none
@(private = "file")
_guard_prev: [len(CHILD_GUARD_SIGNALS)]posix.sigaction_t

@(private = "file")
child_guard_handler :: proc "c" (sig: posix.Signal) {
	idx := -1
	for g, i in CHILD_GUARD_SIGNALS {
		if g == sig do idx = i
	}
	if idx < 0 do return
	prev := _guard_prev[idx]
	prev_ptr := rawptr(prev.sa_handler)
	if prev_ptr == posix.SIG_IGN {
		return
	}
	if pid := intrinsics.atomic_load(&_guard_pid); pid > 0 {
		if _guard_group {
			posix.killpg(pid, .SIGKILL)
		}
		posix.kill(pid, .SIGKILL)
	}
	if prev_ptr != posix.SIG_DFL {
		if .SIGINFO in prev.sa_flags {
			prev.sa_sigaction(sig, nil, nil)
		} else {
			prev.sa_handler(sig)
		}
		return
	}
	intrinsics.atomic_store(&_guard_signal, i32(sig))
}

// Install the guard before fork (a signal between fork and the install
// would otherwise orphan the child). false: another runner owns it.
@(private = "file")
child_guard_begin :: proc(own_group: bool) -> bool {
	if _, ok := intrinsics.atomic_compare_exchange_strong(&_guard_busy, 0, 1); !ok {
		return false
	}
	intrinsics.atomic_store(&_guard_pid, 0)
	_guard_group = own_group
	act: posix.sigaction_t
	act.sa_handler = child_guard_handler
	act.sa_flags = {.RESTART}
	posix.sigemptyset(&act.sa_mask)
	for sig, i in CHILD_GUARD_SIGNALS {
		posix.sigaction(sig, &act, &_guard_prev[i])
	}
	return true
}

@(private = "file")
child_guard_set_pid :: proc(active: bool, pid: posix.pid_t) {
	if active && pid > 0 {
		intrinsics.atomic_store(&_guard_pid, pid)
		// A signal that arrived between fork and here found no pid.
		if intrinsics.atomic_load(&_guard_signal) != 0 {
			if _guard_group do posix.killpg(pid, .SIGKILL)
			posix.kill(pid, .SIGKILL)
		}
	}
}

// After the child is reaped: restore the previous handlers; if a signal was
// caught, undo (subprocess_interrupt_cleanup) and exit 128 + signal.
@(private = "file")
child_guard_end :: proc(active: bool) {
	if !active do return
	intrinsics.atomic_store(&_guard_pid, 0)
	for sig, i in CHILD_GUARD_SIGNALS {
		posix.sigaction(sig, &_guard_prev[i], nil)
	}
	intrinsics.atomic_store(&_guard_busy, 0)
	if sig := intrinsics.atomic_exchange(&_guard_signal, 0); sig != 0 {
		if subprocess_interrupt_cleanup != nil {
			subprocess_interrupt_cleanup()
		}
		wayu_exit(128 + int(sig))
	}
}

// run_command runs a subprocess with the given arg array (no shell).
// Returns true if the process exits with code 0, false otherwise.
// Stdout and stderr are redirected to /dev/null.
// IMPORTANT: args[0] is the program name (searched via $PATH by execvp).
run_command :: proc(args: []string) -> bool {
	if len(args) == 0 {
		return false
	}

	// Build null-terminated argv for execvp
	argv := make([dynamic]cstring, len(args) + 1)
	defer {
		for i in 0 ..< len(args) {
			delete(argv[i])
		}
		delete(argv)
	}
	for arg, i in args {
		argv[i] = strings.clone_to_cstring(arg)
	}
	argv[len(args)] = nil

	// Open /dev/null for redirecting stdout+stderr in child
	devnull := posix.open("/dev/null", {.WRONLY})

	guarded := child_guard_begin(false)
	pid := posix.fork()
	if pid < 0 {
		child_guard_end(guarded)
		// fork failed
		if devnull >= 0 {
			posix.close(devnull)
		}
		return false
	}

	if pid == 0 {
		// Child process
		// Redirect stdin (fd 0), stdout (fd 1), and stderr (fd 2) to /dev/null.
		// Stdin must be redirected so git (and other tools) don't try to read
		// credential prompts from the terminal — especially important when the
		// parent is running in raw terminal mode (TUI).
		if devnull >= 0 {
			posix.dup2(devnull, posix.FD(0))
			posix.dup2(devnull, posix.FD(1))
			posix.dup2(devnull, posix.FD(2))
			posix.close(devnull)
		}
		// Belt-and-suspenders with the stdin redirect above: git consults
		// /dev/tty directly for credential prompts, bypassing stdin, so also
		// disable terminal prompting outright. Keeps `git clone`/`pull` from
		// hanging on an unreachable or private remote.
		posix.setenv("GIT_TERMINAL_PROMPT", "0", true)
		// Execute — execvp searches $PATH
		posix.execvp(argv[0], raw_data(argv[:]))
		// execvp only returns on failure — use _exit to avoid Odin atexit handlers
		posix._exit(1)
	}
	child_guard_set_pid(guarded, pid)

	// Parent process
	if devnull >= 0 {
		posix.close(devnull)
	}

	status: c.int = 0
	for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	child_guard_end(guarded)
	return posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0
}

// capture_command runs a subprocess and captures its stdout.
// Returns the trimmed stdout as a heap-allocated string (caller must delete()).
// Returns "" on failure (process error, fork failure, or missing binary).
// Stderr is redirected to /dev/null.
capture_command :: proc(args: []string) -> string {
	if len(args) == 0 {
		return ""
	}

	// Build null-terminated argv
	argv := make([dynamic]cstring, len(args) + 1)
	defer {
		for i in 0 ..< len(args) {
			delete(argv[i])
		}
		delete(argv)
	}
	for arg, i in args {
		argv[i] = strings.clone_to_cstring(arg)
	}
	argv[len(args)] = nil

	// Create pipe: pipefd[0] = read end, pipefd[1] = write end
	pipefd: [2]posix.FD
	if posix.pipe(&pipefd) != .OK {
		return ""
	}

	// Open /dev/null for stderr
	devnull := posix.open("/dev/null", {.WRONLY})

	guarded := child_guard_begin(true)
	pid := posix.fork()
	if pid < 0 {
		child_guard_end(guarded)
		posix.close(pipefd[0])
		posix.close(pipefd[1])
		if devnull >= 0 {
			posix.close(devnull)
		}
		return ""
	}

	if pid == 0 {
		// Child: redirect stdout to write end of pipe
		posix.close(pipefd[0]) // Close unused read end
		posix.dup2(pipefd[1], posix.FD(1)) // stdout → pipe write end
		posix.close(pipefd[1]) // Close original write end (dup2'd)
		if devnull >= 0 {
			posix.dup2(devnull, posix.FD(2)) // stderr → /dev/null
			posix.close(devnull)
		}
		// Detach stdin from the controlling terminal so a captured command can
		// never block on an interactive prompt. Without this, `git ls-remote`
		// against an unreachable/private plugin remote hangs forever asking for
		// credentials. Paired with GIT_TERMINAL_PROMPT=0, git fails fast instead.
		stdin_null := posix.open("/dev/null", {}) // {} = O_RDONLY (read-only is the default mode)
		if stdin_null >= 0 {
			posix.dup2(stdin_null, posix.FD(0))
			posix.close(stdin_null)
		}
		posix.setenv("GIT_TERMINAL_PROMPT", "0", true)
		// New session = no controlling terminal: /dev/tty can't be opened, so
		// a command that bypasses stdin (e.g. `zsh -i` running an rc file or
		// zsh-newuser-install that reads keys from /dev/tty) can't block on —
		// or steal input from — the TUI's terminal.
		posix.setsid()
		posix.execvp(argv[0], raw_data(argv[:]))
		posix._exit(1)
	}
	child_guard_set_pid(guarded, pid)

	// Parent: read from read end of pipe
	posix.close(pipefd[1]) // Close write end — child owns it
	if devnull >= 0 {
		posix.close(devnull)
	}

	// Read all output into a builder
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	buf: [4096]byte
	for {
		n := posix.read(pipefd[0], raw_data(buf[:]), len(buf))
		if n <= 0 {
			break
		}
		strings.write_bytes(&sb, buf[:n])
	}
	posix.close(pipefd[0])

	// Wait for child
	status: c.int = 0
	for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	child_guard_end(guarded)

	if !posix.WIFEXITED(status) || posix.WEXITSTATUS(status) != 0 {
		return ""
	}

	output := strings.to_string(sb)
	trimmed := strings.trim_space(output)
	return strings.clone(trimmed)
}

// Clipboard helpers are best-effort: bound their lifetime and share the
// runner's nonblocking input, partial-write and SIGPIPE handling.
run_command_with_stdin :: proc(args: []string, input: string) -> bool {
	r := run_command_timeout(args, 5_000, stdin_data = input)
	defer command_result_destroy(&r)
	return r.ok
}

// run_background_shell fires a shell command in the background and returns
// immediately. The child is double-forked so the parent doesn't need to
// waitpid (init inherits the orphan). Stdout/stderr go to /dev/null.
run_background_shell :: proc(cmd: string) {
	pid := posix.fork()
	if pid < 0 {
		return
	}
	if pid > 0 {
		// Parent: reap the intermediate child immediately
		status: c.int = 0
		posix.waitpid(pid, &status, {})
		return
	}
	// Intermediate child: fork again so the grandchild is orphaned
	gpid := posix.fork()
	if gpid < 0 {
		posix._exit(1)
	}
	if gpid > 0 {
		posix._exit(0)
	} // intermediate exits, grandchild reparents to init

	// Grandchild: own session, so closing the terminal (SIGHUP to its
	// session) doesn't kill a background zcompile halfway; then redirect I/O
	// and exec.
	posix.setsid()
	devnull := posix.open("/dev/null", {.WRONLY})
	if devnull >= 0 {
		posix.dup2(devnull, posix.FD(0))
		posix.dup2(devnull, posix.FD(1))
		posix.dup2(devnull, posix.FD(2))
		posix.close(devnull)
	}

	cmd_cstr := strings.clone_to_cstring(cmd)
	argv := [4]cstring{"sh", "-c", cmd_cstr, nil}
	posix.execvp("sh", raw_data(argv[:]))
	posix._exit(1)
}

// run_command_capture_stderr runs a subprocess like run_command but returns
// its stderr (trimmed, ALLOCATED — caller must delete) so a failure can be
// explained to the user. Stdout goes to /dev/null; stdin is /dev/null and the
// child gets a new session, so git can never prompt on (or read from) the
// controlling terminal. At most 64 KiB of stderr is kept.
run_command_capture_stderr :: proc(args: []string) -> (ok: bool, stderr_text: string) {
	if len(args) == 0 {
		return false, strings.clone("")
	}

	argv := make([dynamic]cstring, len(args) + 1)
	defer {
		for i in 0 ..< len(args) {
			delete(argv[i])
		}
		delete(argv)
	}
	for arg, i in args {
		argv[i] = strings.clone_to_cstring(arg)
	}
	argv[len(args)] = nil

	pipefd: [2]posix.FD
	if posix.pipe(&pipefd) != .OK {
		return false, strings.clone("")
	}

	guarded := child_guard_begin(true)
	pid := posix.fork()
	if pid < 0 {
		child_guard_end(guarded)
		posix.close(pipefd[0])
		posix.close(pipefd[1])
		return false, strings.clone("")
	}

	if pid == 0 {
		posix.close(pipefd[0])
		posix.dup2(pipefd[1], posix.FD(2)) // stderr → pipe write end
		posix.close(pipefd[1])
		devnull := posix.open("/dev/null", {.RDWR})
		if devnull >= 0 {
			posix.dup2(devnull, posix.FD(0))
			posix.dup2(devnull, posix.FD(1))
			posix.close(devnull)
		}
		posix.setenv("GIT_TERMINAL_PROMPT", "0", true)
		posix.setsid()
		posix.execvp(argv[0], raw_data(argv[:]))
		posix._exit(127)
	}
	child_guard_set_pid(guarded, pid)

	posix.close(pipefd[1])

	MAX_STDERR :: 64 * 1024
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	buf: [4096]byte
	for {
		n := posix.read(pipefd[0], raw_data(buf[:]), len(buf))
		if n <= 0 {
			break
		}
		// Keep draining past the cap so the child never blocks on a full pipe.
		if strings.builder_len(sb) < MAX_STDERR {
			strings.write_bytes(&sb, buf[:min(int(n), MAX_STDERR - strings.builder_len(sb))])
		}
	}
	posix.close(pipefd[0])

	status: c.int = 0
	for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	child_guard_end(guarded)

	ok = posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0
	stderr_text = strings.clone(strings.trim_space(strings.to_string(sb)))
	return
}

// An environment variable set in a child process only when the parent's
// environment does not already define it (the user's value always wins).
Env_Default :: struct {
	name:  string,
	value: string,
}

// Outcome of run_command_timeout. stdout/stderr are trimmed and ALLOCATED
// (possibly empty) — release with command_result_destroy.
Command_Result :: struct {
	ok:        bool, // all stdin delivered, exited 0 before the deadline
	timed_out: bool, // killed at the deadline (ok is false)
	cancelled: bool, // killed because subprocess_cancel_check said so (ok is false)
	exit_code: int, // the child's exit status when it exited normally, else -1
	stdout:    string,
	stderr:    string,
}

command_result_destroy :: proc(r: ^Command_Result) {
	delete(r.stdout)
	delete(r.stderr)
	r.stdout = ""
	r.stderr = ""
}

// While set (the TUI, during a long operation), run_command_timeout calls it
// at least every SUBPROCESS_CANCEL_POLL_MS; true kills the child like a
// timeout does and the result has cancelled = true. It may also repaint a
// progress indicator. nil in the CLI.
subprocess_cancel_check: proc() -> bool
SUBPROCESS_CANCEL_POLL_MS :: 100

// run_command_timeout runs a subprocess (no shell) with stdin on /dev/null,
// capturing stdout and stderr (each capped at 64 KiB; the rest is drained
// and dropped). Like capture_command the child gets GIT_TERMINAL_PROMPT=0
// and a new session (no controlling terminal), so neither git nor ssh can
// prompt on — or read keys from — the user's terminal.
//
// timeout_ms > 0 is an overall deadline: when it passes, the child's whole
// process group (git and the ssh/https helpers it spawned) is killed with
// SIGKILL and the result has timed_out = true. timeout_ms <= 0 waits forever.
// env_defaults are set in the child only when not already set.
//
// stdin_data, when non-empty, is the child's stdin instead of /dev/null
// (streamed without blocking output capture or the deadline, then closed).
//
// cwd, when non-empty, is the child's working directory (it exits 127 when
// it cannot change to it): compilers such as bun, deno or go read config
// files from their cwd, which must not be wherever wayu was started.
run_command_timeout :: proc(
	args: []string,
	timeout_ms: int,
	env_defaults: []Env_Default = nil,
	stdin_data := "",
	cwd := "",
) -> (
	result: Command_Result,
) {
	result.exit_code = -1
	if len(args) == 0 {
		result.stdout = strings.clone("")
		result.stderr = strings.clone("")
		return
	}

	argv := make([dynamic]cstring, len(args) + 1)
	defer {
		for i in 0 ..< len(args) {
			delete(argv[i])
		}
		delete(argv)
	}
	for arg, i in args {
		argv[i] = strings.clone_to_cstring(arg)
	}
	argv[len(args)] = nil

	// Child-side env strings are prepared before fork (no allocation in the child).
	env_c := make([]cstring, 2 * len(env_defaults))
	defer {
		for s in env_c {
			delete(s)
		}
		delete(env_c)
	}
	for e, i in env_defaults {
		env_c[2 * i] = strings.clone_to_cstring(e.name)
		env_c[2 * i + 1] = strings.clone_to_cstring(e.value)
	}

	cwd_c: cstring
	if len(cwd) > 0 {
		cwd_c = strings.clone_to_cstring(cwd, context.temp_allocator)
	}

	out_pipe, err_pipe: [2]posix.FD
	in_pipe := [2]posix.FD{-1, -1}
	if posix.pipe(&out_pipe) != .OK {
		result.stdout = strings.clone("")
		result.stderr = strings.clone("")
		return
	}
	if posix.pipe(&err_pipe) != .OK {
		posix.close(out_pipe[0])
		posix.close(out_pipe[1])
		result.stdout = strings.clone("")
		result.stderr = strings.clone("")
		return
	}
	if len(stdin_data) > 0 && posix.pipe(&in_pipe) != .OK {
		posix.close(out_pipe[0])
		posix.close(out_pipe[1])
		posix.close(err_pipe[0])
		posix.close(err_pipe[1])
		result.stdout = strings.clone("")
		result.stderr = strings.clone("")
		return
	}

	// Set only the parent's write end nonblocking; the child still reads
	// ordinary blocking stdin. Fail before fork if this cannot be arranged.
	if in_pipe[1] >= 0 && posix.fcntl(in_pipe[1], .SETFL, c.int(posix.O_NONBLOCK)) < 0 {
		for fd in ([]posix.FD {
				out_pipe[0],
				out_pipe[1],
				err_pipe[0],
				err_pipe[1],
				in_pipe[0],
				in_pipe[1],
			}) {posix.close(fd)}
		result.stdout = strings.clone("")
		result.stderr = strings.clone("")
		return
	}

	guarded := child_guard_begin(true)
	pid := posix.fork()
	if pid < 0 {
		child_guard_end(guarded)
		posix.close(out_pipe[0])
		posix.close(out_pipe[1])
		posix.close(err_pipe[0])
		posix.close(err_pipe[1])
		if in_pipe[0] >= 0 {
			posix.close(in_pipe[0])
			posix.close(in_pipe[1])
		}
		result.stdout = strings.clone("")
		result.stderr = strings.clone("")
		return
	}

	if pid == 0 {
		posix.close(out_pipe[0])
		posix.close(err_pipe[0])
		posix.dup2(out_pipe[1], posix.FD(1))
		posix.dup2(err_pipe[1], posix.FD(2))
		posix.close(out_pipe[1])
		posix.close(err_pipe[1])
		if in_pipe[0] >= 0 {
			posix.close(in_pipe[1])
			posix.dup2(in_pipe[0], posix.FD(0))
			posix.close(in_pipe[0])
		} else {
			stdin_null := posix.open("/dev/null", {})
			if stdin_null >= 0 {
				posix.dup2(stdin_null, posix.FD(0))
				posix.close(stdin_null)
			}
		}
		posix.setenv("GIT_TERMINAL_PROMPT", "0", true)
		for i := 0; i < len(env_c); i += 2 {
			posix.setenv(env_c[i], env_c[i + 1], false)
		}
		if cwd_c != nil && posix.chdir(cwd_c) != .OK {
			posix._exit(127)
		}
		// New session: no controlling terminal, and the child leads its own
		// process group so the deadline can kill git's helpers too.
		posix.setsid()
		posix.execvp(argv[0], raw_data(argv[:]))
		posix._exit(127)
	}
	child_guard_set_pid(guarded, pid)

	posix.close(out_pipe[1])
	posix.close(err_pipe[1])
	has_input := in_pipe[0] >= 0
	if has_input do posix.close(in_pipe[0])
	// Install in the parent after fork, so the child retains its own signal
	// behavior. Keep it active until every possible pipe write is finished.
	prev_sigpipe := posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN) if has_input else nil
	defer if has_input do posix.signal(.SIGPIPE, prev_sigpipe)
	input := transmute([]byte)stdin_data
	input_failed := false

	MAX_CAPTURE :: 64 * 1024
	out_sb := strings.builder_make()
	err_sb := strings.builder_make()
	defer strings.builder_destroy(&out_sb)
	defer strings.builder_destroy(&err_sb)

	fds := [3]posix.pollfd {
		{fd = out_pipe[0], events = {.IN}},
		{fd = err_pipe[0], events = {.IN}},
		{fd = in_pipe[1], events = {.OUT}},
	}
	open_count := 2
	start := time.tick_now()
	buf: [4096]byte
	status: c.int
	reaped := false

	for open_count > 0 || !reaped {
		// EOF on both pipes says nothing about process lifetime: a child
		// can redirect its output and keep running. Keep the same deadline
		// and cancellation checks active until it actually exits.
		if open_count == 0 {
			waited := posix.waitpid(pid, &status, {.NOHANG})
			if waited == pid {
				reaped = true
				break
			}
			if waited < 0 && posix.errno() != .EINTR do break
		}
		wait_ms: c.int = -1
		if timeout_ms > 0 {
			elapsed := int(time.duration_milliseconds(time.tick_since(start)))
			if elapsed >= timeout_ms {
				result.timed_out = true
				break
			}
			wait_ms = c.int(timeout_ms - elapsed)
		}
		if subprocess_cancel_check != nil {
			if subprocess_cancel_check() {
				result.cancelled = true
				break
			}
			if wait_ms < 0 || wait_ms > SUBPROCESS_CANCEL_POLL_MS do wait_ms = SUBPROCESS_CANCEL_POLL_MS
		}
		if open_count == 0 && (wait_ms < 0 || wait_ms > 10) do wait_ms = 10

		n := posix.poll(raw_data(fds[:]), len(fds), wait_ms)
		if n < 0 {
			if posix.errno() == .EINTR {
				continue
			}
			break
		}
		if n == 0 {
			continue // the deadline is re-checked at the top
		}

		for &p, i in fds {
			if p.fd < 0 || p.revents == {} {
				continue
			}
			if i == 2 {
				n := posix.write(p.fd, raw_data(input), c.size_t(len(input)))
				if n < 0 && (posix.errno() == .EINTR || posix.errno() == .EAGAIN) do continue
				if n > 0 {
					input = input[n:]
				} else {
					input_failed = true
				}
				if input_failed || len(input) == 0 {
					posix.close(p.fd); p.fd = -1
				}
				continue
			}

			got := posix.read(p.fd, raw_data(buf[:]), len(buf))
			if got <= 0 {
				posix.close(p.fd)
				p.fd = -1 // poll ignores negative fds
				open_count -= 1
				continue
			}
			sb := &out_sb if i == 0 else &err_sb
			if strings.builder_len(sb^) < MAX_CAPTURE {
				strings.write_bytes(
					sb,
					buf[:min(int(got), MAX_CAPTURE - strings.builder_len(sb^))],
				)
			}
		}
	}

	if result.timed_out || result.cancelled {
		// The child is a session (and process group) leader: take down the
		// whole group, then the child itself in case setsid failed.
		posix.killpg(pid, .SIGKILL)
		posix.kill(pid, .SIGKILL)
	}
	for p in fds {
		if p.fd >= 0 {
			posix.close(p.fd)
		}
	}

	if !reaped {
		waited: posix.pid_t
		for {
			waited = posix.waitpid(pid, &status, {})
			if waited >= 0 || posix.errno() != .EINTR do break
		}
		reaped = waited == pid
	}
	child_guard_end(guarded)

	result.exit_code = int(posix.WEXITSTATUS(status)) if reaped && posix.WIFEXITED(status) else -1
	result.ok =
		!input_failed &&
		len(input) == 0 &&
		reaped &&
		!result.timed_out &&
		!result.cancelled &&
		posix.WIFEXITED(status) &&
		posix.WEXITSTATUS(status) == 0
	result.stdout = strings.clone(strings.trim_space(strings.to_string(out_sb)))
	result.stderr = strings.clone(strings.trim_space(strings.to_string(err_sb)))
	return
}

// run_command_passthrough_timeout runs a subprocess (no shell) that shares
// wayu's stdout and stderr (its output is shown), with stdin on /dev/null.
// The child leads its own process group; when timeout_ms > 0 passes, the
// whole group is killed with SIGKILL and timed_out is true. timeout_ms <= 0
// waits forever. ok: exited 0 before the deadline.
run_command_passthrough_timeout :: proc(
	args: []string,
	timeout_ms: int,
) -> (
	ok: bool,
	timed_out: bool,
) {
	if len(args) == 0 {
		return false, false
	}
	argv := make([dynamic]cstring, len(args) + 1)
	defer {
		for i in 0 ..< len(args) {
			delete(argv[i])
		}
		delete(argv)
	}
	for arg, i in args {
		argv[i] = strings.clone_to_cstring(arg)
	}
	argv[len(args)] = nil

	guarded := child_guard_begin(true)
	pid := posix.fork()
	if pid < 0 {
		child_guard_end(guarded)
		return false, false
	}
	if pid == 0 {
		stdin_null := posix.open("/dev/null", {})
		if stdin_null >= 0 {
			posix.dup2(stdin_null, posix.FD(0))
			posix.close(stdin_null)
		}
		posix.setpgid(0, 0)
		posix.execvp(argv[0], raw_data(argv[:]))
		posix._exit(127)
	}
	child_guard_set_pid(guarded, pid)
	// Also set from the parent so the group exists before a deadline kill.
	posix.setpgid(pid, pid)

	start := time.tick_now()
	status: c.int = 0
	for {
		r := posix.waitpid(pid, &status, {.NOHANG})
		if r == pid {
			break
		}
		if r < 0 && posix.errno() != .EINTR {
			child_guard_end(guarded)
			return false, false
		}
		if timeout_ms > 0 &&
		   int(time.duration_milliseconds(time.tick_since(start))) >= timeout_ms {
			posix.killpg(pid, .SIGKILL)
			posix.kill(pid, .SIGKILL)
			for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
			child_guard_end(guarded)
			return false, true
		}
		time.sleep(10 * time.Millisecond)
	}
	child_guard_end(guarded)
	return posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0, false
}
