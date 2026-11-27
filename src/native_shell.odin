package wayu

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

native_interrupted: bool

native_interrupt :: proc "c" (_: posix.Signal) {
	intrinsics.volatile_store(&native_interrupted, true)
}

native_stop_list :: proc(s: ^Native_Session) -> bool {
	if s.terminal && intrinsics.volatile_load(&native_interrupted) {
		s.status = 130
		return true
	}

	return s.exiting || s.returning || s.loop_action != .None
}

Native_Session :: struct {
	locals, definitions: map[string]string,
	shell_name:          string,
	loop_depth:          int,
	loop_action:         enum {
		None,
		Break,
		Continue,
	},
	positional:          []string,
	returning:           bool,
	function_depth:      int,
	sub_status:          int,
	jump_echo:           bool,
	jump_cmd:            string,
	jump_hook:           string,
	functions:           map[string]Native_Function,
	vi_register:         string,
	source_depth:        int,
	aliases:             map[string][dynamic]ShellStatement,
	vi_mode:             bool,
	prompt:              PromptConfigFull,
	prompt_options:      InteractiveConfig,
	prompt_cache:        Native_Prompt_Cache,
	highlight:           ^Native_Highlight_Styles,
	suggest:             Native_Suggest_Config,
	minimal_prompt:      bool,
	status:              int,
	exiting:             bool,
	terminal:            bool,
	modes:               posix.termios,
	jobs:                [dynamic]Native_Job,
	next_job:            int,
}
Native_Redirect :: struct {
	target: posix.FD,
	op:     string,
	path:   ShellWord,
}
Native_Command :: struct {
	words:     [dynamic]ShellWord,
	redirects: [dynamic]Native_Redirect,
}
Native_Pipeline :: struct {
	commands:   [dynamic]Native_Command,
	condition:  string,
	background: bool,
}

native_reserved_word :: proc(word: ShellWord) -> bool {
	switch word.text {
	case "if",
	     "then",
	     "elif",
	     "else",
	     "fi",
	     "while",
	     "until",
	     "for",
	     "do",
	     "done",
	     "case",
	     "esac",
	     "{",
	     "}":
		for active in word.active {
			if !active {
				return false
			}
		}
		return true
	}
	return false
}

native_parse :: proc(stmts: []ShellStatement) -> ([]Native_Pipeline, string) {
	result := make([dynamic]Native_Pipeline, context.temp_allocator)
	for stmt in stmts {
		if stmt.error != "" {
			return nil, stmt.error
		}
		pipe := Native_Pipeline {
			commands = make([dynamic]Native_Command, context.temp_allocator),
		}
		cmd: Native_Command
		need_word := false
		for i := 0; i < len(stmt.tokens); i += 1 {
			t := stmt.tokens[i]
			if t.kind == .Word {
				if len(cmd.words) == 0 && native_reserved_word(t.word) {
					return nil, fmt.tprintf("unsupported shell construct %s", t.word.text)
				}
				if cmd.words.allocator.procedure == nil {
					cmd.words = make([dynamic]ShellWord, context.temp_allocator)
				}
				append(&cmd.words, t.word)
				need_word = false
				continue
			}
			target, op, redirect := native_redirection(t.op)
			if redirect {
				if i + 1 >= len(stmt.tokens) || stmt.tokens[i + 1].kind != .Word {
					return nil, "expected a redirection target"
				}
				i += 1
				if cmd.redirects.allocator.procedure == nil {
					cmd.redirects = make([dynamic]Native_Redirect, context.temp_allocator)
				}
				append(&cmd.redirects, Native_Redirect{target, op, stmt.tokens[i].word})
				continue
			}
			switch t.op {
			case "|", ";", "&", "&&", "||":
				if len(cmd.words) == 0 {
					return nil, "expected a command before operator"
				}
				append(&pipe.commands, cmd)
				cmd = {}
				need_word = t.op != ";" && t.op != "&"
				if t.op != "|" {
					if t.op == "&" && (pipe.condition == "&&" || pipe.condition == "||") {
						return nil, "background conditional lists are unsupported"
					}
					pipe.background = t.op == "&"
					append(&result, pipe)
					pipe = {
						commands  = make([dynamic]Native_Command, context.temp_allocator),
						condition = t.op,
					}
				}
			case:
				return nil, fmt.tprintf("unsupported operator %s", t.op)
			}
		}
		if len(cmd.words) > 0 {
			append(&pipe.commands, cmd)
			append(&result, pipe)
		} else if need_word || len(cmd.redirects) > 0 {
			return nil, "expected a command"
		}
	}
	return result[:], ""
}

Native_Field_Splits :: struct {
	offsets:          [dynamic]int,
	unquoted_capture: bool,
}

native_expand :: proc(
	w: ShellWord,
	last: int,
	pattern := false,
	s: ^Native_Session = nil,
	splits: ^Native_Field_Splits = nil,
) -> (
	string,
	bool,
) {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(w.text); i += 1 {
		ch := w.text[i]
		if ch == '`' && w.active[i] {
			return "", false
		}
		if ch == '~' && i == 0 && w.active[i] && (len(w.text) == 1 || w.text[1] == '/') {
			native_expand_literal(&b, os.get_env("HOME", context.temp_allocator), pattern)
		} else if ch == '$' && w.active[i] && i + 1 < len(w.text) {
			start := i + 1
			if w.text[start] == '?' && w.active[start] {
				strings.write_string(&b, fmt.tprintf("%d", last))
				i += 1
				continue
			}
			if strings.index_byte("#@0123456789", w.text[start]) >= 0 {
				if s == nil {
					return "", false
				}
				symbol := w.text[start]
				if symbol == '#' {
					strings.write_string(&b, fmt.tprintf("%d", len(s.positional)))
				} else if symbol == '@' {
					native_expand_literal(
						&b,
						strings.join(s.positional, " ", context.temp_allocator),
						pattern,
					)
				} else if symbol == '0' {
					strings.write_string(&b, s.shell_name)
				} else if n := int(symbol - '1'); n < len(s.positional) {
					native_expand_literal(&b, s.positional[n], pattern)
				}
				i += 1
				continue
			}
			if w.text[start] == '(' {
				if s == nil {
					return "", false
				}
				end := shell_expansion_end(w.text, start)
				if end < 0 {
					return "", false
				}
				value, ok := native_capture(s, w.text[start + 1:end - 1])
				if !ok {
					return "", false
				}
				if splits != nil && w.active[start] {
					splits.unquoted_capture = true
					from := 0
					for byte_value, j in transmute([]u8)value {
						if byte_value == ' ' || byte_value == '\t' || byte_value == '\n' {
							native_expand_literal(&b, value[from:j], pattern)
							append(&splits.offsets, len(strings.to_string(b)))
							from = j + 1
						}
					}
					native_expand_literal(&b, value[from:], pattern)
				} else {
					native_expand_literal(&b, value, pattern)
				}
				i = end - 1
				continue
			}
			braced := w.text[start] == '{'
			if braced {
				start += 1
			}
			end := start
			for end < len(w.text) && w.active[end] && is_env_var_char(w.text[end]) {end += 1}
			if braced && !is_shell_var_name(w.text[start:end]) {
				return "", false
			}
			if braced && strings.has_prefix(w.text[end:], ":-") {
				close := shell_expansion_end(w.text, start - 1)
				if close < 0 {
					return "", false
				}
				value := native_value(s, w.text[start:end])
				if value == "" {
					fallback, ok := native_default_word(w.text[end + 2:close - 1], last, s)
					if !ok {
						return "", false
					}
					value = fallback
				}
				native_expand_literal(&b, value, pattern)
				i = close - 1
				continue
			}
			if braced && (end >= len(w.text) || w.text[end] != '}') {
				return "", false
			}
			if end == start {
				strings.write_byte(&b, ch)
				continue
			}
			native_expand_literal(&b, native_value(s, w.text[start:end]), pattern)
			i = end - 1
			if braced {
				i += 1
			}
		} else {
			if pattern && ((!w.active[i] && strings.index_byte("*?[]", ch) >= 0) || ch == '\\') {
				strings.write_byte(&b, '\\')
			}
			strings.write_byte(&b, ch)
		}
	}
	return strings.to_string(b), true
}

native_expand_literal :: proc(b: ^strings.Builder, v: string, pattern: bool) {
	if !pattern {
		strings.write_string(b, v)
		return
	}
	for ch in transmute([]u8)v {
		if strings.index_byte("*?[]\\", ch) >= 0 {
			strings.write_byte(b, '\\')
		}
		strings.write_byte(b, ch)
	}
}

native_arguments :: proc(w: ShellWord, s: ^Native_Session, args: ^[dynamic]string) -> bool {
	if w.text == "$@" && w.active[0] {
		append(args, ..s.positional)
		return true
	}
	glob := false
	for i := 0; i < len(w.text); i += 1 {
		if w.active[i] &&
		   w.text[i] == '$' &&
		   i + 1 < len(w.text) &&
		   (w.text[i + 1] == '{' || w.text[i + 1] == '(') {
			end := shell_expansion_end(w.text, i + 1)
			if end < 0 {
				return false
			}
			i = end - 1
		} else if w.active[i] &&
		   strings.index_byte("*?[", w.text[i]) >= 0 &&
		   !(i > 0 && w.text[i - 1] == '$' && w.active[i - 1]) {
			glob = true
		}
	}
	splits := Native_Field_Splits {
		offsets = make([dynamic]int, context.temp_allocator),
	}
	value, ok := native_expand(w, s.status, glob, s, &splits)
	if !ok || strings.contains(value, "\x00") {
		return false
	}
	if !splits.unquoted_capture {
		return native_glob_field(value, glob, args)
	}
	begin := 0
	for cut in splits.offsets {
		if cut > begin && !native_glob_field(value[begin:cut], glob, args) {
			return false
		}
		begin = cut
	}
	if len(value) > begin || (value == "" && w.quoted) {
		return native_glob_field(value[begin:], glob, args)
	}
	return true
}

native_glob_field :: proc(field: string, glob: bool, args: ^[dynamic]string) -> bool {
	value := field
	if glob {
		pattern := value
		matches: posix.glob_t
		result := posix.glob(
			strings.clone_to_cstring(pattern, context.temp_allocator),
			{},
			nil,
			&matches,
		)
		defer posix.globfree(&matches)
		if result == .SUCCESS {
			for m in matches.gl_pathv[:matches.gl_pathc] {append(args, strings.clone(string(m), context.temp_allocator))}
			return true
		}
		if result != .NOMATCH {
			return false
		}
		b := strings.builder_make(context.temp_allocator)
		for i := 0; i < len(value); i += 1 {
			if value[i] == '\\' && i + 1 < len(value) {
				i += 1
			}
			strings.write_byte(&b, value[i])
		}
		value = strings.to_string(b)
	}
	append(args, value)
	return true
}

NATIVE_BUILTINS :: [?]string {
	"cd",
	"export",
	"unset",
	"exit",
	"jobs",
	"fg",
	"bg",
	"source",
	"type",
	"where",
	"command",
	"return",
	"break",
	"continue",
}

native_is_builtin :: proc(s: ^Native_Session, name: string) -> bool {
	if name in s.definitions || name != "" && name == s.jump_cmd {
		return true
	}

	for builtin in NATIVE_BUILTINS {
		if name == builtin {
			return true
		}
	}
	return false
}

native_warp_query :: proc(args: []string) -> bool {
	if len(args) < 3 ||
	   args[0] != "wayu" ||
	   args[1] != "warp" ||
	   args[2] == "edit" ||
	   args[2] == "search" ||
	   args[2] == "help" {
		return false
	}
	for word in args[2:] {
		if strings.has_prefix(word, "-") {
			return false
		}
	}
	return true
}

native_builtin :: proc(s: ^Native_Session, args: []string) -> int {
	if native_warp_query(args) {
		return warp_jump(args[2:], s)
	}
	if s.jump_cmd != "" && args[0] == s.jump_cmd {
		return native_jump(s, args)
	}

	if body, ok := s.definitions[args[0]]; ok {
		if s.function_depth >= 64 {
			fmt.eprintln("wayu: function nesting too deep")
			return 1
		}
		previous := s.positional
		s.positional = args[1:]
		s.function_depth += 1
		native_eval(s, strings.clone(body, context.temp_allocator))
		s.function_depth -= 1
		s.positional = previous
		s.returning = false
		return s.status
	}
	switch args[0] {
	case "where", "type", "command":
		return native_lookup(s, args)
	case "break", "continue":
		if s.loop_depth == 0 || len(args) != 1 {
			fmt.eprintfln("%s: requires an enclosing loop", args[0])
			return EXIT_USAGE
		}
		s.loop_action = .Break if args[0] == "break" else .Continue
		return 0
	case "return":
		if s.function_depth == 0 || len(args) > 2 {
			return EXIT_USAGE
		}
		code := s.status
		if len(args) == 2 {
			v, ok := strconv.parse_int(args[1])
			if !ok {
				return EXIT_USAGE
			}
			code = v & 255
		}
		s.returning = true
		return code
	case "source":
		if len(args) != 2 {
			fmt.eprintln("usage: source FILE")
			return EXIT_USAGE
		}
		return native_source(s, args[1])
	case "jobs", "fg", "bg":
		return native_jobs_command(s, args)
	case "exit":
		code := s.status
		if len(args) > 2 {
			return EXIT_USAGE
		}
		if len(args) == 2 {
			v, ok := strconv.parse_int(args[1])
			if !ok {
				fmt.eprintln("exit: expected an integer")
				return EXIT_USAGE
			}
			code = v & 255
		}
		s.exiting = true
		return code
	case "cd":
		if len(args) > 2 {
			fmt.eprintln("cd: expected at most one directory")
			return EXIT_USAGE
		}
		dest := os.get_env("HOME", context.temp_allocator) if len(args) == 1 else args[1]
		return native_cd(s, dest)
	case "export", "unset":
		for arg in args[1:] {
			name, eq, value := strings.partition(arg, "=")
			if !is_shell_var_name(name) || (args[0] == "unset" && eq != "") {
				fmt.eprintfln("%s: invalid variable name", args[0])
				return EXIT_USAGE
			}
			if args[0] == "unset" {
				native_forget(&s.locals, name)
				if !os.unset_env(name) {
					return 1
				}
			} else {
				if eq == "" {
					value = native_value(s, name)
				}
				if os.set_env(name, value) != nil {
					return 1
				}
				native_forget(&s.locals, name)
			}
		}
	case:
		return -1
	}
	return 0
}

native_cd :: proc(s: ^Native_Session, directory: string) -> int {
	dest := directory
	old, _ := os.get_working_directory(context.temp_allocator)
	if dest == "-" {
		dest = os.get_env("OLDPWD", context.temp_allocator)
	}
	if dest == "" || posix.chdir(strings.clone_to_cstring(dest, context.temp_allocator)) != .OK {
		fmt.eprintfln("cd: cannot enter %s", dest)
		return 1
	}
	new_dir, err := os.get_working_directory(context.temp_allocator)
	if err != nil {
		return 1
	}
	_ = os.set_env("OLDPWD", old)
	_ = os.set_env("PWD", new_dir)
	if s.jump_hook == "pwd" && new_dir != old {
		native_jump_record(new_dir)
	}

	return 0
}

native_redirection :: proc(operator: string) -> (posix.FD, string, bool) {
	i := 0
	for i < len(operator) && operator[i] >= '0' && operator[i] <= '9' {i += 1}
	op := operator[i:]
	if op != ">" && op != "<" && op != ">>" && op != ">&" && op != "<&" {
		return 0, "", false
	}
	fd := 0 if op[0] == '<' else 1
	if i != 0 {
		if i != 1 || operator[0] > '2' {
			return 0, "", false
		}
		fd = int(operator[0] - '0')
	}
	return posix.FD(fd), op, true
}

native_redirect :: proc(cmd: Native_Command, s: ^Native_Session) -> bool {
	for r in cmd.redirects {
		path, ok := native_expand(r.path, s.status, false, s)
		if !ok || strings.contains(path, "\x00") {
			return false
		}
		file := strings.clone_to_cstring(path, context.temp_allocator)
		fd: posix.FD
		target := r.target
		if r.op == "<&" || r.op == ">&" {
			if len(path) != 1 || path[0] < '0' || path[0] > '2' {
				fmt.eprintln("wayu: expected descriptor 0, 1, or 2")
				return false
			}
			if posix.dup2(posix.FD(path[0] - '0'), target) < 0 {
				return false
			}
			continue
		}
		if r.op == "<" {
			fd = posix.open(file, {})
		} else {
			flags := posix.O_Flags{.WRONLY, .CREAT}
			if r.op == ">" {
				flags += {.TRUNC}
			} else {
				flags += {.APPEND}
			}
			fd = posix.open(file, flags, transmute(posix.mode_t)posix._mode_t(0o666))
		}
		if fd < 0 {
			fmt.eprintfln("wayu: %s: %v", path, posix.errno())
			return false
		}
		if fd != target {
			ok = posix.dup2(fd, target) >= 0
			posix.close(fd)
			if !ok {
				return false
			}
		}
	}
	return true
}

native_pipeline :: proc(s: ^Native_Session, p: Native_Pipeline) -> int {
	grouped := s.terminal || p.background
	job: Native_Job
	gate: [2]posix.FD
	if grouped && posix.pipe(&gate) != .OK {
		return 1
	}
	pids := make([dynamic]posix.pid_t, context.temp_allocator)
	previous := posix.FD(-1)
	failed := false
	for cmd, idx in p.commands {
		args := make([dynamic]string, context.temp_allocator)
		argv := make([dynamic]cstring, context.temp_allocator)
		prefix := 0
		for prefix < len(cmd.words) && native_assignment(cmd.words[prefix]) {prefix += 1}
		s.sub_status = 0
		for w in cmd.words[prefix:] {
			if !native_arguments(w, s, &args) {
				fmt.eprintln("wayu: invalid word expansion")
				failed = true
				break
			}
		}

		if failed {
			break
		}
		only := len(args) == 0
		name := ""
		if !only {
			name = args[0]
		}
		saved := make([dynamic]Native_Binding, context.temp_allocator)
		defer native_restore(s, saved[:])
		for w in cmd.words[:prefix] {
			value, ok := native_expand(w, s.status, false, s)
			if !ok || strings.contains(value, "\x00") {
				failed = true
				break
			}
			key, _, v := strings.partition(value, "=")
			if only && len(p.commands) == 1 && !p.background {
				native_assign(s, key, v)
			} else {
				append(&saved, native_bind(s, key, v))
			}
		}
		if failed {
			break
		}

		builtin := only || native_is_builtin(s, name) || native_warp_query(args[:])
		if builtin && len(p.commands) == 1 && !p.background {
			if grouped {
				posix.close(gate[0])
				posix.close(gate[1])
			}
			if len(cmd.redirects) == 0 {
				return s.sub_status if only else native_builtin(s, args[:])
			}
			in_fd := posix.dup(posix.STDIN_FILENO)
			out_fd := posix.dup(posix.STDOUT_FILENO)
			defer if in_fd >= 0 {
				posix.dup2(in_fd, posix.STDIN_FILENO)
				posix.close(in_fd)
			}
			defer if out_fd >= 0 {
				posix.dup2(out_fd, posix.STDOUT_FILENO)
				posix.close(out_fd)
			}
			err_fd := posix.dup(posix.STDERR_FILENO)
			defer if err_fd >= 0 {
				posix.dup2(err_fd, posix.STDERR_FILENO)
				posix.close(err_fd)
			}
			if in_fd < 0 || out_fd < 0 || err_fd < 0 || !native_redirect(cmd, s) {
				return 1
			}
			return s.sub_status if only else native_builtin(s, args[:])
		}
		launch := args[:]
		if fn, found := s.functions[name]; found && !builtin {
			launch = native_function_args(fn, args[:])
		}

		for arg in launch {append(&argv, strings.clone_to_cstring(arg, context.temp_allocator))}
		append(&argv, nil)
		fds: [2]posix.FD
		more := idx + 1 < len(p.commands)
		if more && posix.pipe(&fds) != .OK {
			failed = true
			break
		}
		pid := posix.fork()
		if pid == 0 {
			posix.signal(.SIGINT, auto_cast posix.SIG_DFL)
			posix.signal(.SIGQUIT, auto_cast posix.SIG_DFL)
			posix.signal(.SIGPIPE, auto_cast posix.SIG_DFL)
			if grouped {
				posix.close(gate[1])
				for sig in ([3]posix.Signal {
						.SIGTSTP,
						.SIGTTIN,
						.SIGTTOU,
					}) {posix.signal(sig, auto_cast posix.SIG_DFL)}
				ch: u8
				for posix.read(gate[0], &ch, 1) < 0 && posix.errno() == .EINTR {}
				posix.close(gate[0])
			}
			if previous >= 0 {
				if posix.dup2(previous, posix.STDIN_FILENO) < 0 {
					posix._exit(1)
				}
				posix.close(previous)
			}
			if more {
				posix.close(fds[0])
				if posix.dup2(fds[1], posix.STDOUT_FILENO) < 0 {
					posix._exit(1)
				}
				posix.close(fds[1])
			}
			if !native_redirect(cmd, s) {
				posix._exit(1)
			}
			if builtin {
				if only {
					posix._exit(c.int(s.sub_status))
				}
				if name == "fg" || name == "bg" {
					fmt.eprintfln("%s: job control requires the foreground shell", name)
					posix._exit(1)
				}
				s.terminal = false
				posix._exit(c.int(native_builtin(s, args[:])))
			}

			posix.execvp(argv[0], raw_data(argv[:]))
			err := posix.errno()
			fmt.eprintfln("wayu: %s: %v", name, err)
			posix._exit(EXIT_EXEC_NOT_FOUND if err == .ENOENT else EXIT_EXEC_NOT_RUNNABLE)
		}
		if more {
			posix.close(fds[1])
		}
		if pid < 0 {
			if more {
				posix.close(fds[0])
			}
			failed = true
			break
		}
		if grouped {
			if job.group == 0 {
				job.group = pid
			}
			// Children wait on gate until the parent assigns the whole pipeline
			// to its group and hands over the terminal.
			if posix.setpgid(pid, job.group) != .OK {
				failed = true
			}
			append(&job.members, Native_Process{pid = pid})
		}
		append(&pids, pid)
		if previous >= 0 {
			posix.close(previous)
		}
		previous = fds[0] if more else -1
	}
	if previous >= 0 {
		posix.close(previous)
	}
	if failed {
		for pid in pids {posix.kill(pid, .SIGKILL)}
	}
	if grouped {
		if !failed && !p.background && s.terminal && posix.tcsetpgrp(0, job.group) != .OK {
			failed = true
			posix.killpg(job.group, .SIGKILL)
		}
		posix.close(gate[0])
		posix.close(gate[1])
		if !failed {
			job.name = strings.clone(p.commands[0].words[0].text)
			rc := 0
			if !p.background {
				rc = native_job_wait(s, &job, false)
			}
			if p.background || !native_job_done(&job) {
				s.next_job += 1
				job.id = s.next_job
				append(&s.jobs, job)
				if s.terminal {
					fmt.eprintfln("[%d] %d", job.id, job.group)
				}
			} else {
				native_job_destroy(&job)
			}
			return rc
		}
		delete(job.members)
	}
	result := 1
	for pid in pids {
		status: c.int
		waited := posix.waitpid(pid, &status, {})
		for waited < 0 && posix.errno() == .EINTR {waited = posix.waitpid(pid, &status, {})}
		if waited < 0 {
			result = 1
		} else if posix.WIFEXITED(status) {
			result = int(posix.WEXITSTATUS(status))
		} else if posix.WIFSIGNALED(status) {
			result = 128 + int(posix.WTERMSIG(status))
		}
	}
	return 1 if failed else result
}

native_continues :: proc(tokens: []ShellToken) -> bool {
	if len(tokens) == 0 {
		return false
	}

	last := tokens[len(tokens) - 1]
	return last.kind == .Op && (last.op == "|" || last.op == "&&" || last.op == "||")
}

native_incomplete :: proc(source: string) -> bool {
	parts := shell_parse_statements(source, .POSIX, true)
	defer shell_statements_destroy(&parts)

	if len(parts) == 0 {
		return false
	}

	last := parts[len(parts) - 1]
	parser := native_parser(nil, source, parts[:])
	_ = native_list(&parser)

	return(
		strings.has_prefix(last.error, "unterminated") ||
		last.error == "trailing backslash" ||
		native_continues(last.tokens[:]) ||
		parser.incomplete \
	)
}

native_eval :: proc(s: ^Native_Session, source: string) {
	stmts := shell_parse_statements(source, .POSIX, true)
	defer shell_statements_destroy(&stmts)

	parser := native_parser(s, source, stmts[:])
	nodes := native_list(&parser)
	if parser.err != "" || parser.i != len(parser.tokens) {
		fmt.eprintfln("wayu: %s", parser.err if parser.err != "" else "unexpected block delimiter")
		s.status = 2
		return
	}
	native_run_list(s, nodes)
}

run_native_shell :: proc(
	command: Maybe(string) = nil,
	login := false,
	parameters: []string = nil,
) {
	s: Native_Session
	s.shell_name = "wayu"
	if len(parameters) > 0 {
		s.shell_name = parameters[0]
		s.positional = parameters[1:]
	}
	s.locals = make(map[string]string)
	s.definitions = make(map[string]string)
	s.aliases = make(map[string][dynamic]ShellStatement)
	native_configure(&s)
	native_jump_configure(&s)
	native_functions_load(&s)
	if login {
		path := fmt.tprintf("%s/login.wayu", wayu.config)
		if os.exists(path) {
			s.status = native_source(&s, path)
			if s.exiting {
				wayu_exit(s.status)
			}
		}
	}
	if line, supplied := command.(string); supplied {
		native_eval(&s, line)
		wayu_exit(s.status)
	}
	prompt_arena: virtual.Arena
	interactive := bool(posix.isatty(posix.STDIN_FILENO))
	if interactive {
		s.terminal = posix.tcgetpgrp(0) == posix.getpgrp() && posix.tcgetattr(0, &s.modes) == .OK
		if s.terminal {
			s.suggest = native_suggest_defaults()
			if content, ok := get_cached_toml_content(); ok {
				// The editor resets the command arena after each submission.
				// Keep all parsed prompt strings alive for the interactive session.
				if virtual.arena_init_growing(&prompt_arena) == nil {
					context.temp_allocator = virtual.arena_allocator(&prompt_arena)
					context.allocator = context.temp_allocator
					native_suggest_configure(&s.suggest, content)
					s.highlight = native_highlight_styles()
					s.prompt_options = parse_interactive_config(content)
					s.vi_mode = s.prompt_options.vi_mode
					if prompt_is_enabled(content) {
						s.prompt = parse_full_prompt_config(content)
					}
				}
			}
			for sig in ([3]posix.Signal {
					.SIGTSTP,
					.SIGTTIN,
					.SIGTTOU,
				}) {posix.signal(sig, auto_cast posix.SIG_IGN)}
		}
		posix.signal(.SIGINT, native_interrupt)
		posix.signal(.SIGQUIT, auto_cast posix.SIG_IGN)
	}
	if interactive {
		startup := fmt.tprintf("%s/config.wayu", wayu.config)
		if os.exists(startup) {
			s.status = native_source(&s, startup)
		}
	}
	history: Native_History
	if s.terminal && s.suggest.enabled {
		history.shell_commands = native_read_shell_history()
	}
	for first_prompt := true; !s.exiting; first_prompt = false {
		native_jobs_reap(&s)
		if interactive && !first_prompt {
			fmt.eprintln()
		}

		if s.terminal {
			if s.jump_hook == "prompt" {
				if dir, err := os.get_working_directory(context.temp_allocator); err == nil {
					native_jump_record(dir)
				}
			}

			_ = native_history_sync(&history)
			line, ok := native_edit_line(&s, &history)
			if !ok {
				break
			}
			if len(line) > 0 {
				_ = native_history_sync(&history, line)
				intrinsics.volatile_store(&native_interrupted, false)
				native_eval(&s, line)
			}
			free_all(context.temp_allocator)
			continue
		}
		if interactive {
			fmt.eprint("wayu> ")
		}
		b := strings.builder_make(context.temp_allocator)
		eof := false
		for {
			ch: u8
			n := posix.read(posix.STDIN_FILENO, &ch, 1)
			if n < 0 && posix.errno() == .EINTR {
				continue
			}
			if n <= 0 {
				eof = true
				break
			}
			if ch == '\n' {
				if native_incomplete(strings.to_string(b)) {
					strings.write_byte(&b, ch)
					if interactive {
						fmt.eprint("> ")
					}
					continue
				}
				break
			}
			strings.write_byte(&b, ch)
		}
		native_eval(&s, strings.to_string(b))
		free_all(context.temp_allocator)
		if eof {
			break
		}
	}
	wayu_exit(s.status)
}
