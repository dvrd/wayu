package wayu

import "core:c"
import "core:strings"
import "core:sys/posix"
import "core:time"

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

	pid := posix.fork()
	if pid < 0 {
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

	// Parent process
	if devnull >= 0 {
		posix.close(devnull)
	}

	status: c.int = 0
	posix.waitpid(pid, &status, {})
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

	pid := posix.fork()
	if pid < 0 {
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
	posix.waitpid(pid, &status, {})

	if !posix.WIFEXITED(status) || posix.WEXITSTATUS(status) != 0 {
		return ""
	}

	output := strings.to_string(sb)
	trimmed := strings.trim_space(output)
	return strings.clone(trimmed)
}

// run_command_with_stdin runs a subprocess and writes input to its stdin.
// Returns true if the process exits with code 0, false otherwise.
// Stdout and stderr are redirected to /dev/null.
// Used for clipboard commands (pbcopy, xclip) that read from stdin.
run_command_with_stdin :: proc(args: []string, input: string) -> bool {
	if len(args) == 0 {
		return false
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

	// Create pipe for stdin: pipefd[0] = read end (child stdin), pipefd[1] = write end (parent writes)
	pipefd: [2]posix.FD
	if posix.pipe(&pipefd) != .OK {
		return false
	}

	// Open /dev/null for stdout+stderr
	devnull := posix.open("/dev/null", {.WRONLY})

	pid := posix.fork()
	if pid < 0 {
		posix.close(pipefd[0])
		posix.close(pipefd[1])
		if devnull >= 0 {
			posix.close(devnull)
		}
		return false
	}

	if pid == 0 {
		// Child: redirect stdin from read end of pipe
		posix.close(pipefd[1]) // Close unused write end
		posix.dup2(pipefd[0], posix.FD(0)) // stdin ← pipe read end
		posix.close(pipefd[0]) // Close original read end (dup2'd)
		if devnull >= 0 {
			posix.dup2(devnull, posix.FD(1)) // stdout → /dev/null
			posix.dup2(devnull, posix.FD(2)) // stderr → /dev/null
			posix.close(devnull)
		}
		posix.execvp(argv[0], raw_data(argv[:]))
		posix._exit(1)
	}

	// Parent: write input to write end, then close it (signals EOF to child)
	posix.close(pipefd[0]) // Close read end — child owns it
	if devnull >= 0 {
		posix.close(devnull)
	}

	if len(input) > 0 {
		input_bytes := transmute([]byte)input
		posix.write(pipefd[1], raw_data(input_bytes), c.size_t(len(input_bytes)))
	}
	posix.close(pipefd[1]) // EOF signal to child

	// Wait for child
	status: c.int = 0
	posix.waitpid(pid, &status, {})
	return posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0
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

	pid := posix.fork()
	if pid < 0 {
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
			strings.write_bytes(&sb, buf[:n])
		}
	}
	posix.close(pipefd[0])

	status: c.int = 0
	posix.waitpid(pid, &status, {})

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
	ok:        bool, // exited 0 before the deadline
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
// (written whole, then closed; meant for small inputs such as a key that must
// stay off argv: at most one pipe buffer, so the write never blocks).
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

	pid := posix.fork()
	if pid < 0 {
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

	posix.close(out_pipe[1])
	posix.close(err_pipe[1])
	if in_pipe[0] >= 0 {
		posix.close(in_pipe[0])
		// A child that exits without reading must not kill us with SIGPIPE.
		prev := posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
		data := transmute([]byte)stdin_data
		for len(data) > 0 {
			n := posix.write(in_pipe[1], raw_data(data), c.size_t(len(data)))
			if n < 0 && posix.errno() == .EINTR {
				continue
			}
			if n <= 0 {
				break
			}
			data = data[n:]
		}
		posix.close(in_pipe[1])
		posix.signal(.SIGPIPE, prev)
	}

	MAX_CAPTURE :: 64 * 1024
	out_sb := strings.builder_make()
	err_sb := strings.builder_make()
	defer strings.builder_destroy(&out_sb)
	defer strings.builder_destroy(&err_sb)

	fds := [2]posix.pollfd{{fd = out_pipe[0], events = {.IN}}, {fd = err_pipe[0], events = {.IN}}}
	open_count := 2
	start := time.tick_now()
	buf: [4096]byte

	for open_count > 0 {
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

		n := posix.poll(raw_data(fds[:]), 2, wait_ms)
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
			got := posix.read(p.fd, raw_data(buf[:]), len(buf))
			if got <= 0 {
				posix.close(p.fd)
				p.fd = -1 // poll ignores negative fds
				open_count -= 1
				continue
			}
			sb := &out_sb if i == 0 else &err_sb
			if strings.builder_len(sb^) < MAX_CAPTURE {
				strings.write_bytes(sb, buf[:got])
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

	status: c.int = 0
	for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}

	result.exit_code = int(posix.WEXITSTATUS(status)) if posix.WIFEXITED(status) else -1
	result.ok =
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

	pid := posix.fork()
	if pid < 0 {
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
			return false, false
		}
		if timeout_ms > 0 &&
		   int(time.duration_milliseconds(time.tick_since(start))) >= timeout_ms {
			posix.killpg(pid, .SIGKILL)
			posix.kill(pid, .SIGKILL)
			for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {}
			return false, true
		}
		time.sleep(10 * time.Millisecond)
	}
	return posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0, false
}
