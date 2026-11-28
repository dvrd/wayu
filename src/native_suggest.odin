package wayu

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"

Native_Suggest_Config :: struct {
	enabled, atuin: bool,
	style:          string,
	accept_keys:    map[string]bool,
}

native_suggest_defaults :: proc() -> Native_Suggest_Config {
	keys := make(map[string]bool)
	keys["\x19"] = true
	keys["\x1b[121;5u"] = true
	return {
		enabled = true,
		atuin = os.get_env("ATUIN_SESSION", context.temp_allocator) != "",
		style = "\x1b[2m",
		accept_keys = keys,
	}
}

native_suggest_configure :: proc(cfg: ^Native_Suggest_Config, content: string) {
	doc, _ := toml_doc_parse_alloc(content, context.temp_allocator)
	for key in ([]string{"settings.autosuggest", "autosuggest.enabled"}) {
		if v := get_toml_value(&doc, key); v != nil && v.type == .BOOLEAN {
			cfg.enabled = v.bool_val
		}
	}

	if !cfg.enabled {
		return
	}

	cfg.atuin = cfg.atuin || get_toml_value(&doc, "tools.atuin") != nil
	if CURRENT_COLOR_PROFILE != .ASCII {
		style := AUTOSUGGEST_DEFAULT_STYLE
		if v := autosuggest_style_value(&doc);
		   v != nil && v.type == .STRING && autosuggest_style_valid(v.str_val) {
			style = v.str_val
		}

		cfg.style = native_region_style(style)
	}

	configured := make(map[string]bool)
	for key in autosuggest_accept_keys(&doc) {
		if len(key) >= 2 && key[0] == '^' {
			ch := key[1] & 31
			if key[1] == '?' {
				ch = 127
			}

			configured[fmt.tprintf("%c%s", ch, key[2:])] = true
		} else if strings.has_prefix(key, "\x1b[") {
			configured[key] = true
		}
	}

	if len(configured) > 0 {
		cfg.accept_keys = configured
	}
}

// Each query contains every result for its prefix, so subsequent extensions
// can filter the same list without starting another process or scanning PATH.
Native_Suggest_Query :: struct {
	loaded:  bool,
	prefix:  string,
	results: []string,
}

Native_Suggest_Sources :: struct {
	atuin, commands: Native_Suggest_Query,
}

native_atuin_matches :: proc(q: ^Native_Suggest_Query, prefix: string) -> []string {
	if q.loaded && strings.has_prefix(prefix, q.prefix) {
		return q.results
	}

	q^ = {
		loaded = true,
		prefix = strings.clone(prefix, context.temp_allocator),
	}
	if script_find_on_path("atuin") == "" {
		return nil
	}

	marker := fmt.tprintf("\x1ewayu-%x~", rand.uint64())
	output := capture_command(
		{
			"atuin",
			"search",
			"--filter-mode",
			"global",
			"--search-mode",
			"prefix",
			"--format",
			strings.concatenate({marker, "{command}", marker}, context.temp_allocator),
			"--",
			prefix,
		},
	)
	defer delete(output)

	results := make([dynamic]string, context.temp_allocator)
	for record in strings.split(output, fmt.tprintf("%s\n", marker), context.temp_allocator) {
		if !strings.has_prefix(record, marker) {
			continue
		}

		cmd := strings.trim_suffix(record[len(marker):], marker)
		if cmd != "" && cmd[0] != ' ' && strings.has_prefix(cmd, prefix) {
			append(&results, strings.clone(cmd, context.temp_allocator))
		}
	}

	q.results = results[:]
	return q.results
}

native_command_matches :: proc(
	q: ^Native_Suggest_Query,
	s: ^Native_Session,
	prefix: string,
) -> []string {
	if prefix == "" {
		return nil
	}

	for ch in transmute([]u8)prefix {
		if !is_env_var_char(ch) && strings.index_byte(".+-", ch) < 0 {
			return nil
		}
	}

	if q.loaded && strings.has_prefix(prefix, q.prefix) {
		return q.results
	}

	names := make(map[string]bool, context.temp_allocator)
	native_command_names(s, &names, prefix)

	results := make([dynamic]string, context.temp_allocator)
	for name in names {append(&results, name)}

	slice.sort_by(
		results[:],
		proc(a, b: string) -> bool {return len(a) < len(b) || (len(a) == len(b) && a < b)},
	)
	q^ = {true, strings.clone(prefix, context.temp_allocator), results[:]}

	return q.results
}

native_suggestions :: proc(
	e: ^Native_Editor,
	h: ^Native_History,
	s: ^Native_Session,
	all := false,
) {
	if !s.suggest.enabled || (e.has_matches && (!all || e.all_matches)) {
		return
	}

	clear(&e.matches)
	e.match = 0
	if e.line == "" && !all {
		return
	}

	e.has_matches = true
	e.all_matches = all
	seen := make(map[string]bool)
	defer delete(seen)

	add :: proc(e: ^Native_Editor, seen: ^map[string]bool, cmd: string) -> bool {
		if len(cmd) <= len(e.line) || !strings.has_prefix(cmd, e.line) || cmd in seen^ {
			return false
		}

		seen^[cmd] = true
		append(&e.matches, cmd)
		return true
	}

	for commands in ([2][]string{h.commands[:], h.shell_commands}) {
		for i := len(commands) - 1; i >= 0; i -= 1 {
			if add(e, &seen, commands[i]) && !all {
				return
			}
		}
	}

	if s.suggest.atuin {
		for cmd in native_atuin_matches(&e.sources.atuin, e.line) {
			if add(e, &seen, cmd) && !all {
				return
			}
		}
	}

	if len(e.matches) == 0 {
		for cmd in native_command_matches(&e.sources.commands, s, e.line) {
			if add(e, &seen, cmd) && !all {
				return
			}
		}
	}
}
