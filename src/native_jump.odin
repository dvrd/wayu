package wayu

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

native_jump_configure :: proc(s: ^Native_Session) {
	s.jump_cmd = "z"
	s.jump_hook = "pwd"
	tools := read_wayu_toml_tools()
	defer {
		for &tool in tools {destroy_tool_entry(&tool)}
		delete(tools)
	}

	for tool in tools {
		if tool.name != "zoxide" || !tool_kind_is_evalcache(tool.kind) || tool.login_only {
			continue
		}

		parts := shell_parse_statements(tool.args, .POSIX)
		defer shell_statements_destroy(&parts)
		if len(parts) != 1 || parts[0].error != "" {
			return
		}
		tokens := parts[0].tokens
		if len(tokens) < 2 || tokens[0].word.text != "init" {
			return
		}

		cmd, hook := "z", "pwd"
		no_cmd := false
		for i := 1; i < len(tokens); i += 1 {
			arg, eq, value := strings.partition(tokens[i].word.text, "=")
			switch arg {
			case "--cmd", "--hook":
				if eq == "" {
					i += 1
					if i >= len(tokens) {
						return
					}
					value = tokens[i].word.text
				}
				if arg == "--cmd" {
					cmd = value
				} else {
					hook = value
				}
			case "--no-cmd":
				no_cmd = true
			}
		}
		s.jump_cmd = ""
		s.zoxide_fallback = true
		if !no_cmd && is_safe_alias_name(cmd) {
			s.jump_cmd = strings.clone(cmd)
		}
		s.jump_hook = strings.clone(hook)
		return
	}
}

Native_Dir_Visit :: struct {
	count:      i64,
	last_visit: i64,
}

native_directory_visits :: proc(path: string) -> (map[string]Native_Dir_Visit, bool) {
	visits := make(map[string]Native_Dir_Visit, context.temp_allocator)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err == os.General_Error.Not_Exist {
		return visits, true
	}
	if err != nil {
		return nil, false
	}
	if json.unmarshal(data, &visits, allocator = context.temp_allocator) != nil {
		return nil, false
	}
	return visits, true
}

native_jump_record :: proc(dir: string) {
	if !config_lock_acquire() {
		return
	}
	defer config_lock_release()

	path := fmt.tprintf("%s/directories.json", wayu.data)
	visits, ok := native_directory_visits(path)
	if !ok {
		fmt.eprintfln("wayu: unable to read %s", path)
		return
	}
	visit := visits[dir]
	visit.count += 1
	visit.last_visit = time.to_unix_nanoseconds(time.now())
	visits[dir] = visit
	data, err := json.marshal(visits, allocator = context.temp_allocator)
	if err != nil || write_file_atomic(path, data) != nil {
		fmt.eprintfln("wayu: unable to save %s", path)
	}
}

native_jump_match :: proc(cwd: string, keywords: []string) -> string {
	visits, ok := native_directory_visits(fmt.tprintf("%s/directories.json", wayu.data))
	if !ok {
		return ""
	}
	terms := make([dynamic]string, context.temp_allocator)
	for word in keywords {append(&terms, strings.to_lower(word, context.temp_allocator))}
	best := ""
	rank: Native_Dir_Visit
	for dir, visit in visits {
		if dir == cwd {
			continue
		}
		rest := strings.to_lower(dir, context.temp_allocator)
		matched := true
		for term in terms {
			at := strings.index(rest, term)
			if at < 0 {
				matched = false; break
			}
			rest = rest[at + len(term):]
		}
		if matched &&
		   (visit.count > rank.count ||
				   (visit.count == rank.count && visit.last_visit > rank.last_visit)) &&
		   os.is_dir(dir) {
			best, rank = dir, visit
		}
	}
	return best
}

native_jump :: proc(s: ^Native_Session, args: []string) -> int {
	dest := os.get_env("HOME", context.temp_allocator)
	if len(args) == 2 && (args[1] == "-" || os.is_dir(args[1])) {
		dest = args[1]
	} else if len(args) > 1 {
		cwd, err := os.get_working_directory(context.temp_allocator)
		if err != nil {
			return 1
		}
		dest = native_jump_match(cwd, args[1:])
		if dest == "" {
			if !s.zoxide_fallback || script_find_on_path("zoxide") == "" {
				fmt.eprintln("z: no matching directory")
				return 1
			}
			query := make([dynamic]string, context.temp_allocator)
			append(&query, "zoxide", "query", "--exclude", cwd, "--")
			append(&query, ..args[1:])
			state, stdout, stderr, exec_err := os.process_exec(
				{command = query[:]},
				context.temp_allocator,
			)
			if exec_err != nil {
				fmt.eprintfln("zoxide query: %v", exec_err)
				return 1
			}
			fmt.eprint(string(stderr))
			if state.exit_code != 0 {
				return state.exit_code
			}
			dest = strings.trim_suffix(string(stdout), "\n")
		}
	}
	status := native_cd(s, dest)
	if status == 0 && s.zoxide_fallback && os.get_env("_ZO_ECHO", context.temp_allocator) == "1" {
		fmt.println(os.get_env("PWD", context.temp_allocator))
	}
	return status
}
