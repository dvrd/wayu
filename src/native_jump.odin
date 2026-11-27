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
		s.jump_echo = os.get_env("_ZO_ECHO", context.temp_allocator) == "1"
		if !no_cmd && is_safe_alias_name(cmd) {
			s.jump_cmd = strings.clone(cmd)
		}
		s.jump_hook = strings.clone(hook)
		return
	}
}

Native_Dir_Visit :: struct {
	count:      f64,
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

NATIVE_JUMP_MAX_RANK :: 10_000

native_jump_age :: proc(visits: ^map[string]Native_Dir_Visit) {
	total: f64
	for _, visit in visits^ {total += visit.count}

	if total <= NATIVE_JUMP_MAX_RANK {
		return
	}

	factor := 0.9 * NATIVE_JUMP_MAX_RANK / total
	expired := make([dynamic]string, context.temp_allocator)
	for dir, &visit in visits^ {
		visit.count *= factor
		if visit.count < 1 {
			append(&expired, dir)
		}
	}

	for dir in expired {delete_key(visits, dir)}
}

native_jump_score :: proc(visit: Native_Dir_Visit, now: i64) -> f64 {
	switch {
	case visit.last_visit > now - i64(time.Hour):
		return visit.count * 4
	case visit.last_visit > now - i64(time.Hour * 24):
		return visit.count * 2
	case visit.last_visit > now - i64(time.Hour * 24 * 7):
		return visit.count * 0.5
	case:
		return visit.count * 0.25
	}
}

native_jump_path_matches :: proc(dir: string, terms: []string) -> bool {
	if len(terms) == 0 {
		return false
	}

	path := strings.to_lower(dir, context.temp_allocator)
	last := terms[len(terms) - 1]
	at := strings.last_index(path, last)
	if at < 0 || strings.contains(path[at + len(last):], "/") {
		return false
	}

	path = path[:at]
	for term in terms[:len(terms) - 1] {
		pos := strings.index(path, term)
		if pos < 0 {
			return false
		}

		path = path[pos + len(term):]
	}

	return true
}

native_jump_record :: proc(dir: string) -> bool {
	if !config_lock_acquire() {
		return false
	}
	defer config_lock_release()

	path := fmt.tprintf("%s/directories.json", wayu.data)
	visits, ok := native_directory_visits(path)
	if !ok {
		fmt.eprintfln("wayu: unable to read %s", path)
		return false
	}
	visit := visits[dir]
	visit.count += 1
	visit.last_visit = time.to_unix_nanoseconds(time.now())
	visits[dir] = visit
	native_jump_age(&visits)
	if !native_directory_save(path, visits) {
		fmt.eprintfln("wayu: unable to save %s", path)
		return false
	}
	return true
}

native_directory_save :: proc(path: string, visits: map[string]Native_Dir_Visit) -> bool {
	data, err := json.marshal(visits, allocator = context.temp_allocator)
	return err == nil && write_file_atomic(path, data) == nil
}

native_jump_match :: proc(cwd: string, keywords: []string) -> string {
	visits, ok := native_directory_visits(fmt.tprintf("%s/directories.json", wayu.data))
	if !ok {
		return ""
	}
	terms := make([dynamic]string, context.temp_allocator)
	for word in keywords {append(&terms, strings.to_lower(word, context.temp_allocator))}
	best := ""
	now := time.to_unix_nanoseconds(time.now())
	best_score: f64
	latest: i64
	for dir, visit in visits {
		score := native_jump_score(visit, now)
		if score < best_score || dir == cwd || !native_jump_path_matches(dir, terms[:]) {
			continue
		}

		if score == best_score &&
		   (visit.last_visit < latest || (visit.last_visit == latest && dir >= best)) {
			continue
		}

		if os.is_dir(dir) {
			best, best_score, latest = dir, score, visit.last_visit
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
			fmt.eprintfln("%s: no matching directory", args[0])
			return 1
		}
	}
	status := native_cd(s, dest)
	if status == 0 && s.jump_echo {
		fmt.println(os.get_env("PWD", context.temp_allocator))
	}
	return status
}
