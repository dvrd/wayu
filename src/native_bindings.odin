package wayu

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

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

native_capture :: proc(s: ^Native_Session, source: string) -> (string, bool) {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		return "", false
	}

	pid := posix.fork()
	if pid == 0 {
		posix.close(fds[0])
		if posix.dup2(fds[1], 1) < 0 {
			posix._exit(1)
		}

		posix.close(fds[1])
		s.terminal = false
		native_eval(s, source)
		posix._exit(c.int(s.status))
	}

	posix.close(fds[1])
	if pid < 0 {
		posix.close(fds[0])
		return "", false
	}

	b := strings.builder_make(context.temp_allocator)
	buf: [8192]u8
	ok := true
	for {
		n := posix.read(fds[0], &buf[0], len(buf))
		if n < 0 && posix.errno() == .EINTR {
			continue
		}

		if n <= 0 {
			ok = n == 0
			break
		}

		strings.write_bytes(&b, buf[:n])
	}

	posix.close(fds[0])
	status: c.int
	for posix.waitpid(pid, &status, {}) < 0 {
		if posix.errno() != .EINTR {
			return "", false
		}
	}

	s.sub_status =
		int(posix.WEXITSTATUS(status)) if \
			posix.WIFEXITED(status) else \
			128 + int(posix.WTERMSIG(status))
	return strings.trim_right(strings.to_string(b), "\n"), ok
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
