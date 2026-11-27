package wayu

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

Native_Prompt_Values :: struct {
	pwd, dir, basename, branch, context_name, version, pending, localip: string,
}

// The command arena is cleared between prompts. Keep only the most recent
// metadata on the session heap, scoped to its directory, branch and language.
Native_Prompt_Cache :: struct {
	pwd, branch, context_name, version, pending: string,
}

native_prompt_cache_matches :: proc(c: ^Native_Prompt_Cache, v: Native_Prompt_Values) -> bool {
	return c.pwd == v.pwd && c.branch == v.branch && c.context_name == v.context_name
}

native_prompt_cache_update :: proc(c: ^Native_Prompt_Cache, v: Native_Prompt_Values) {
	if native_prompt_cache_matches(c, v) && c.pending == v.pending && c.version == v.version {
		return
	}
	next := Native_Prompt_Cache {
		pwd          = strings.clone(v.pwd),
		branch       = strings.clone(v.branch),
		context_name = strings.clone(v.context_name),
		version      = strings.clone(v.version),
		pending      = strings.clone(v.pending),
	}
	delete(c.pwd)
	delete(c.branch)
	delete(c.context_name)
	delete(c.version)
	delete(c.pending)
	c^ = next
}

native_prompt_branch :: proc(pwd: string) -> string {
	git := os.get_env("GIT_DIR", context.temp_allocator)
	for dir := pwd; git == "" && dir != ""; {
		path := fmt.tprintf("%s/.git", dir)
		if os.is_dir(path) {
			git = path; break
		}
		if os.is_file(path) {
			link, err := os.read_entire_file_from_path(path, context.temp_allocator)
			if err != nil || !strings.has_prefix(string(link), "gitdir: ") {
				return ""
			}
			git = strings.trim_space(string(link)[8:])
			if !strings.has_prefix(git, "/") {
				git = fmt.tprintf("%s/%s", dir, git)
			}
			break
		}
		if dir == "/" {
			return ""
		}
		dir = dir[:max(1, strings.last_index_byte(dir, '/'))]
	}
	if git == "" {
		return ""
	}
	head, err := os.read_entire_file_from_path(fmt.tprintf("%s/HEAD", git), context.temp_allocator)
	if err != nil {
		return ""
	}
	ref := strings.trim_space(string(head))
	if ref == "ref: refs/heads/.invalid" {
		branch := capture_command({"git", "symbolic-ref", "--short", "HEAD"})
		defer delete(branch)
		return strings.clone(branch, context.temp_allocator)
	}
	if strings.has_prefix(ref, "ref: ") {
		return strings.trim_prefix(ref[5:], "refs/heads/")
	}
	return ref[:min(len(ref), 7)]
}

native_prompt_values :: proc(s: ^Native_Session) -> (v: Native_Prompt_Values) {
	if s.prompt.format == "" {
		return
	}
	v.pwd, _ = os.get_working_directory(context.temp_allocator)
	v.dir = v.pwd
	home := os.get_env("HOME", context.temp_allocator)
	if home != "" {
		if resolved, err := os.get_absolute_path(home, context.temp_allocator); err == nil {
			home = resolved
		}
	}
	if home != "" && (v.pwd == home || strings.has_prefix(v.pwd, fmt.tprintf("%s/", home))) {
		v.dir = fmt.tprintf("~%s", v.pwd[len(home):])
	}
	v.basename = get_base_name(v.dir)
	if v.dir == "/" {
		v.basename = "/"
	}
	if s.prompt_options.async_rprompt || strings.contains(s.prompt.format, "{git_branch}") {
		v.branch = native_prompt_branch(v.pwd)
	}
	if strings.contains(s.prompt.format, "{localip}") {
		output := capture_command(
			{
				"sh",
				"-c",
				`ipconfig getifaddr en0 2>/dev/null || ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}'`,
			},
		)
		v.localip = strings.clone(output, context.temp_allocator)
		delete(output)
	}
	if s.prompt_options.context_aware &&
	   (strings.contains(s.prompt.format, "{language_context}") ||
			   strings.contains(s.prompt.format, "{context_icon}")) {
		configured := make(map[string]bool, context.temp_allocator)
		for name in s.prompt.context_order {
			match, valid := native_prompt_detect(s.prompt.context_detects[name][:])
			if match {
				v.context_name = name; return
			}
			configured[name] = valid
		}
		for rule in PROMPT_BUILTIN_CONTEXTS {
			if !configured[rule.name] {
				if match, _ := native_prompt_detect(rule.detect); match {
					v.context_name = rule.name; return
				}
			}
		}
	}
	return
}

native_prompt_detect :: proc(patterns: []string) -> (matched, valid: bool) {
	for raw in patterns {
		pattern := strings.trim_space(raw)
		safe, is_glob := prompt_detect_pattern(pattern)
		if !safe {
			continue
		}
		valid = true
		if is_glob {
			matches, _ := os.glob(pattern, context.temp_allocator)
			if len(matches) > 0 {
				return true, true
			}
		} else if os.exists(pattern) {
			return true, true
		}
	}
	return
}

// Only style codes produced by the prompt renderer reach the terminal.
// Text from config, file names, and external commands stays literal.
native_prompt_text :: proc(b: ^strings.Builder, text: string, layout := false) {
	for r in text {
		if layout && r == '\n' {
			strings.write_byte(b, '\n')
		} else if r < ' ' || (r >= 0x7f && r < 0xa0) {
			strings.write_rune(b, '�')
		} else {
			strings.write_rune(b, r)
		}
	}
}

native_prompt_style :: proc(b: ^strings.Builder, style: string) -> bool {
	if CURRENT_COLOR_PROFILE == .ASCII {
		return false
	}
	seq := style_to_ansi(style)
	if seq == "" {
		return false
	}
	strings.write_byte(b, 0x1b)
	strings.write_string(b, seq[2:])
	return true
}

native_prompt_module :: proc(b: ^strings.Builder, format: string, vars: [][2]string) {
	for seg in prompt_dsl_segments(format) {
		styled := seg.styled && native_prompt_style(b, seg.style)
		for text := seg.text; len(text) > 0; {
			idx := len(text)
			match: [2]string
			for pair in vars {
				at := strings.index(text, pair[0])
				if at >= 0 && at < idx {
					idx = at; match = pair
				}
			}
			native_prompt_text(b, text[:idx], true)
			if idx == len(text) {
				break
			}
			native_prompt_text(b, match[1])
			text = text[idx + len(match[0]):]
		}
		if styled {
			strings.write_string(b, "\x1b[0m")
		}
	}
}

native_prompt_token :: proc(
	b: ^strings.Builder,
	s: ^Native_Session,
	v: Native_Prompt_Values,
	name: string,
	normal: bool,
) {
	cfg := &s.prompt
	switch name {
	case "dir":
		native_prompt_module(
			b,
			cfg.dir_format,
			{{"$dir", v.dir}, {"$pwd", v.pwd}, {"$basename", v.basename}},
		)
	case "git_branch":
		if v.branch != "" {
			native_prompt_module(b, cfg.git_branch_format, {{"$branch", v.branch}})
		}
	case "username":
		if cfg.username_show_always ||
		   posix.geteuid() == 0 ||
		   os.get_env("SSH_CONNECTION", context.temp_allocator) != "" ||
		   os.get_env("SSH_TTY", context.temp_allocator) != "" ||
		   os.get_env("SSH_CLIENT", context.temp_allocator) != "" {
			native_prompt_module(
				b,
				cfg.username_format,
				{{"$user", os.get_env("USER", context.temp_allocator)}},
			)
		}
	case "hostname":
		buf: [256]u8
		if posix.gethostname(raw_data(buf[:]), len(buf) - 1) == .OK {
			host, _, _ := strings.partition(string(cstring(raw_data(buf[:]))), ".")
			native_prompt_module(b, cfg.hostname_format, {{"$hostname", host}})
		}
	case "localip":
		native_prompt_module(b, cfg.localip_format, {{"$localip", v.localip}})
	case "language_context", "context_icon":
		if format, ok := cfg.context_formats[v.context_name]; ok {
			native_prompt_module(b, format, {{"$version", v.version}})
		} else {
			strings.write_string(b, "wayu")
		}
	case "character":
		symbol := cfg.character_success if s.status == 0 else cfg.character_error
		style := "green bold" if s.status == 0 else "red bold"
		if s.vi_mode && s.prompt_options.vi_mode_indicator {
			symbol = cfg.vimcmd_symbol if normal else cfg.character_success
			style = "green bold" if normal else "202 bold"
		}
		styled := native_prompt_style(b, style)
		native_prompt_text(b, symbol)
		if styled {
			strings.write_string(b, "\x1b[0m")
		}
	}
}

native_prompt_render :: proc(s: ^Native_Session, v: Native_Prompt_Values, normal: bool) -> string {
	if s.prompt.format == "" {
		return "wayu> "
	}
	b := strings.builder_make(context.temp_allocator)
	if s.minimal_prompt {
		native_prompt_text(&b, v.dir)
		strings.write_string(&b, " ")
		strings.write_string(
			&b,
			"✗ " if s.prompt_options.transient_enabled && s.status != 0 else "➜ ",
		)
		return strings.to_string(b)
	}
	format, _ := strings.replace_all(s.prompt.format, `\n`, "\n", context.temp_allocator)
	for len(format) > 0 {
		open := strings.index_byte(format, '{')
		if open < 0 {
			native_prompt_text(&b, format, true); break
		}
		end := strings.index_byte(format[open:], '}')
		if end < 0 {
			native_prompt_text(&b, format, true); break
		}
		end += open
		literal_end := open
		next := end + 1
		style := ""
		if open > 0 && format[open - 1] == '[' && strings.has_prefix(format[next:], "](") {
			if close := strings.index_byte(format[next + 2:], ')'); close >= 0 {
				style = format[next + 2:next + 2 + close]
				next += 3 + close
				literal_end -= 1
			}
		}
		native_prompt_text(&b, format[:literal_end], true)
		styled := native_prompt_style(&b, style)
		native_prompt_token(&b, s, v, format[open + 1:end], normal)
		if styled {
			strings.write_string(&b, "\x1b[0m")
		}
		format = format[next:]
	}
	return strings.to_string(b)
}

// A worker owns its process group so leaving the editor also cancels any
// version or Git command it launched. The polling editor remains responsive.
Native_Prompt_Worker :: struct {
	pid:    posix.pid_t,
	fd:     posix.FD,
	output: strings.Builder,
}

native_prompt_worker_start :: proc(
	s: ^Native_Session,
	v: Native_Prompt_Values,
) -> (
	w: Native_Prompt_Worker,
) {
	if s.prompt.format == "" || !s.prompt_options.async_rprompt {
		return
	}
	version := ""
	if strings.contains(s.prompt.context_formats[v.context_name], "$version") {
		for pair in PROMPT_VERSION_CMDS {
			if pair[0] == v.context_name {
				version = pair[1]; break
			}
		}
	}
	if v.branch == "" && version == "" {
		return
	}
	script := strings.builder_make(context.temp_allocator)
	if v.branch != "" {
		// Match the generated prompt's repository-local filter and fsmonitor policy.
		strings.write_string(
			&script,
			`filters=$(git config --show-scope --get-regexp '` +
			PROMPT_GIT_FILTER_RE +
			`'); rc=$?
if [ "$rc" = 1 ] || { [ "$rc" = 0 ] && ! printf '%s\n' "$filters" | grep -Ev '^(global|system|command)[[:space:]]' | grep -q .; }; then
  ` +
			PROMPT_GIT_STATUS +
			` | awk 'END {if(NR) printf "%d",NR}'
fi`,
		)
	}
	strings.write_string(&script, "\nprintf '\\n'\n")
	strings.write_string(&script, version)
	cmd := strings.clone_to_cstring(strings.to_string(script), context.temp_allocator)
	args := [4]cstring{"sh", "-c", cmd, nil}
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		return
	}
	pid := posix.fork()
	if pid == 0 {
		posix.close(fds[0])
		if posix.setpgid(0, 0) != .OK {
			posix._exit(1)
		}
		null := posix.open("/dev/null", {.RDWR})
		if null < 0 {
			posix._exit(1)
		}
		posix.dup2(null, 0)
		posix.dup2(null, 2)
		posix.dup2(fds[1], 1)
		posix.close(null)
		posix.close(fds[1])
		posix.execv("/bin/sh", raw_data(args[:]))
		posix._exit(127)
	}
	posix.close(fds[1])
	if pid < 0 {
		posix.close(fds[0]); return
	}
	posix.setpgid(pid, pid)
	return {pid, fds[0], strings.builder_make(context.temp_allocator)}
}

native_prompt_worker_close :: proc(w: ^Native_Prompt_Worker, cancel: bool) {
	if w.pid <= 0 {
		return
	}
	posix.close(w.fd)
	if cancel {
		posix.killpg(w.pid, .SIGKILL)
	}
	status: c.int
	for posix.waitpid(w.pid, &status, {}) < 0 && posix.errno() == .EINTR {}
	w.pid = 0
}

// Return when stdin is ready or metadata changed enough to repaint.
native_prompt_wait :: proc(
	w: ^Native_Prompt_Worker,
	v: ^Native_Prompt_Values,
	cache: ^Native_Prompt_Cache,
) -> bool {
	for w.pid > 0 {
		fds := [2]posix.pollfd{{fd = 0, events = {.IN}}, {fd = w.fd, events = {.IN}}}
		if posix.poll(raw_data(fds[:]), 2, -1) < 0 {
			if posix.errno() == .EINTR {
				continue
			}
			return false
		}
		if fds[1].revents != {} {
			buf: [1024]u8
			n := posix.read(w.fd, &buf[0], len(buf))
			if n > 0 {
				strings.write_string(&w.output, string(buf[:n]))
			} else if n == 0 {
				native_prompt_worker_close(w, false)
				count, _, version := strings.partition(strings.to_string(w.output), "\n")
				new_version := strings.trim_space(version)
				changed := v.pending != count || v.version != new_version
				v.pending = count
				v.version = new_version
				native_prompt_cache_update(cache, v^)
				return changed
			} else if posix.errno() != .EINTR {
				native_prompt_worker_close(w, true)
			}
		}
		if fds[0].revents != {} {
			return false
		}
	}
	return false
}

native_right_prompt :: proc(s: ^Native_Session, v: Native_Prompt_Values) -> string {
	if s.minimal_prompt || v.pending == "" {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	native_prompt_module(
		&b,
		s.prompt_options.rprompt_format,
		{{"{git_branch}", v.branch}, {"{git_pending}", v.pending}},
	)
	return strings.to_string(b)
}
