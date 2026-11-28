package wayu

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:sys/posix"

NATIVE_METRICS :: #config(WAYU_NATIVE_METRICS, false)

native_value :: proc(s: ^Native_Session, name: string) -> string {
	if s != nil {
		if value, ok := s.locals[name]; ok {
			return value
		}
	}

	return os.get_env(name, context.temp_allocator)
}

native_store :: proc(table: ^map[string]string, key, value: string) {
	copy := strings.clone(value)
	if old, ok := table^[key]; ok {
		ptr := &table^[key]
		ptr^ = copy
		delete(old)
	} else {
		table^[strings.clone(key)] = copy
	}
}

native_forget :: proc(table: ^map[string]string, key: string) {
	owned_key, value := delete_key(table, key)
	if NATIVE_METRICS {
		if len(owned_key) > 0 {
			fmt.eprintfln("wayu-local-release bytes=%d", len(value))
		}
	}

	delete(owned_key)
	delete(value)
}

native_assignment :: proc(w: ShellWord) -> bool {
	name, eq, _ := strings.partition(w.text, "=")
	if eq == "" || !is_shell_var_name(name) {
		return false
	}

	for active in w.active[:len(name) + 1] {
		if !active {
			return false
		}
	}

	return true
}

native_assign :: proc(s: ^Native_Session, key, value: string) {
	if NATIVE_METRICS {
		digest := hash.fnv64a(transmute([]u8)value)
		fmt.eprintfln("wayu-assignment bytes=%d fnv64a=%016x", len(value), digest)
	}

	if _, ok := os.lookup_env(key, context.temp_allocator); ok {
		_ = os.set_env(key, value)
	} else {
		native_store(&s.locals, key, value)
	}
}

Native_Binding :: struct {
	key, env, local:    string,
	had_env, had_local: bool,
}

native_bind :: proc(s: ^Native_Session, key, value: string) -> Native_Binding {
	env, had_env := os.lookup_env(key, context.temp_allocator)
	local, had_local := s.locals[key]
	saved := Native_Binding {
		key,
		env,
		strings.clone(local, context.temp_allocator),
		had_env,
		had_local,
	}

	native_forget(&s.locals, key)
	_ = os.set_env(key, value)
	return saved
}

native_restore :: proc(s: ^Native_Session, saved: []Native_Binding) {
	#reverse for b in saved {
		if b.had_env {
			_ = os.set_env(b.key, b.env)
		} else {
			_ = os.unset_env(b.key)
		}

		native_forget(&s.locals, b.key)
		if b.had_local {
			native_store(&s.locals, b.key, b.local)
		}
	}
}

native_capture_fits :: proc(limit, used, incoming: int) -> bool {
	return limit == 0 || (used <= limit && incoming <= limit - used)
}

// Only the forked evaluator installs this handler, after it owns a process group.
// A descendant may temporarily mask Ctrl+C across fork and keep stdout open.
// Notify the collector before terminating the group, including the evaluator.
Capture_Notice :: enum u8 {
	None,
	Overflow,
	Interrupted,
}

capture_interrupt_fd: posix.FD
capture_interrupt_group: posix.pid_t

native_capture_interrupt :: proc "c" (_: posix.Signal) {
	token := Capture_Notice.Interrupted
	_ = posix.write(capture_interrupt_fd, auto_cast &token, 1)
	_ = posix.kill(-capture_interrupt_group, .SIGKILL)
}

native_capture :: proc(s: ^Native_Session, source: string, out: ^strings.Builder) -> bool {
	root := s.capture_bytes > 0 && s.capture_group == 0
	notice: [2]posix.FD
	if root {
		if posix.pipe(&notice) != .OK {
			return false
		}

		// Shared with nested substitution evaluators, never inherited by external programs.
		if posix.fcntl(notice[1], .SETFD, c.int(posix.FD_CLOEXEC)) < 0 ||
		   posix.fcntl(notice[0], .SETFL, c.int(posix.O_NONBLOCK)) < 0 {
			posix.close(notice[0])
			posix.close(notice[1])
			return false
		}
	}

	// Descriptor lifetimes span fork and collection.
	defer if root {
		_ = posix.close(notice[0])
	}

	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		if root {
			posix.close(notice[1])
		}

		return false
	}

	foreground := root && posix.tcgetpgrp(0) == posix.getpgrp()
	pid := posix.fork()
	if pid == 0 {
		posix.close(fds[0])
		if root {
			posix.close(notice[0])
			s.capture_notice = notice[1]
			if posix.setpgid(0, 0) != .OK {
				posix._exit(EXIT_OSERR)
			}

			s.capture_group = posix.getpgrp()
			capture_interrupt_fd, capture_interrupt_group = notice[1], s.capture_group
			posix.signal(.SIGINT, native_capture_interrupt)
			if foreground {
				posix.signal(.SIGTTOU, auto_cast posix.SIG_IGN)
				if posix.tcsetpgrp(0, s.capture_group) != .OK {
					posix._exit(EXIT_OSERR)
				}
			}
		}

		if posix.dup2(fds[1], 1) < 0 {
			posix._exit(EXIT_IOERR)
		}

		posix.close(fds[1])
		s.jobs = nil
		s.completed_jobs = nil
		s.last_background_pid = 0
		s.terminal = false
		s.pipeline_child = true
		mark := len(s.deferred)
		native_eval_at(s, source, s.location)
		native_run_deferred(s, mark)
		posix._exit(c.int(s.status))
	}

	if root {
		posix.close(notice[1])
	}

	posix.close(fds[1])
	if pid < 0 {
		posix.close(fds[0])
		return false
	}

	if root {
		_ = posix.setpgid(pid, pid)
	}
	defer if foreground {
		previous := posix.signal(.SIGTTOU, auto_cast posix.SIG_IGN)
		_ = posix.tcsetpgrp(0, posix.getpgrp())
		posix.signal(.SIGTTOU, previous)
	}

	start := len(out.buf)
	peak := cap(out.buf)
	overlap := 0
	buf: [8192]u8
	ok := true
	reason := Capture_Notice.None
	// A child can keep stdout open after the evaluator has acknowledged cancellation.
	// Watch both descriptors so cancellation never waits for another output byte.
	watch := [2]posix.pollfd{{fd = fds[0], events = {.IN}}, {fd = notice[0], events = {.IN}}}
	for {
		if root {
			ready := posix.poll(raw_data(watch[:]), 2, -1)
			if ready < 0 {
				if posix.errno() != .EINTR {
					ok = false
					break
				}
				if intrinsics.volatile_load(&native_interrupted) {
					reason = .Interrupted
					_ = posix.killpg(pid, .SIGKILL)
					break
				}
				continue
			}
			if watch[1].revents != {} {
				token: Capture_Notice
				count := posix.read(notice[0], auto_cast &token, 1)
				if count == 1 {
					reason = token
					_ = posix.killpg(pid, .SIGKILL)
					break
				}
				if count == 0 {
					watch[1].fd = -1
				}
			}
			if watch[0].revents == {} {
				continue
			}
		}

		n := posix.read(fds[0], &buf[0], len(buf))
		if n < 0 && posix.errno() == .EINTR {
			if root && intrinsics.volatile_load(&native_interrupted) {
				posix.killpg(pid, .SIGINT)
			}

			continue
		}

		if n <= 0 {
			ok = n == 0
			break
		}

		if !native_capture_fits(s.capture_bytes, len(out.buf) - start, int(n)) {
			reason = .Overflow
			group := pid if root else s.capture_group
			if !root {
				token := Capture_Notice.Overflow
				_ = posix.write(s.capture_notice, auto_cast &token, 1)
			}

			_ = posix.killpg(group, .SIGKILL)
			break
		}

		if NATIVE_METRICS {
			old_ptr, old_cap := raw_data(out.buf), cap(out.buf)
			strings.write_bytes(out, buf[:n])
			peak = max(peak, cap(out.buf))
			if old_ptr != raw_data(out.buf) {
				overlap = max(overlap, old_cap + cap(out.buf))
			}
		} else {
			strings.write_bytes(out, buf[:n])
		}
	}

	posix.close(fds[0])
	status: c.int
	for posix.waitpid(pid, &status, {}) < 0 {
		if posix.errno() != .EINTR {
			return false
		}
	}

	if root && reason == .None {
		token: Capture_Notice
		if posix.read(notice[0], auto_cast &token, 1) == 1 {
			reason = token
		}
	}

	if reason == .Interrupted {
		s.expansion_failure = 130
		return false
	}

	if reason == .Overflow {
		s.expansion_failure = EXIT_DATAERR
		if native_should_explain(s) {
			fmt.eprintfln(
				"wayu: command substitution exceeded settings.capture_bytes (%d bytes)",
				s.capture_bytes,
			)
		}

		return false
	}

	s.sub_status =
		int(posix.WEXITSTATUS(status)) if \
			posix.WIFEXITED(status) else \
			128 + int(posix.WTERMSIG(status))
	if s.sub_status != 0 {
		s.expansion_failure = s.sub_status
		return false
	}

	if NATIVE_METRICS {
		fmt.eprintfln(
			"wayu-capture raw=%d capacity=%d resize_overlap=%d",
			len(out.buf) - start,
			peak,
			overlap,
		)
	}

	for len(out.buf) > start && out.buf[len(out.buf) - 1] == '\n' {_ = pop(&out.buf)}

	return ok
}

native_lookup :: proc(s: ^Native_Session, args: []string) -> int {
	names := args[1:]
	if args[0] == "command" {
		if len(names) == 0 || names[0] != "-v" {
			fmt.eprintln("usage: command -v NAME...")
			return EXIT_USAGE
		}

		names = names[1:]
	}

	if len(names) == 0 {
		return EXIT_USAGE
	}

	rc := 0
	for name in names {
		kind := ""
		if name in s.aliases {
			kind = "an alias"
		} else if name in s.definitions || name in s.functions {
			kind = "a function"
		} else if native_is_builtin(s, name) {
			kind = "a shell builtin"
		}

		if kind != "" {
			if args[0] == "command" {
				fmt.println(name)
			} else {
				fmt.printfln("%s is %s", name, kind)
			}

			if args[0] != "where" {
				continue
			}
		}

		if args[0] == "where" && !strings.contains(name, "/") {
			found := false
			for dir in strings.split(
				os.get_env("PATH", context.temp_allocator),
				":",
				context.temp_allocator,
			) {
				full := fmt.tprintf("%s/%s", dir if dir != "" else ".", name)
				if script_find_on_path(full) != "" {
					fmt.println(full)
					found = true
				}
			}

			if !found && kind == "" {
				rc = 1
			}
		} else if path := script_find_on_path(name); path != "" {
			if args[0] == "type" {
				fmt.printfln("%s is %s", name, path)
			} else {
				fmt.println(path)
			}
		} else if kind == "" {
			rc = 1
		}
	}

	return rc
}
