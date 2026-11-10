// prompt_generator.odin - Genera prompt nativo zsh pre-compilado
// Copied from starship.toml configuration - SIMPLIFIED VERSION
package wayu
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
// Convert a wayu style string (e.g. "bold green", "red italic", "242")
// into zsh prompt escapes (e.g. "%B%F{2}", "%F{1}%3m", "%F{242}").
style_to_zsh :: proc(style: string) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	tokens := strings.split(style, " ")
	defer delete(tokens)
	for token in tokens {
		t := strings.trim_space(token)
		if len(t) == 0 {
			continue
		}
		switch t {
		case "bold":
			strings.write_string(&b, "%B")
		case "italic":
			strings.write_string(&b, "%3m")
		case "underline":
			strings.write_string(&b, "%U")
		case "dim":
			strings.write_string(&b, "%2m")
		case:
			num := color_name_to_num(t)
			if num >= 0 {
				strings.write_string(&b, "%F{")
				strings.write_int(&b, num)
				strings.write_string(&b, "}")
			} else if all_digits(t) {
				strings.write_string(&b, "%F{")
				strings.write_string(&b, t)
				strings.write_string(&b, "}")
			}
		}
	}
	return strings.clone(strings.to_string(b))
}

color_name_to_num :: proc(name: string) -> int {
	switch name {
	case "black":
		return 0
	case "red":
		return 1
	case "green":
		return 2
	case "yellow":
		return 3
	case "blue":
		return 4
	case "magenta":
		return 5
	case "cyan":
		return 6
	case "white":
		return 7
	case "orange":
		return 208
	case "pink":
		return 205
	case "purple":
		return 129
	case "gray", "grey":
		return 242
	case "lime":
		return 118
	case "teal":
		return 30
	case:
		return -1
	}
}

all_digits :: proc(s: string) -> bool {
	for c in s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return len(s) > 0
}

// Convert a wayu DSL format string ("[text](style)" patterns) into zsh escapes.
dsl_to_zsh_format :: proc(format: string) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	i := 0
	for i < len(format) {
		lbracket := strings.index(format[i:], "[")
		if lbracket == -1 {
			strings.write_string(&b, format[i:]); break
		}
		lbracket += i
		strings.write_string(&b, format[i:lbracket])
		rbracket := strings.index(format[lbracket:], "]")
		if rbracket == -1 {
			strings.write_string(&b, format[lbracket:]); break
		}
		rbracket += lbracket
		if rbracket + 1 >= len(format) || format[rbracket + 1] != '(' {
			strings.write_string(&b, format[lbracket:rbracket + 1])
			i = rbracket + 1
			continue
		}
		lparen := rbracket + 1
		rparen := strings.index(format[lparen:], ")")
		if rparen == -1 {
			strings.write_string(&b, format[lbracket:]); break
		}
		rparen += lparen
		text := strings.trim_space(format[lbracket + 1:rbracket])
		style_str := strings.trim_space(format[lparen + 1:rparen])
		zsh := style_to_zsh(style_str)
		defer delete(zsh)
		strings.write_string(&b, zsh)
		strings.write_string(&b, text)
		strings.write_string(&b, "%f")
		i = rparen + 1
	}
	return strings.clone(strings.to_string(b))
}


// Configuración del prompt (basada en starship.toml)
PromptConfigFull :: struct {
	format:                string,
	character_success:     string,
	character_error:       string,
	vimcmd_symbol:         string,
	vimcmd_visual_symbol:  string,
	vimcmd_replace_symbol: string,
	username_show_always:  bool,

	// Per-module format strings (from each [prompt.*] section)
	username_format:       string,
	hostname_format:       string,
	localip_format:        string,
	dir_format:            string,
	git_branch_format:     string,

	// Per-language context entries from [prompt.contexts]
	// Key = language name, value = format string for {language_context}
	context_formats:       map[string]string,
	context_detects:       map[string][dynamic]string,
	// Context names in [prompt.contexts] file order (first match wins).
	context_order:         [dynamic]string,
}

// Free the heap parts of a PromptConfigFull (detect lists + containers).
// Format strings and context names are temp-allocated (or literals).
destroy_full_prompt_config :: proc(cfg: ^PromptConfigFull) {
	for _, list in cfg.context_detects {
		for item in list {delete(item)}
		delete(list)
	}
	delete(cfg.context_detects)
	delete(cfg.context_formats)
	delete(cfg.context_order)
}

// [prompt] / [prompt.*] are read through the one TOML parser (OKAMI-363;
// they were matched line by line with strings.contains): any valid TOML
// form works (dotted keys, multi-line strings, escapes, comments), keys only
// count in their own table, and a value of the wrong type keeps the
// default. Lenient, like the other generators: a bad line elsewhere in
// wayu.toml doesn't drop the prompt settings. The returned strings are
// temp-allocated; the doc lives in `arena` (caller destroys it).
@(private = "file")
prompt_doc_parse :: proc(toml: string, arena: ^virtual.Arena) -> (doc: TomlDoc, ok: bool) {
	if virtual.arena_init_growing(arena) != nil {
		return {}, false
	}
	doc, _ = toml_doc_parse_alloc(toml, virtual.arena_allocator(arena))
	return doc, true
}

// String at `key` (temp-allocated clone), found = false when absent or not
// a string.
@(private = "file")
prompt_get_string :: proc(doc: ^TomlDoc, key: string) -> (value: string, found: bool) {
	v := get_toml_value(doc, key)
	if v == nil || v.type != .STRING {
		return "", false
	}
	return strings.clone(v.str_val, context.temp_allocator), true
}

@(private = "file")
prompt_get_bool :: proc(doc: ^TomlDoc, key: string) -> (value: bool, found: bool) {
	v := get_toml_value(doc, key)
	if v == nil || v.type != .BOOLEAN {
		return false, false
	}
	return v.bool_val, true
}

// Parse [prompt] and its module tables (see prompt_doc_parse).
parse_full_prompt_config :: proc(toml: string) -> PromptConfigFull {
	cfg := PromptConfigFull {
		// Modules carry their own trailing separators (starship defaults).
		format                = "{username}{dir}{git_branch}{character} ",
		character_success     = "➜",
		character_error       = "✗",
		vimcmd_symbol         = "❮",
		vimcmd_visual_symbol  = "❮",
		vimcmd_replace_symbol = "❮",
		username_show_always  = false,
		username_format       = "[$user](white bold) in ",
		hostname_format       = "$hostname",
		localip_format        = "$localip",
		dir_format            = "[$dir](cyan bold) ",
		git_branch_format     = "on [$branch](magenta bold) ",
		context_formats       = make(map[string]string),
		context_detects       = make(map[string][dynamic]string),
		context_order         = make([dynamic]string),
	}

	arena: virtual.Arena
	doc, ok := prompt_doc_parse(toml, &arena)
	if !ok {
		return cfg
	}
	defer virtual.arena_destroy(&arena)

	// Non-empty strings only (an empty format would hide the module).
	formats := [?]struct {
		key:   string,
		field: ^string,
	} {
		{"prompt.format", &cfg.format},
		{"prompt.username.format", &cfg.username_format},
		{"prompt.hostname.format", &cfg.hostname_format},
		{"prompt.localip.format", &cfg.localip_format},
		{"prompt.dir.format", &cfg.dir_format},
		{"prompt.git_branch.format", &cfg.git_branch_format},
	}
	for f in formats {
		if v, found := prompt_get_string(&doc, f.key); found && len(v) > 0 {
			f.field^ = v
		}
	}
	// Symbols: the text between `[` and `]` of "[sym](style)".
	symbols := [?]struct {
		key:   string,
		field: ^string,
	} {
		{"prompt.character.success_symbol", &cfg.character_success},
		{"prompt.character.error_symbol", &cfg.character_error},
		{"prompt.character.vimcmd_symbol", &cfg.vimcmd_symbol},
		{"prompt.character.vimcmd_visual_symbol", &cfg.vimcmd_visual_symbol},
		{"prompt.character.vimcmd_replace_symbol", &cfg.vimcmd_replace_symbol},
	}
	for sym in symbols {
		if v, found := prompt_get_string(&doc, sym.key); found {
			if inner, has := prompt_bracket_symbol(v); has {
				sym.field^ = inner
			}
		}
	}
	if v, found := prompt_get_bool(&doc, "prompt.username.show_always"); found {
		cfg.username_show_always = v
	}
	prompt_read_contexts(&cfg, &doc)
	return cfg
}

// Symbol inside the brackets of "[sym](style)", trimmed.
@(private = "file")
prompt_bracket_symbol :: proc(value: string) -> (string, bool) {
	start := strings.index(value, "[")
	end := strings.index(value, "]")
	if start >= 0 && end > start {
		return strings.trim_space(value[start + 1:end]), true
	}
	return "", false
}

// [prompt.contexts]: `name = { format = "...", detect = [...] }` (or a
// [prompt.contexts.<name>] table), in file order. A repeated name keeps its
// first position and takes the last values.
@(private = "file")
prompt_read_contexts :: proc(cfg: ^PromptConfigFull, doc: ^TomlDoc) {
	for e in doc.entries {
		full := e.key
		if e.header >= 0 {
			h := doc.headers[e.header]
			if h.array {
				continue
			}
			parts := make([dynamic]string, context.temp_allocator)
			append(&parts, ..h.path)
			append(&parts, ..e.key)
			full = parts[:]
		}
		if len(full) < 3 || full[0] != "prompt" || full[1] != "contexts" {
			continue
		}
		name := strings.clone(full[2], context.temp_allocator)
		known := false
		for n in cfg.context_order {
			if n == name {
				known = true; break
			}
		}
		if !known {
			append(&cfg.context_order, name)
		}
		// An inline table entry (`name = {...}`) carries its own value (the
		// last duplicate wins); dotted keys / sub-tables are read below.
		table := e.value if len(full) == 3 else nil
		if table == nil {
			parent := get_toml_value(doc, fmt.tprintf("prompt.contexts.%s", full[2]))
			table = parent
		}
		if table == nil || table.type != .TABLE {
			continue
		}
		if f, has := table.table_val["format"]; has && f != nil && f.type == .STRING {
			cfg.context_formats[name] = strings.clone(f.str_val, context.temp_allocator)
		}
		if d, has := table.table_val["detect"]; has && d != nil && d.type == .ARRAY {
			list := make([dynamic]string)
			for item in d.arr_val {
				if item != nil && item.type == .STRING && len(item.str_val) > 0 {
					append(&list, strings.clone(item.str_val))
				}
			}
			if old, exists := cfg.context_detects[name]; exists {
				for item in old {delete(item)}
				delete(old)
			}
			cfg.context_detects[name] = list
		}
	}
}

// The native prompt is opt-in: it (and its zle widgets and precmd hooks) is
// generated only when wayu.toml has `enabled = true` under [prompt].
// Without it wayu leaves PROMPT, keymaps and zle widgets alone.
prompt_is_enabled :: proc(toml: string) -> bool {
	v, _ := prompt_table_bool(toml, "enabled")
	return v
}

// Boolean `key` directly under [prompt] (not its sub-tables); found = false
// when the key is absent or not a boolean.
prompt_table_bool :: proc(toml: string, key: string) -> (value: bool, found: bool) {
	arena: virtual.Arena
	doc, ok := prompt_doc_parse(toml, &arena)
	if !ok {
		return false, false
	}
	defer virtual.arena_destroy(&arena)
	return prompt_get_bool(&doc, fmt.tprintf("prompt.%s", key))
}

// Values that come from outside the config (git branch, local IP, tool
// version, shell name) spliced into the prompt with every `%` doubled: the
// prompt is %-expanded after the values are substituted, so a branch named
// `feat%n-%D{%Y}` printed the user name and the date, or any other prompt
// escape (OKAMI-343). zsh's own %~ / %n / %m output is not re-expanded.
PROMPT_GIT_BRANCH :: `${_WAYU_GIT_BRANCH//\%/%%}`
PROMPT_LOCALIP :: `${_WAYU_LOCALIP//\%/%%}`
PROMPT_CONTEXT_VER :: `${_WAYU_CONTEXT_VER//\%/%%}`

// Escape `s` for splicing inside a zsh double-quoted string: backslash, `"`,
// `$` and backtick are backslash-escaped so config text is always literal (no `$(...)` execution,
// no broken quoting). Prompt `%` escapes are left for prompt expansion.
// Returns a temp-allocated string.
prompt_dq_escape :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '\\', '"', '$', '`':
			strings.write_byte(&sb, '\\')
		}
		strings.write_byte(&sb, c)
	}
	return strings.to_string(sb)
}

// Render a module format (DSL) to an escaped double-quote body, then swap the
// escaped module variables (`\$user`, ...) for generated zsh code. vars are
// {escaped_name, replacement}. Temp-allocated.
prompt_render_module :: proc(dsl_format: string, vars: [][2]string) -> string {
	rendered := dsl_to_zsh_format(dsl_format)
	defer delete(rendered)
	out := prompt_dq_escape(rendered)
	for v in vars {
		out, _ = strings.replace_all(out, v[0], v[1], context.temp_allocator)
	}
	return out
}

// Generate shell code for a single prompt token (content only, no styling).
// Called by the format walker for both bare {token} and styled [{token}](style).
generate_prompt_token :: proc(builder: ^strings.Builder, cfg: PromptConfigFull, name: string) {
	// Each token has a per-module format string from [prompt.<name>].
	// The format uses the DSL ([text](style)) and module-specific variables
	// ($user, $hostname, $localip, $dir, $branch) that get replaced with
	// zsh escapes or shell commands.

	// Config text is escaped (prompt_render_module) so only the generated
	// replacements below can expand; `$(...)` typed in wayu.toml stays literal.
	if name == "username" {
		// Like starship: only over SSH or as root unless show_always = true.
		rendered := prompt_render_module(cfg.username_format, {{`\$user`, "%n"}})
		indent := "  "
		if !cfg.username_show_always {
			fmt.sbprintln(
				builder,
				`  if [[ -n "${SSH_CONNECTION-}${SSH_CLIENT-}${SSH_TTY-}" ]] || (( EUID == 0 )); then`,
			)
			indent = "    "
		}
		strings.write_string(builder, indent)
		strings.write_string(builder, `result+="`)
		strings.write_string(builder, rendered)
		strings.write_string(builder, `"`)
		fmt.sbprintln(builder)
		if !cfg.username_show_always {
			fmt.sbprintln(builder, "  fi")
		}
	} else if name == "hostname" {
		rendered := prompt_render_module(cfg.hostname_format, {{`\$hostname`, "%m"}})
		strings.write_string(builder, `  result+="`)
		strings.write_string(builder, rendered)
		strings.write_string(builder, `"`)
		fmt.sbprintln(builder)
	} else if name == "localip" {
		// $localip gets replaced with a shell subshell that fetches the IP
		// Looked up once per prompt by _wayu_update_localip (precmd).
		rendered := prompt_render_module(cfg.localip_format, {{`\$localip`, PROMPT_LOCALIP}})
		strings.write_string(builder, `  result+="`)
		strings.write_string(builder, rendered)
		strings.write_string(builder, `"`)
		fmt.sbprintln(builder)
	} else if name == "dir" {
		rendered := prompt_render_module(
			cfg.dir_format,
			{{`\$basename`, "%1~"}, {`\$pwd`, "%/"}, {`\$dir`, "%~"}},
		)
		strings.write_string(builder, `  result+="`)
		strings.write_string(builder, rendered)
		strings.write_string(builder, `"`)
		fmt.sbprintln(builder)
	} else if name == "git_branch" {
		rendered := prompt_render_module(cfg.git_branch_format, {{`\$branch`, PROMPT_GIT_BRANCH}})
		fmt.sbprintln(builder, `  if [[ -n "$_WAYU_GIT_BRANCH" ]]; then`)
		strings.write_string(builder, `    result+="`)
		strings.write_string(builder, rendered)
		strings.write_string(builder, `"`)
		fmt.sbprintln(builder)
		fmt.sbprintln(builder, "  fi")
	} else if name == "language_context" || name == "context_icon" {
		// Render per-language format from [prompt.contexts], fallback to shell name
		fmt.sbprintln(builder, `  case "$_WAYU_CONTEXT" in`)
		for lang, fmt_str in cfg.context_formats {
			// $version -> async-fetched version string
			rendered := prompt_render_module(fmt_str, {{`\$version`, PROMPT_CONTEXT_VER}})
			strings.write_string(builder, `    `)
			// Same sanitizing as _wayu_detect_context's _WAYU_CONTEXT values.
			strings.write_string(builder, sanitize_ident(lang))
			strings.write_string(builder, `) result+="`)
			strings.write_string(builder, rendered)
			strings.write_string(builder, `" ;;`)
			fmt.sbprintln(builder)
		}
		// Default: show shell name
		fmt.sbprintln(builder, `    *) result+="${${SHELL:t}//\%/%%}" ;;`)
		fmt.sbprintln(builder, "  esac")
	} else if name == "character" {
		fmt.sbprintln(builder, "  local char_symbol char_color")
		fmt.sbprintln(builder, `  case "$_WAYU_VI_MODE" in`)
		fmt.sbprint(builder, `    INSERT) char_symbol="`)
		fmt.sbprint(builder, prompt_dq_escape(cfg.character_success))
		fmt.sbprintln(builder, `" ;;`)
		fmt.sbprint(builder, `    NORMAL) char_symbol="`)
		fmt.sbprint(builder, prompt_dq_escape(cfg.vimcmd_symbol))
		fmt.sbprintln(builder, `" ;;`)
		fmt.sbprint(builder, `    VISUAL) char_symbol="`)
		fmt.sbprint(builder, prompt_dq_escape(cfg.vimcmd_visual_symbol))
		fmt.sbprintln(builder, `" ;;`)
		fmt.sbprint(builder, `    REPLACE|REPLACE_ONE) char_symbol="`)
		fmt.sbprint(builder, prompt_dq_escape(cfg.vimcmd_replace_symbol))
		fmt.sbprintln(builder, `" ;;`)
		fmt.sbprintln(builder, "    *)")
		fmt.sbprintln(builder, "      if [[ ${_WAYU_LAST_EXIT:-0} -eq 0 ]]; then")
		fmt.sbprint(builder, `        char_symbol="`)
		fmt.sbprint(builder, prompt_dq_escape(cfg.character_success))
		fmt.sbprintln(builder, `"`)
		fmt.sbprintln(builder, "      else")
		fmt.sbprint(builder, `        char_symbol="`)
		fmt.sbprint(builder, prompt_dq_escape(cfg.character_error))
		fmt.sbprintln(builder, `"`)
		fmt.sbprintln(builder, "      fi")
		fmt.sbprintln(builder, `    ;;`)
		fmt.sbprintln(builder, "  esac")
		fmt.sbprintln(builder, `  case "$_WAYU_VI_MODE" in`)
		fmt.sbprintln(builder, `    INSERT) char_color="202" ;;`)
		fmt.sbprintln(builder, `    NORMAL) char_color="2" ;;`)
		fmt.sbprintln(builder, `    VISUAL) char_color="129" ;;`)
		fmt.sbprintln(builder, `    REPLACE|REPLACE_ONE) char_color="129" ;;`)
		fmt.sbprintln(builder, "    *)")
		fmt.sbprintln(builder, "      if [[ ${_WAYU_LAST_EXIT:-0} -eq 0 ]]; then")
		fmt.sbprintln(builder, `        char_color="2"`)
		fmt.sbprintln(builder, "      else")
		fmt.sbprintln(builder, `        char_color="1"`)
		fmt.sbprintln(builder, "      fi")
		fmt.sbprintln(builder, `    ;;`)
		fmt.sbprintln(builder, "  esac")
		fmt.sbprintln(builder, `  result+="%F{${char_color}}%B${char_symbol}%b%F{reset}"`)
	}
}

// _wayu_update_git_info (precmd): sets _WAYU_GIT_BRANCH and _WAYU_GIT_DIR
// (work tree top, "" when unknown) without forking (OKAMI-285). The git dir
// is found by walking up from $PWD — a `.git` dir, or a `.git` file
// "gitdir: ..." (worktrees, submodules); $GIT_DIR wins — and HEAD is read
// with the `read` builtin: "ref: refs/heads/<branch>", or a commit id when
// detached (first 7 characters). Only the reftable placeholder HEAD
// (refs/heads/.invalid) asks git itself. A checkout shows at the next prompt.
PROMPT_GIT_INFO_ZSH :: `_wayu_update_git_info() {
  emulate -L zsh
  local d=$PWD g="" top="" l=""
  if [[ -n ${GIT_DIR-} ]]; then
    g=${GIT_DIR:a}
  else
    while true; do
      if [[ -d $d/.git ]]; then
        g=$d/.git top=$d
        break
      elif [[ -f $d/.git ]]; then
        { read -r l < $d/.git } 2>/dev/null
        if [[ $l == 'gitdir: '* ]]; then
          g=${l#gitdir: } top=$d
          [[ $g == /* ]] || g=$d/$g
        fi
        break
      fi
      [[ $d == / || -z $d ]] && break
      d=${d:h}
    done
  fi
  _WAYU_GIT_BRANCH="" _WAYU_GIT_DIR=$top
  [[ -n $g ]] || return 0
  l=""
  { read -r l < $g/HEAD } 2>/dev/null || return 0
  if [[ $l == 'ref: refs/heads/.invalid' ]]; then
    _WAYU_GIT_BRANCH="$(command git symbolic-ref --short HEAD 2>/dev/null)"
  elif [[ $l == 'ref: refs/heads/'* ]]; then
    _WAYU_GIT_BRANCH=${l#ref: refs/heads/}
  elif [[ $l == 'ref: '* ]]; then
    _WAYU_GIT_BRANCH=${l#ref: }
  else
    _WAYU_GIT_BRANCH=${l[1,7]}
  fi
  return 0
}
`

generate_full_prompt :: proc(cfg: PromptConfigFull) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	fmt.sbprintln(&builder, "# --- Wayu Native Prompt (from starship.toml) ---")
	fmt.sbprintln(&builder)

	// Git branch for the prompt, without forking (OKAMI-285): see
	// PROMPT_GIT_INFO_ZSH. The dirty count stays in the async worker.
	fmt.sbprintln(&builder, "typeset -g _WAYU_GIT_BRANCH=\"\"")
	fmt.sbprintln(&builder, "typeset -g _WAYU_GIT_DIR=\"\"")
	fmt.sbprintln(&builder)
	fmt.sbprint(&builder, PROMPT_GIT_INFO_ZSH)
	fmt.sbprintln(&builder)

	// Hook precmd
	fmt.sbprintln(&builder, "autoload -Uz add-zsh-hook")
	fmt.sbprintln(&builder, "add-zsh-hook precmd _wayu_update_git_info")
	if strings.contains(cfg.format, "{localip}") {
		fmt.sbprintln(&builder, `typeset -g _WAYU_LOCALIP=""`)
		fmt.sbprintln(
			&builder,
			`_wayu_update_localip() { _WAYU_LOCALIP="$(command ipconfig getifaddr en0 2>/dev/null || command ip -4 route get 1 2>/dev/null | command awk '{print $7; exit}')"; }`,
		)
		fmt.sbprintln(&builder, "add-zsh-hook precmd _wayu_update_localip")
	}
	fmt.sbprintln(&builder)

	// The full prompt text, built in the shell itself (no subshell, no fork)
	// into REPLY; _wayu_prompt_render stores it for PROMPT.
	fmt.sbprintln(&builder, "_wayu_prompt_full() {")
	fmt.sbprintln(&builder, `  local result=""`)
	fmt.sbprintln(&builder, "  # _WAYU_LAST_EXIT set by _wayu_prompt_master")
	fmt.sbprintln(&builder)

	// Procesar cada componente según el format
	// Manejar newlines en el format (reemplazar \n literal con newline real)
	format_with_newlines, was_alloc := strings.replace_all(cfg.format, `\n`, "\n")
	defer if was_alloc {
		delete(format_with_newlines)
	}
	format_parts := strings.split(format_with_newlines, "\n")
	defer delete(format_parts)

	for part, i in format_parts {
		// Añadir newline antes de cada parte excepto la primera
		if i > 0 {
			fmt.sbprintln(&builder, `  result+=$'\n'`)
		}

		// Walk the format part, emitting literal text between tokens.
		// Supports: {token} (bare) and [{token}](style) (styled via DSL)
		pos := 0
		for pos < len(part) {
			// Check for [{token}](style) pattern first
			open_bracket := strings.index(part[pos:], "[{")
			open_brace := strings.index(part[pos:], "{")

			// If [{...}](...) comes before or at same position as bare {
			if open_bracket != -1 && (open_brace == -1 || open_bracket <= open_brace) {
				open_bracket += pos
				// Emit literal text before the bracket
				if open_bracket > pos {
					literal := part[pos:open_bracket]
					fmt.sbprint(&builder, `  result+="`)
					fmt.sbprint(&builder, prompt_dq_escape(literal))
					fmt.sbprintln(&builder, `"`)
				}

				// Find closing }](style)
				close_bracket := strings.index(part[open_bracket:], "}]")
				if close_bracket != -1 {
					close_bracket += open_bracket
					token_name := part[open_bracket + 2:close_bracket] // between [{ and }]

					// Check for (style) after }]
					if close_bracket + 2 < len(part) && part[close_bracket + 2] == '(' {
						close_paren := strings.index(part[close_bracket + 2:], ")")
						if close_paren != -1 {
							close_paren += close_bracket + 2
							style_str := strings.trim_space(part[close_bracket + 3:close_paren])

							// Emit style start
							token_style := style_to_zsh(style_str)
							defer delete(token_style)
							fmt.sbprint(&builder, `  result+="`)
							fmt.sbprint(&builder, token_style)
							fmt.sbprintln(&builder, `"`)

							// Generate token code (will be wrapped in style)
							generate_prompt_token(&builder, cfg, token_name)

							// Emit style end
							fmt.sbprintln(&builder, `  result+="%f"`)

							pos = close_paren + 1
							continue
						}
					}
				}
				// Fallback: treat [ as literal
				fmt.sbprint(&builder, `  result+="`)
				fmt.sbprint(&builder, "[")
				fmt.sbprintln(&builder, `"`)
				pos = open_bracket + 1
				continue
			}

			if open_brace == -1 {
				// Remaining text is literal
				remaining := part[pos:]
				if len(remaining) > 0 {
					fmt.sbprint(&builder, `  result+="`)
					fmt.sbprint(&builder, prompt_dq_escape(remaining))
					fmt.sbprintln(&builder, `"`)
				}
				break
			}
			open_brace += pos

			// Emit literal text before the token
			if open_brace > pos {
				literal := part[pos:open_brace]
				fmt.sbprint(&builder, `  result+="`)
				fmt.sbprint(&builder, prompt_dq_escape(literal))
				fmt.sbprintln(&builder, `"`)
			}

			close_brace := strings.index(part[open_brace:], "}")
			if close_brace == -1 {
				// Unclosed — emit as literal
				fmt.sbprint(&builder, `  result+="`)
				fmt.sbprint(&builder, prompt_dq_escape(part[open_brace:]))
				fmt.sbprintln(&builder, `"`)
				break
			}
			close_brace += open_brace
			token := part[open_brace + 1:close_brace]
			pos = close_brace + 1

			// Generate shell code for known token
			generate_prompt_token(&builder, cfg, token)
		}
	} // Cierre del for loop

	fmt.sbprintln(&builder, `  REPLY=$result`)
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)

	// NOTA: PROMPT se configura en generate_interactive_prompt
	// para permitir integración con features interactivas

	return strings.clone(strings.to_string(builder))
}

InteractiveConfig :: struct {
	// Toggle
	toggle_key:        string,
	toggle_enabled:    bool,

	// VI Mode: `[prompt] vi_mode = true` switches the line editor to the vi
	// keymap (default false: the keymap is left alone, OKAMI-285);
	// vi_mode_indicator ([prompt.interactive]) adds the mode indicator.
	vi_mode:           bool,
	vi_mode_indicator: bool,
	vi_insert_symbol:  string,
	vi_normal_symbol:  string,
	vi_visual_symbol:  string,

	// Context
	context_aware:     bool,

	// Async
	async_rprompt:     bool,
	rprompt_format:    string,

	// Transient
	transient_enabled: bool,
	transient_format:  string,

	// [prompt.contexts] (detect lists) used to generate context detection.
	// Optional; nil means built-in detection only.
	contexts:          ^PromptConfigFull,
}

// Genera todo el código interactivo
generate_interactive_prompt :: proc(base_prompt: string, cfg: InteractiveConfig) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	fmt.sbprintln(&builder, "# --- Interactive Prompt Features ---")
	fmt.sbprintln(&builder)

	// Include base prompt function
	fmt.sbprintln(&builder, "# --- Base Prompt (from starship.toml) ---")
	fmt.sbprint(&builder, base_prompt)
	fmt.sbprintln(&builder)

	// Variables de estado
	fmt.sbprintln(&builder, "# State variables")
	fmt.sbprintln(&builder, "typeset -g _WAYU_PROMPT_MODE=\"full\"")
	// "" = no vi mode: the character module then reflects the exit status.
	fmt.sbprintfln(
		&builder,
		"typeset -g _WAYU_VI_MODE=\"%s\"",
		"INSERT" if cfg.vi_mode && cfg.vi_mode_indicator else "",
	)
	fmt.sbprintln(&builder, "typeset -g _WAYU_CONTEXT=\"default\"")
	fmt.sbprintln(&builder, "typeset -g _WAYU_CONTEXT_VER=\"\"")
	fmt.sbprintln(&builder, "typeset -g _WAYU_ASYNC_DATA=\"\"")
	fmt.sbprintln(&builder)

	// 1. VI MODE (first: `bindkey -v` resets the main keymap, so any
	// binding made before it would land in the wrong keymap)
	if cfg.vi_mode {
		generate_vi_mode_feature(&builder, cfg)
	}

	// 2. TOGGLE FEATURE (opt-in)
	if cfg.toggle_enabled {
		generate_toggle_feature(&builder, cfg.toggle_key, cfg.vi_mode)
	}

	// 3. CONTEXT AWARE
	if cfg.context_aware {
		generate_context_feature(&builder, cfg.contexts)
	}

	// 4. ASYNC RPROMPT
	if cfg.async_rprompt {
		generate_async_feature(&builder, cfg.rprompt_format)
	}

	// 5. TRANSIENT PROMPT
	if cfg.transient_enabled {
		generate_transient_feature(&builder, cfg.transient_format)
	}

	// 6. SEPARATOR LINE (línea entre output y prompt)
	generate_separator_feature(&builder)

	// The prompt is rendered without command substitution (OKAMI-375):
	// PROMPT='${_WAYU_PS1}' (promptsubst) and _wayu_prompt_render computes
	// _WAYU_PS1 in the shell itself — from precmd (_wayu_prompt_master,
	// which captures the exit status first), and from the widgets / signal
	// handler that change what it shows (vi mode, toggle, async data) right
	// before their `zle reset-prompt`. A parameter's value is not expanded
	// again, so a `$(...)` in a branch name stays text.
	fmt.sbprintln(&builder, "# --- Master Prompt Function ---")
	fmt.sbprintln(&builder, `typeset -g _WAYU_PS1="${_WAYU_PS1-}"`)
	fmt.sbprintln(&builder, "_wayu_prompt_render() {")
	fmt.sbprintln(&builder, "  local REPLY=\"\"")
	if cfg.toggle_enabled || cfg.transient_enabled {
		fmt.sbprintln(&builder, "  if [[ \"$_WAYU_PROMPT_MODE\" == \"minimal\" ]]; then")
		if cfg.transient_enabled {
			fmt.sbprintln(&builder, "    _wayu_prompt_transient")
		} else {
			fmt.sbprintln(&builder, "    REPLY=\"%~ ➜ \"")
		}
		fmt.sbprintln(&builder, "  else")
		fmt.sbprintln(&builder, "    _wayu_prompt_full")
		fmt.sbprintln(&builder, "  fi")
	} else {
		fmt.sbprintln(&builder, "  _wayu_prompt_full")
	}
	fmt.sbprintln(&builder, "  _WAYU_PS1=$REPLY")
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder, "_wayu_prompt_master() {")
	fmt.sbprintln(&builder, "  export _WAYU_LAST_EXIT=$?")
	fmt.sbprintln(&builder, "  _wayu_prompt_render")
	fmt.sbprintln(&builder, "  return $_WAYU_LAST_EXIT")
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)

	// PROMPT/RPROMPT are set now and set again at the first prompt (a
	// one-shot precmd hook): wayu may be loaded from .zshenv, and a login
	// shell then runs /etc/zshrc (macOS: `PS1="%n@%m %1~ %# "`) and other
	// startup files afterwards, which would replace the prompt.
	fmt.sbprintln(&builder, "_wayu_prompt_set() {")
	fmt.sbprintln(&builder, "  setopt promptsubst")
	fmt.sbprintln(&builder, `  PROMPT=$'\n''${_WAYU_PS1}'`)
	if cfg.async_rprompt {
		fmt.sbprintln(&builder, `  RPROMPT='${_WAYU_ASYNC_DATA}'`)
	} else {
		fmt.sbprintln(&builder, "  unset RPROMPT")
	}
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder, "_wayu_prompt_set")
	fmt.sbprintln(&builder, "_wayu_prompt_reassert() {")
	fmt.sbprintln(&builder, "  local s=$?")
	fmt.sbprintln(&builder, "  _wayu_prompt_set")
	fmt.sbprintln(&builder, "  add-zsh-hook -d precmd _wayu_prompt_reassert")
	fmt.sbprintln(&builder, "  return $s")
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder, "autoload -Uz add-zsh-hook")
	fmt.sbprintln(&builder, "add-zsh-hook precmd _wayu_prompt_reassert")
	// After _wayu_update_git_info (added with the base prompt).
	fmt.sbprintln(&builder, "add-zsh-hook precmd _wayu_prompt_master")

	return strings.clone(strings.to_string(builder))
}

// TOGGLE FEATURE. Bound in explicit keymaps: viins + vicmd with the vi
// keymap wayu sets up, emacs otherwise.
generate_toggle_feature :: proc(b: ^strings.Builder, key: string, vi: bool) {
	fmt.sbprintln(b, "# --- Feature: Toggle Prompt (Minimal/Full) ---")
	fmt.sbprintln(b, "_wayu_toggle_prompt() {")
	fmt.sbprintln(b, "  if [[ \"$_WAYU_PROMPT_MODE\" == \"full\" ]]; then")
	fmt.sbprintln(b, `    _WAYU_PROMPT_MODE="minimal"`)
	fmt.sbprintln(b, "  else")
	fmt.sbprintln(b, `    _WAYU_PROMPT_MODE="full"`)
	fmt.sbprintln(b, "  fi")
	fmt.sbprintln(b, "  _wayu_prompt_render; zle reset-prompt")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "zle -N _wayu_toggle_prompt")
	key_q := shell_single_quote(key, context.temp_allocator)
	for keymap in ([]string{"viins", "vicmd"} if vi else []string{"emacs"}) {
		fmt.sbprintfln(b, "bindkey -M %s %s _wayu_toggle_prompt", keymap, key_q)
	}
	fmt.sbprintln(b)
}

// VI MODE FEATURE (`[prompt] vi_mode = true`): vi keymap, then — unless
// vi_mode_indicator = false — the mode indicator. zle-line-init and
// zle-keymap-select are CHAINED (OKAMI-285): a widget already installed
// under that name (by the user, a plugin or another prompt) is kept as
// _wayu_prev_<name> and called first. Re-sourcing core doesn't chain wayu's
// widget to itself.
generate_vi_mode_feature :: proc(b: ^strings.Builder, cfg: InteractiveConfig) {
	fmt.sbprintln(b, "# --- Feature: VI Mode ---")
	fmt.sbprintln(b, "bindkey -v")
	fmt.sbprintln(b, "KEYTIMEOUT=1  # shorter delay when switching modes")
	fmt.sbprintln(b, "bindkey -M viins '^?' backward-delete-char")
	fmt.sbprintln(b, "bindkey -M viins '^H' backward-delete-char")
	fmt.sbprintln(b)
	if !cfg.vi_mode_indicator {
		return
	}
	fmt.sbprint(b, PROMPT_VI_INDICATOR_ZSH)
	fmt.sbprintln(b)
}

PROMPT_VI_INDICATOR_ZSH :: `_wayu_vi_mode_from_keymap() {
  local m
  case $KEYMAP in
    vicmd) m=NORMAL ;;
    visual|vivis) m=VISUAL ;;
    *) m=INSERT ;;
  esac
  [[ $m == "$_WAYU_VI_MODE" ]] && return 0
  _WAYU_VI_MODE=$m
  _wayu_prompt_render; zle reset-prompt
}
_wayu_zle_keymap_select() {
  (( ${+widgets[_wayu_prev_zle-keymap-select]} )) && zle _wayu_prev_zle-keymap-select -- "$@"
  _wayu_vi_mode_from_keymap
}
_wayu_zle_line_init() {
  (( ${+widgets[_wayu_prev_zle-line-init]} )) && zle _wayu_prev_zle-line-init -- "$@"
  _wayu_vi_mode_from_keymap
}
# Install $2 as special widget $1, keeping an existing $1 as _wayu_prev_$1.
_wayu_zle_chain() {
  [[ ${widgets[$1]-} == "user:$2" ]] && return 0
  if (( ${+widgets[$1]} )); then
    zle -A "$1" "_wayu_prev_$1"
  fi
  zle -N "$1" "$2"
}
_wayu_zle_chain zle-keymap-select _wayu_zle_keymap_select
_wayu_zle_chain zle-line-init _wayu_zle_line_init

# Visual mode (zle-keymap-select doesn't fire for it)
_wayu_visual_mode() {
  zle visual-mode
  _WAYU_VI_MODE="VISUAL"
  _wayu_prompt_render; zle reset-prompt
}
_wayu_visual_line_mode() {
  zle visual-line-mode
  _WAYU_VI_MODE="VISUAL"
  _wayu_prompt_render; zle reset-prompt
}
zle -N _wayu_visual_mode
zle -N _wayu_visual_line_mode
bindkey -M vicmd 'v' _wayu_visual_mode
bindkey -M vicmd 'V' _wayu_visual_line_mode

# Leave visual mode: 'i' -> INSERT, Esc -> NORMAL (cancelling the selection)
bindkey -M visual 'i' vi-insert
_wayu_visual_exit() {
  zle deactivate-region
  zle vi-cmd-mode
}
zle -N _wayu_visual_exit
bindkey -M visual $'\e' _wayu_visual_exit
`

// 3. CONTEXT AWARE
// File-existence only detection (instant, no subprocesses).
// Version string is fetched asynchronously by the async worker.
generate_context_feature :: proc(b: ^strings.Builder, contexts: ^PromptConfigFull = nil) {
	fmt.sbprintln(b, "# --- Feature: Context-Aware Prompt ---")
	fmt.sbprintln(b, "# File-only detection (instant). Version fetched async.")
	fmt.sbprintln(b, "_wayu_detect_context() {")
	// Reset options locally: the *.odin(NY1) tests below use bare glob
	// qualifiers, which blow up with "no matches found" in any shell that runs
	// with NO_BARE_GLOB_QUAL (some tool/agent harnesses do). emulate -L zsh
	// restores zsh defaults for the body only, and null_glob keeps a
	// non-matching pattern from erroring at all.
	fmt.sbprintln(b, "  emulate -L zsh -o null_glob")
	fmt.sbprintln(b, `  _WAYU_CONTEXT_VER=""`)

	// User-defined [prompt.contexts] detect lists come first, in file order;
	// built-in rules follow only for names the user didn't configure.
	configured := make(map[string]bool, 16, context.temp_allocator)
	first := true
	if contexts != nil {
		for name in contexts.context_order {
			detects, has := contexts.context_detects[name]
			if !has || len(detects) == 0 {
				continue
			}
			cond := context_detect_condition(detects[:])
			if len(cond) == 0 {
				continue
			}
			configured[name] = true
			strings.write_string(b, "  if " if first else "  elif ")
			strings.write_string(b, cond)
			strings.write_string(b, `; then _WAYU_CONTEXT="`)
			strings.write_string(b, sanitize_ident(name))
			strings.write_string(b, "\"\n")
			first = false
		}
	}

	// Built-in detection: (context name, condition).
	BUILTIN :: [?][2]string {
		{"rust", `[[ -f "Cargo.toml" ]]`},
		{"bun", `[[ -f "bun.lockb" ]] || [[ -f "bunfig.toml" ]]`},
		{"gleam", `[[ -f "gleam.toml" ]]`},
		{"swift", `[[ -f "Package.swift" ]]`},
		{"dart", `[[ -f "pubspec.yaml" ]]`},
		{"php", `[[ -f "composer.json" ]]`},
		{"ruby", `[[ -f "Gemfile" ]] || [[ -f ".ruby-version" ]]`},
		{"elixir", `[[ -f "mix.exs" ]]`},
		{"erlang", `[[ -f "rebar.config" ]] || [[ -f "erlang.mk" ]]`},
		{"haskell", `[[ -f "stack.yaml" ]] || [[ -f "cabal.project" ]]`},
		{"julia", `[[ -f "Project.toml" ]] || [[ -f "Manifest.toml" ]]`},
		{
			"odin",
			`[[ -f "ols.json" ]] || (){ [[ -e $1 ]] } *.odin(NY1) || (){ [[ -e $1 ]] } src/*.odin(NY1)`,
		},
		{"golang", `[[ -f "go.mod" ]]`},
		{"nim", `[[ -f "nim.cfg" ]]`},
		{"ocaml", `[[ -f "dune" ]]`},
		{"nix", `[[ -f "flake.nix" ]] || [[ -f "default.nix" ]]`},
		{"deno", `[[ -f "deno.json" ]] || [[ -f "deno.jsonc" ]]`},
		{"elm", `[[ -f "elm.json" ]]`},
		{"crystal", `[[ -f "shard.yml" ]]`},
		{"perl", `[[ -f "cpanfile" ]]`},
		{"buf", `[[ -f "buf.yaml" ]]`},
		{"nodejs", `[[ -f "package.json" ]]`},
		{"java", `[[ -f "pom.xml" ]] || [[ -f "build.gradle" ]]`},
		{"scala", `[[ -f "build.sbt" ]]`},
		{"python", `[[ -f "requirements.txt" ]] || [[ -f "pyproject.toml" ]]`},
		{"zig", `[[ -f "build.zig" ]] || [[ -f "build.zig.zon" ]]`},
		{"rlang", `[[ -f "DESCRIPTION" ]]`},
		{"lua", `[[ -f ".lua-version" ]]`},
		{"docker", `[[ -f "Dockerfile" ]] || [[ -f "docker-compose.yml" ]]`},
		{"aws", `[[ -e ".aws" ]]`},
	}
	for entry in BUILTIN {
		if configured[entry[0]] {
			continue
		}
		strings.write_string(b, "  if " if first else "  elif ")
		strings.write_string(b, entry[1])
		strings.write_string(b, `; then _WAYU_CONTEXT="`)
		strings.write_string(b, entry[0])
		strings.write_string(b, "\"\n")
		first = false
	}
	fmt.sbprintln(b, `  else _WAYU_CONTEXT="default"`)
	fmt.sbprintln(b, "  fi")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)
	fmt.sbprintln(b, "autoload -Uz add-zsh-hook")
	fmt.sbprintln(b, "add-zsh-hook chpwd _wayu_detect_context")
	fmt.sbprintln(b, "_wayu_detect_context  # Detect on startup")
	fmt.sbprintln(b)
}

// Build a zsh condition from a [prompt.contexts] detect list.
//   "Cargo.toml" -> [[ -e 'Cargo.toml' ]]
//   "*.kt"       -> (){ [[ -e $1 ]] } *.kt(NY1)   (null-glob, stop at 1)
// Entries with characters outside a conservative filename/glob set are
// skipped so a config value can never inject shell code. Returns a
// temp-allocated string ("" when no entry is usable).
context_detect_condition :: proc(detects: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	n := 0
	for raw in detects {
		item := strings.trim_space(raw)
		if len(item) == 0 {
			continue
		}
		safe := true
		is_glob := false
		for i in 0 ..< len(item) {
			c := item[i]
			switch {
			case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
			case c == '.' || c == '_' || c == '-' || c == '/' || c == '+' || c == '@':
			case c == '*' || c == '?':
				is_glob = true
			case c >= 0x80: // UTF-8 bytes in file names
			case:
				safe = false
			}
		}
		if !safe {
			continue
		}
		if n > 0 {
			strings.write_string(&sb, " || ")
		}
		if is_glob {
			strings.write_string(&sb, "(){ [[ -e $1 ]] } ")
			strings.write_string(&sb, item)
			strings.write_string(&sb, "(NY1)")
		} else {
			strings.write_string(&sb, "[[ -e ")
			strings.write_string(&sb, shell_single_quote(item, context.temp_allocator))
			strings.write_string(&sb, " ]]")
		}
		n += 1
	}
	return strings.to_string(sb)
}

// 4. ASYNC FEATURE
// Async worker runs in background subshell after each command.
// Fetches: git pending count + context version string.
// Writes results to a temp file and signals the parent to re-render.
generate_async_feature :: proc(b: ^strings.Builder, rprompt_format: string) {
	fmt.sbprintln(b, "# --- Feature: Async RPROMPT ---")
	fmt.sbprintln(b, "typeset -g _WAYU_ASYNC_FD=")
	fmt.sbprintln(b)

	// Version command lookup — maps context name to version command.
	// Runs in the background worker so it never blocks the prompt.
	fmt.sbprintln(b, "_wayu_version_cmd() {")
	fmt.sbprintln(b, `  case "$1" in`)
	fmt.sbprintln(
		b,
		`    rust)    command rustc --version 2>/dev/null | command awk '{print $2}' ;;`,
	)
	fmt.sbprintln(b, `    bun)     command bun --version 2>/dev/null ;;`)
	fmt.sbprintln(
		b,
		`    dart)    command dart --version 2>/dev/null | command awk '{print $4}' ;;`,
	)
	fmt.sbprintln(
		b,
		`    ruby)    command ruby --version 2>/dev/null | command awk '{print $2}' ;;`,
	)
	fmt.sbprintln(
		b,
		`    elixir)  command elixir --version 2>/dev/null | command awk 'NR==1{print $2}' ;;`,
	)
	fmt.sbprintln(b, `    odin)    command odin version 2>/dev/null | command awk '{print $3}' ;;`)
	fmt.sbprintln(
		b,
		`    golang)  command go version 2>/dev/null | command awk '{print $3}' | command sed 's/go//' ;;`,
	)
	fmt.sbprintln(
		b,
		`    deno)    command deno --version 2>/dev/null | command head -1 | command awk '{print $2}' ;;`,
	)
	fmt.sbprintln(b, `    nodejs)  command node --version 2>/dev/null | command sed 's/v//' ;;`)
	fmt.sbprintln(
		b,
		`    python)  command python3 --version 2>/dev/null | command awk '{print $2}' ;;`,
	)
	fmt.sbprintln(b, `    zig)     command zig version 2>/dev/null ;;`)
	fmt.sbprintln(b, `    *)       ;;`)
	fmt.sbprintln(b, "  esac")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)

	// The background worker
	fmt.sbprintln(b, "_wayu_async_worker() {")
	fmt.sbprintln(b, "  local git_pending=\"\"")
	fmt.sbprintln(b, "  if [[ -n \"$_WAYU_GIT_BRANCH\" ]]; then")
	fmt.sbprintln(
		b,
		`    git_pending="$(command git status --porcelain 2>/dev/null | command wc -l | command tr -d ' ')"`,
	)
	fmt.sbprintln(b, "    if [[ \"$git_pending\" -gt 0 ]]; then")
	// Apply rprompt_format: DSL conversion + escaping + token substitution
	{
		rpfmt := prompt_render_module(
			rprompt_format,
			{{"{git_pending}", "${git_pending}"}, {"{git_branch}", PROMPT_GIT_BRANCH}},
		)
		fmt.sbprint(b, "      git_pending=\"")
		fmt.sbprint(b, rpfmt)
		fmt.sbprint(b, "\"")
		fmt.sbprintln(b)
	}
	fmt.sbprintln(b, "    else")
	fmt.sbprintln(b, `      git_pending=""`)
	fmt.sbprintln(b, "    fi")
	fmt.sbprintln(b, "  fi")
	fmt.sbprintln(b)
	fmt.sbprintln(
		b,
		"  # Fetch version string for current context (async — never blocks prompt)",
	)
	fmt.sbprintln(b, `  local ver="$(_wayu_version_cmd "$_WAYU_CONTEXT")"`)
	fmt.sbprintln(b)
	// Results go through the shell's private 0700 dir (mktemp -d in
	// _wayu_start_async): written to a fresh mktemp file, then renamed over
	// `data` so the reader never sees a torn write and nothing in a shared
	// /tmp has a guessable name.
	fmt.sbprintln(b, "  # Write results atomically into the private dir and signal parent")
	fmt.sbprintln(b, `  local dir="$_WAYU_ASYNC_DIR" tmpf`)
	fmt.sbprintln(b, `  [[ -n "$dir" && -d "$dir" ]] || return 0`)
	fmt.sbprintln(b, `  tmpf="$(command mktemp "$dir/.w.XXXXXX" 2>/dev/null)" || return 0`)
	fmt.sbprintln(
		b,
		`  if builtin printf '%s\n%s' "$git_pending" "$ver" > "$tmpf" && command mv -f -- "$tmpf" "$dir/data" 2>/dev/null; then`,
	)
	fmt.sbprintln(b, "    builtin kill -USR1 $$ 2>/dev/null || true")
	fmt.sbprintln(b, "  else")
	fmt.sbprintln(b, `    command rm -f -- "$tmpf"`)
	fmt.sbprintln(b, "  fi")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)

	// USR1 handler (the async worker signals the shell). A TRAPUSR1 function
	// defined before wayu is kept as _wayu_prev_TRAPUSR1 and called first
	// (OKAMI-375); re-sourcing core doesn't chain wayu's handler to itself.
	fmt.sbprintln(b, "_wayu_async_on_usr1() {")
	fmt.sbprintln(b, `  local f="$_WAYU_ASYNC_DIR/data"`)
	fmt.sbprintln(b, "  if [[ -n \"$_WAYU_ASYNC_DIR\" && -f \"$f\" ]]; then")
	fmt.sbprintln(b, `    local lines=("${(@f)$(< "$f")}")`)
	fmt.sbprintln(b, `    _WAYU_ASYNC_DATA="${lines[1]-}"`)
	fmt.sbprintln(b, `    _WAYU_CONTEXT_VER="${lines[2]-}"`)
	fmt.sbprintln(b, `    command rm -f -- "$f"`)
	fmt.sbprintln(b, "  fi")
	fmt.sbprintln(b, "  _wayu_prompt_render; zle && zle reset-prompt")
	fmt.sbprintln(b, "  return 0")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(
		b,
		`if (( ${+functions[TRAPUSR1]} )) && [[ ${functions[TRAPUSR1]} != *_wayu_async_on_usr1* ]]; then`,
	)
	fmt.sbprintln(b, `  functions[_wayu_prev_TRAPUSR1]=${functions[TRAPUSR1]}`)
	fmt.sbprintln(b, "fi")
	fmt.sbprintln(b, "function TRAPUSR1 {")
	fmt.sbprintln(b, "  (( ${+functions[_wayu_prev_TRAPUSR1]} )) && _wayu_prev_TRAPUSR1 \"$@\"")
	fmt.sbprintln(b, "  _wayu_async_on_usr1")
	fmt.sbprintln(b, "  return 0")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)

	// The private dir is created lazily on the first prompt (one mktemp per
	// shell, nothing at startup) and removed when the shell exits.
	// Re-sourcing core keeps the existing dir (no orphaned dirs).
	fmt.sbprintln(b, `typeset -g _WAYU_ASYNC_DIR="${_WAYU_ASYNC_DIR-}"`)
	fmt.sbprintln(b, "_wayu_start_async() {")
	fmt.sbprintln(b, "  local ret=$?")
	// The private dir: zsh/files' builtin mkdir (no fork; `mktemp -d` cost
	// ~7 ms before the first prompt). -m 700 on a fresh random name that
	// must not exist yet, so nothing pre-created by someone else is used.
	// The worker is started with &! (one fork, no job message; the old
	// `( worker & )` waited on a second fork every prompt).
	fmt.sbprintln(b, `  if [[ -z "$_WAYU_ASYNC_DIR" || ! -d "$_WAYU_ASYNC_DIR" ]]; then`)
	fmt.sbprintln(b, `    _WAYU_ASYNC_DIR=""`)
	fmt.sbprintln(b, `    if zmodload -F zsh/files b:zf_mkdir 2>/dev/null; then`)
	fmt.sbprintln(b, `      local _d _i`)
	fmt.sbprintln(b, `      for _i in 1 2 3; do`)
	fmt.sbprintln(b, `        _d="${TMPDIR:-/tmp}"; _d="${_d%/}/wayu-async.$$.$RANDOM$RANDOM"`)
	fmt.sbprintln(
		b,
		`        if zf_mkdir -m 700 -- "$_d" 2>/dev/null; then _WAYU_ASYNC_DIR=$_d; break; fi`,
	)
	fmt.sbprintln(b, `      done`)
	fmt.sbprintln(b, `    else`)
	fmt.sbprintln(
		b,
		`      _WAYU_ASYNC_DIR="$(command mktemp -d "${TMPDIR:-/tmp}/wayu-async.XXXXXX" 2>/dev/null)" || _WAYU_ASYNC_DIR=""`,
	)
	fmt.sbprintln(b, `    fi`)
	fmt.sbprintln(b, "  fi")
	fmt.sbprintln(b, `  [[ -n "$_WAYU_ASYNC_DIR" ]] && _wayu_async_worker &!`)
	fmt.sbprintln(b, "  return $ret")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "_wayu_async_cleanup() {")
	fmt.sbprintln(
		b,
		`  [[ -n "$_WAYU_ASYNC_DIR" && -d "$_WAYU_ASYNC_DIR" ]] && command rm -rf -- "$_WAYU_ASYNC_DIR"`,
	)
	fmt.sbprintln(b, "  return 0")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)
	fmt.sbprintln(b, "add-zsh-hook precmd _wayu_start_async")
	fmt.sbprintln(b, "add-zsh-hook zshexit _wayu_async_cleanup")
	fmt.sbprintln(b)
}

// 5. TRANSIENT FEATURE
generate_transient_feature :: proc(b: ^strings.Builder, format: string) {
	fmt.sbprintln(b, "# --- Feature: Transient Prompt ---")
	fmt.sbprintln(b, "_wayu_prompt_transient() {")
	fmt.sbprintln(b, "  local result=\"\"")

	// Parsear format simple
	if strings.contains(format, "{dir}") {
		fmt.sbprintln(b, "  result+=\"%~ \"")
	}
	if strings.contains(format, "{character}") {
		// $? here would be the status of `local result` (always 0); use the
		// exit code captured by _wayu_prompt_master instead.
		fmt.sbprintln(b, "  if [[ ${_WAYU_LAST_EXIT:-0} -eq 0 ]]; then")
		fmt.sbprintln(b, `    result+="➜ "`)
		fmt.sbprintln(b, "  else")
		fmt.sbprintln(b, `    result+="✗ "`)
		fmt.sbprintln(b, "  fi")
	}

	fmt.sbprintln(b, `  REPLY=$result`)
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)
}

// 6. SEPARATOR LINE FEATURE (líneas continuas con espacios)
generate_separator_feature :: proc(b: ^strings.Builder) {
	// Separator lines disabled
}

// [prompt] vi_mode and [prompt.interactive] (see prompt_doc_parse).
parse_interactive_config :: proc(toml: string) -> InteractiveConfig {
	cfg := InteractiveConfig {
		toggle_key        = "^P",
		toggle_enabled    = false, // opt-in: ^P is history navigation
		vi_mode           = false, // opt-in via [prompt] vi_mode = true (OKAMI-285)
		vi_mode_indicator = true,
		vi_insert_symbol  = "[I]",
		vi_normal_symbol  = "[N]",
		vi_visual_symbol  = "[V]",
		context_aware     = true,
		async_rprompt     = true,
		rprompt_format    = "[ {git_pending}](242)",
		transient_enabled = true,
		transient_format  = "{dir} {character}",
	}

	arena: virtual.Arena
	doc, ok := prompt_doc_parse(toml, &arena)
	if !ok {
		return cfg
	}
	defer virtual.arena_destroy(&arena)

	bools := [?]struct {
		key:   string,
		field: ^bool,
	} {
		{"prompt.vi_mode", &cfg.vi_mode},
		{"prompt.interactive.toggle_enabled", &cfg.toggle_enabled},
		{"prompt.interactive.vi_mode_indicator", &cfg.vi_mode_indicator},
		{"prompt.interactive.context_aware", &cfg.context_aware},
		{"prompt.interactive.async_rprompt", &cfg.async_rprompt},
		{"prompt.interactive.transient_enabled", &cfg.transient_enabled},
	}
	for k in bools {
		if v, found := prompt_get_bool(&doc, k.key); found {
			k.field^ = v
		}
	}
	strs := [?]struct {
		key:   string,
		field: ^string,
	} {
		{"prompt.interactive.toggle_key", &cfg.toggle_key},
		{"prompt.interactive.rprompt_format", &cfg.rprompt_format},
	}
	for k in strs {
		if v, found := prompt_get_string(&doc, k.key); found && len(v) > 0 {
			k.field^ = v
		}
	}
	return cfg
}
