package wayu

import "core:fmt"
import "core:os"
import "core:strings"

native_configure :: proc(s: ^Native_Session) {
	if content, ok := get_cached_toml_content(); ok {
		s.vi_mode = parse_interactive_config(content).vi_mode
		if prompt_is_enabled(content) {
			cfg := parse_full_prompt_config(content)
			defer destroy_full_prompt_config(&cfg)
			s.prompt_success = strings.clone(cfg.character_success)
			s.prompt_error = strings.clone(cfg.character_error)
			s.prompt_normal = strings.clone(cfg.vimcmd_symbol)
		}
	}
	store := entries_load()
	defer entries_store_destroy(&store)
	for entry in store.env {
		if !entry.secret && is_shell_var_name(entry.name) {
			if err := os.set_env(entry.name, entry.value); err != nil {
				fmt.eprintfln("wayu shell: export %s: %v", entry.name, err)
			}
		}
	}
	path := make([dynamic]string, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	// Only prepend wayu's scripts directory when it exists.
	if bin := script_path_value(); bin != "" && os.is_dir(bin) {
		append(&path, bin)
		seen[bin] = true
	}
	for entry in store.paths {
		dir := expand_env_vars(entry.dir, true)
		defer delete(dir)
		if dir != "" && !seen[dir] {
			copy_dir := strings.clone(dir, context.temp_allocator)
			append(&path, copy_dir)
			seen[copy_dir] = true
		}
	}
	if len(path) > 0 {
		old := os.get_env("PATH", context.temp_allocator)
		for dir in strings.split(old, ":", context.temp_allocator) {
			if !seen[dir] {
				copy_dir := strings.clone(dir, context.temp_allocator)
				append(&path, copy_dir)
				seen[copy_dir] = true
			}
		}
		_ = os.set_env("PATH", strings.join(path[:], ":", context.temp_allocator))
	}
	for a in store.aliases {
		parts := shell_parse_statements(a.value, .POSIX, true)
		if len(parts) != 1 || parts[0].error != "" {
			fmt.eprintfln("wayu shell: unsupported alias definition for %s", a.name)
			shell_statements_destroy(&parts)
			continue
		}
		s.aliases[strings.clone(a.name)] = parts
	}
}

native_alias_tokens :: proc(
	s: ^Native_Session,
	tokens: []ShellToken,
	output: ^[dynamic]ShellToken,
	active: ^map[string]bool,
	at_head: ^bool,
	target: ^bool,
) {
	for t in tokens {
		if t.kind == .Op {
			_, _, redirect := native_redirection(t.op)
			target^ = redirect
			if !target^ {
				at_head^ = true
			}
		} else if target^ {
			target^ = false
		} else if at_head^ {
			name := t.word.text
			alias, found := s.aliases[name]
			literal := true
			for expand in t.word.active {
				if !expand {
					literal = false
					break
				}
			}
			if found && literal && !active^[name] {
				active^[name] = true
				native_alias_tokens(s, alias[0].tokens[:], output, active, at_head, target)
				delete_key(active, name)
				continue
			}
			at_head^ = false
		}
		append(output, t)
	}
}

Native_Function :: struct {
	shell, path: string,
}

native_functions_load :: proc(s: ^Native_Session) {
	dir := fmt.tprintf("%s/functions", wayu.data)
	handle, err := os.open(dir)
	if err != nil {
		return
	}
	defer os.close(handle)
	entries, read_err := os.read_dir(handle, -1, context.temp_allocator)
	if read_err != nil {
		return
	}
	s.functions = make(map[string]Native_Function)
	// Prefer the configured shell, then use a stable order for other languages.
	for shell in ([]string{wayu.shell_ext, "zsh", "bash", "fish"}) {
		suffix := fmt.tprintf(".%s", shell)
		for entry in entries {
			if entry.type != .Regular || !strings.has_suffix(entry.name, suffix) {
				continue
			}
			name := strings.trim_suffix(entry.name, suffix)
			if _, exists := s.functions[name]; exists || !is_shell_identifier(name) {
				continue
			}
			s.functions[strings.clone(name)] = {
				strings.clone(shell),
				fmt.aprintf("%s/%s", dir, entry.name),
			}
		}
	}
}

native_function_args :: proc(fn: Native_Function, args: []string) -> []string {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, fn.shell)
	switch fn.shell {
	case "fish":
		append(
			&cmd,
			"--no-config",
			"-c",
			`source "$argv[1]"; or exit $status; "$argv[2]" $argv[3..-1]`,
			fn.path,
		)
	case "bash", "zsh":
		if fn.shell == "bash" {
			append(&cmd, "--noprofile", "--norc")
		} else {
			append(&cmd, "-f")
		}
		append(&cmd, "-c", `source "$1" || exit; shift; "$@"`, "wayu-function", fn.path)
	}
	append(&cmd, ..args)
	return cmd[:]
}

native_source :: proc(s: ^Native_Session, path: string) -> int {
	if s.source_depth >= 32 {
		fmt.eprintln("source: nesting exceeds 32 files")
		return 1
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("source: %s: %v", path, err)
		return 1
	}
	s.source_depth += 1
	defer s.source_depth -= 1
	native_eval(s, string(data))
	return s.status
}
