package wayu

import "core:c"
import "core:strings"
import "core:sys/posix"

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
		for i in 0..<len(args) {
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
		// Redirect stdout (fd 1) and stderr (fd 2) to /dev/null
		if devnull >= 0 {
			posix.dup2(devnull, posix.FD(1))
			posix.dup2(devnull, posix.FD(2))
			posix.close(devnull)
		}
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
		for i in 0..<len(args) {
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
		posix.close(pipefd[0])                    // Close unused read end
		posix.dup2(pipefd[1], posix.FD(1))        // stdout → pipe write end
		posix.close(pipefd[1])                    // Close original write end (dup2'd)
		if devnull >= 0 {
			posix.dup2(devnull, posix.FD(2))       // stderr → /dev/null
			posix.close(devnull)
		}
		posix.execvp(argv[0], raw_data(argv[:]))
		posix._exit(1)
	}

	// Parent: read from read end of pipe
	posix.close(pipefd[1])  // Close write end — child owns it
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
		for i in 0..<len(args) {
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
		posix.close(pipefd[1])                    // Close unused write end
		posix.dup2(pipefd[0], posix.FD(0))        // stdin ← pipe read end
		posix.close(pipefd[0])                    // Close original read end (dup2'd)
		if devnull >= 0 {
			posix.dup2(devnull, posix.FD(1))       // stdout → /dev/null
			posix.dup2(devnull, posix.FD(2))       // stderr → /dev/null
			posix.close(devnull)
		}
		posix.execvp(argv[0], raw_data(argv[:]))
		posix._exit(1)
	}

	// Parent: write input to write end, then close it (signals EOF to child)
	posix.close(pipefd[0])  // Close read end — child owns it
	if devnull >= 0 {
		posix.close(devnull)
	}

	if len(input) > 0 {
		input_bytes := transmute([]byte)input
		posix.write(pipefd[1], raw_data(input_bytes), c.size_t(len(input_bytes)))
	}
	posix.close(pipefd[1])  // EOF signal to child

	// Wait for child
	status: c.int = 0
	posix.waitpid(pid, &status, {})
	return posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0
}
