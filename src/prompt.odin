// prompt_generator.odin - Genera prompt nativo zsh pre-compilado
// Copied from starship.toml configuration - SIMPLIFIED VERSION
package wayu
import "core:fmt"
import "core:mem/virtual"
import "core:strconv"
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

// Replace mode (OKAMI-347): `R` (vi-replace) switches to the insert keymap
// in overwrite mode, so the keymap alone said INSERT; ZLE_STATE tells. `r`
// (vi-replace-chars) reads one character without a keymap change: wrapped to
// show REPLACE_ONE while it waits (zle -R draws it before the key read).
// Both use vimcmd_replace_symbol.
PROMPT_VI_INDICATOR_ZSH :: `_wayu_vi_mode_from_keymap() {
  local m
  case $KEYMAP in
    vicmd) m=NORMAL ;;
    visual|vivis) m=VISUAL ;;
    *) [[ ${ZLE_STATE-} == *overwrite* ]] && m=REPLACE || m=INSERT ;;
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
_wayu_vi_replace_chars() {
  _WAYU_VI_MODE="REPLACE_ONE"
  _wayu_prompt_render; zle reset-prompt; zle -R
  zle .vi-replace-chars -- "$@"
  _wayu_vi_mode_from_keymap
}
zle -N vi-replace-chars _wayu_vi_replace_chars
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
// A background worker, started from precmd, fetches the git pending count
// and the context's tool version, writes them into the shell's private dir
// and signals the parent (USR1), which re-renders. Per render the shell
// itself forks at most once (OKAMI-349): the worker start (`&!`), and only
// when there is something to fetch — in a git work tree, or in a context
// with a version command (PROMPT_VERSION_CMDS). Elsewhere the RPROMPT data
// is cleared without forking. The USR1 handler reads the result with `read`
// and removes it with zsh/files' zf_rm (it ran `$(<f)` + `command rm`); the
// worker uses zf_mv and a pid-named file instead of mktemp + mv.
//
// The pending count runs git in whatever repo the shell is in, including one
// unpacked from a tarball, whose .git/config can name commands: core.fsmonitor
// (run on every index read) is forced off on the command line, and a
// filter.<driver>.clean / .process (run on a stat-dirty file with that
// attribute) set by the repo's own config (scope local/worktree, includes
// included) skips the count; git-lfs and other filters from the global or
// system config are trusted. --no-optional-locks: no index write, and
// --ignore-submodules=dirty: no `git status` inside submodules, whose config
// isn't checked. The branch is read from HEAD without git either way.
PROMPT_GIT_FILTER_RE :: `^filter\..*\.(clean|process)$`
PROMPT_GIT_STATUS :: "git -c core.fsmonitor=false --no-optional-locks status --porcelain --ignore-submodules=dirty"

PROMPT_VERSION_CMDS :: [?][2]string {
	{"rust", `command rustc --version 2>/dev/null | command awk '{print $2}'`},
	{"bun", `command bun --version 2>/dev/null`},
	{"dart", `command dart --version 2>/dev/null | command awk '{print $4}'`},
	{"ruby", `command ruby --version 2>/dev/null | command awk '{print $2}'`},
	{"elixir", `command elixir --version 2>/dev/null | command awk 'NR==1{print $2}'`},
	{"odin", `command odin version 2>/dev/null | command awk '{print $3}'`},
	{"golang", `command go version 2>/dev/null | command awk '{print $3}' | command sed 's/go//'`},
	{"deno", `command deno --version 2>/dev/null | command head -1 | command awk '{print $2}'`},
	{"nodejs", `command node --version 2>/dev/null | command sed 's/v//'`},
	{"python", `command python3 --version 2>/dev/null | command awk '{print $2}'`},
	{"zig", `command zig version 2>/dev/null`},
}

generate_async_feature :: proc(b: ^strings.Builder, rprompt_format: string) {
	fmt.sbprintln(b, "# --- Feature: Async RPROMPT ---")
	fmt.sbprintln(b)

	// Version command lookup — maps context name to version command.
	// Runs in the background worker so it never blocks the prompt.
	versions := PROMPT_VERSION_CMDS
	names := make([dynamic]string, context.temp_allocator)
	fmt.sbprintln(b, "_wayu_version_cmd() {")
	fmt.sbprintln(b, `  case "$1" in`)
	for v in versions {
		fmt.sbprintfln(b, "    %s) %s ;;", v[0], v[1])
		append(&names, v[0])
	}
	fmt.sbprintln(b, `    *) ;;`)
	fmt.sbprintln(b, "  esac")
	fmt.sbprintln(b, "}")
	fmt.sbprintfln(
		b,
		"_WAYU_VERSIONED='(%s)'",
		strings.join(names[:], "|", context.temp_allocator),
	)
	fmt.sbprintln(b)

	// The background worker. The rprompt format is DSL-converted, escaped
	// and its tokens substituted (prompt_render_module).
	rpfmt := prompt_render_module(
		rprompt_format,
		{{"{git_pending}", "${git_pending}"}, {"{git_branch}", PROMPT_GIT_BRANCH}},
	)
	fmt.sbprintln(b, "_wayu_async_worker() {")
	fmt.sbprintln(b, `  local git_pending="" ver="" dir="$_WAYU_ASYNC_DIR" tmpf`)
	fmt.sbprintln(b, "  local -a st fl")
	fmt.sbprintln(b, "  local -i rc")
	fmt.sbprintln(b, `  if [[ -n "$_WAYU_GIT_BRANCH" ]]; then`)
	// See PROMPT_GIT_STATUS: no count when the repo defines a filter driver.
	fmt.sbprintln(
		b,
		`    fl=( ${(f)"$(command git config --show-scope --get-regexp '` +
		PROMPT_GIT_FILTER_RE +
		`' 2>/dev/null)"} )`,
	)
	fmt.sbprintln(b, "    rc=$?")
	fmt.sbprintln(b, `    fl=( ${fl:#(global|system|command)$'\t'*} )`)
	fmt.sbprintln(b, "    if (( rc == 1 || (rc == 0 && ${#fl} == 0) )); then")
	fmt.sbprintln(b, `      st=( ${(f)"$(command ` + PROMPT_GIT_STATUS + ` 2>/dev/null)"} )`)
	fmt.sbprintln(b, "    fi")
	fmt.sbprintln(b, "    if (( ${#st} > 0 )); then")
	fmt.sbprintln(b, "      git_pending=${#st}")
	fmt.sbprintfln(b, `      git_pending="%s"`, rpfmt)
	fmt.sbprintln(b, "    fi")
	fmt.sbprintln(b, "  fi")
	fmt.sbprintln(
		b,
		`  [[ $_WAYU_CONTEXT == ${~_WAYU_VERSIONED} ]] && ver="$(_wayu_version_cmd "$_WAYU_CONTEXT")"`,
	)
	// Results go through the shell's private 0700 dir (_wayu_start_async):
	// written to a file named after the worker's pid, then renamed over
	// `data` so the reader never sees a torn write.
	fmt.sbprintln(b, `  [[ -n "$dir" && -d "$dir" ]] || return 0`)
	fmt.sbprintln(b, `  if zmodload zsh/system 2>/dev/null && (( ${+builtins[zf_mv]} )); then`)
	fmt.sbprintln(b, `    tmpf="$dir/.w.$sysparams[pid]"`)
	fmt.sbprintln(
		b,
		`    builtin printf '%s\n%s' "$git_pending" "$ver" >| "$tmpf" && zf_mv -f -- "$tmpf" "$dir/data" || { zf_rm -f -- "$tmpf"; return 0; }`,
	)
	fmt.sbprintln(b, "  else")
	fmt.sbprintln(b, `    tmpf="$(command mktemp "$dir/.w.XXXXXX" 2>/dev/null)" || return 0`)
	fmt.sbprintln(
		b,
		`    builtin printf '%s\n%s' "$git_pending" "$ver" > "$tmpf" && command mv -f -- "$tmpf" "$dir/data" 2>/dev/null || { command rm -f -- "$tmpf"; return 0; }`,
	)
	fmt.sbprintln(b, "  fi")
	fmt.sbprintln(b, "  builtin kill -USR1 $$ 2>/dev/null")
	fmt.sbprintln(b, "  return 0")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)

	// USR1 handler (the async worker signals the shell). A TRAPUSR1 function
	// defined before wayu is kept as _wayu_prev_TRAPUSR1 and called first
	// (OKAMI-375); re-sourcing core doesn't chain wayu's handler to itself.
	fmt.sbprint(b, PROMPT_ASYNC_HANDLER_ZSH)
	fmt.sbprintln(b)
}

// The USR1 handler, the TRAPUSR1 chain and the per-prompt worker start. The
// private dir is created lazily on the first prompt that needs the worker
// (zsh/files' builtin mkdir, -m 700 on a fresh random name that must not
// exist yet; `mktemp -d` without zsh/files) and removed when the shell
// exits. Re-sourcing core keeps the existing dir.
PROMPT_ASYNC_HANDLER_ZSH :: `_wayu_async_on_usr1() {
  local f="$_WAYU_ASYNC_DIR/data" a="" v=""
  if [[ -n "$_WAYU_ASYNC_DIR" && -f "$f" ]]; then
    { IFS= read -r a; IFS= read -r v } < "$f" 2>/dev/null
    _WAYU_ASYNC_DATA=$a _WAYU_CONTEXT_VER=$v
    if (( ${+builtins[zf_rm]} )); then zf_rm -f -- "$f"; else command rm -f -- "$f"; fi
  fi
  _wayu_prompt_render; zle && zle reset-prompt
  return 0
}
if (( ${+functions[TRAPUSR1]} )) && [[ ${functions[TRAPUSR1]} != *_wayu_async_on_usr1* ]]; then
  functions[_wayu_prev_TRAPUSR1]=${functions[TRAPUSR1]}
fi
function TRAPUSR1 {
  (( ${+functions[_wayu_prev_TRAPUSR1]} )) && _wayu_prev_TRAPUSR1 "$@"
  _wayu_async_on_usr1
  return 0
}

typeset -g _WAYU_ASYNC_DIR="${_WAYU_ASYNC_DIR-}"
_wayu_start_async() {
  local ret=$?
  if [[ -z "$_WAYU_GIT_BRANCH" && $_WAYU_CONTEXT != ${~_WAYU_VERSIONED} ]]; then
    _WAYU_ASYNC_DATA="" _WAYU_CONTEXT_VER=""
    return $ret
  fi
  if [[ -z "$_WAYU_ASYNC_DIR" || ! -d "$_WAYU_ASYNC_DIR" ]]; then
    _WAYU_ASYNC_DIR=""
    if zmodload -F zsh/files b:zf_mkdir b:zf_mv b:zf_rm 2>/dev/null; then
      local _d _i
      for _i in 1 2 3; do
        _d="${TMPDIR:-/tmp}"; _d="${_d%/}/wayu-async.$$.$RANDOM$RANDOM"
        if zf_mkdir -m 700 -- "$_d" 2>/dev/null; then _WAYU_ASYNC_DIR=$_d; break; fi
      done
    else
      _WAYU_ASYNC_DIR="$(command mktemp -d "${TMPDIR:-/tmp}/wayu-async.XXXXXX" 2>/dev/null)" || _WAYU_ASYNC_DIR=""
    fi
  fi
  [[ -n "$_WAYU_ASYNC_DIR" ]] && _wayu_async_worker &!
  return $ret
}
_wayu_async_cleanup() {
  [[ -n "$_WAYU_ASYNC_DIR" && -d "$_WAYU_ASYNC_DIR" ]] && command rm -rf -- "$_WAYU_ASYNC_DIR"
  return 0
}
add-zsh-hook precmd _wayu_start_async
add-zsh-hook zshexit _wayu_async_cleanup
`

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

// ============================================================================
// fish native prompt (OKAMI-368)
// ============================================================================
//
// `[prompt] enabled = true` in a fish setup: core.fish defines fish_prompt
// (and fish_right_prompt with async_rprompt) from the same [prompt] /
// [prompt.*] tables as zsh: format tokens, module formats ([text](style),
// $user / $hostname / $localip / $dir / $basename / $pwd / $branch /
// $version), character symbols and colors, [prompt.contexts], vi mode
// (fish_vi_key_bindings; the character follows $fish_bind_mode), the
// minimal-mode toggle and the async right prompt. Styles are precomputed
// ANSI sequences (printf format), every value is printed as a `%s`
// argument, and a render runs only builtins (no fork) except {localip}.

// ANSI SGR printf format (`\e[1;36m`) for a wayu style string ("" when the
// style has no known word). Same words and colors as style_to_zsh.
// Temp-allocated.
style_to_ansi :: proc(style: string) -> string {
	codes := make([dynamic]string, context.temp_allocator)
	for token in strings.split(style, " ", context.temp_allocator) {
		t := strings.trim_space(token)
		switch t {
		case "":
		case "bold":
			append(&codes, "1")
		case "dim":
			append(&codes, "2")
		case "italic":
			append(&codes, "3")
		case "underline":
			append(&codes, "4")
		case:
			num := color_name_to_num(t)
			if num < 0 && all_digits(t) {
				num, _ = strconv.parse_int(t)
			}
			if num >= 0 && num < 8 {
				append(&codes, fmt.tprintf("%d", 30 + num))
			} else if num >= 8 && num < 256 {
				append(&codes, fmt.tprintf("38;5;%d", num))
			}
		}
	}
	if len(codes) == 0 {
		return ""
	}
	return fmt.tprintf("\\e[%sm", strings.join(codes[:], ";", context.temp_allocator))
}

// One piece of a module format: text, styled when it came from
// `[text](style)` (same parsing as dsl_to_zsh_format).
PromptSegment :: struct {
	text:   string,
	style:  string,
	styled: bool,
}

// Split a DSL format into segments (slices of `format`; temp array).
prompt_dsl_segments :: proc(format: string) -> [dynamic]PromptSegment {
	segs := make([dynamic]PromptSegment, context.temp_allocator)
	i := 0
	for i < len(format) {
		lb := strings.index(format[i:], "[")
		if lb == -1 {
			append(&segs, PromptSegment{text = format[i:]})
			break
		}
		lb += i
		if lb > i {
			append(&segs, PromptSegment{text = format[i:lb]})
		}
		rb := strings.index(format[lb:], "]")
		if rb == -1 {
			append(&segs, PromptSegment{text = format[lb:]})
			break
		}
		rb += lb
		if rb + 1 >= len(format) || format[rb + 1] != '(' {
			append(&segs, PromptSegment{text = format[lb:rb + 1]})
			i = rb + 1
			continue
		}
		rp := strings.index(format[rb + 1:], ")")
		if rp == -1 {
			append(&segs, PromptSegment{text = format[lb:]})
			break
		}
		rp += rb + 1
		append(
			&segs,
			PromptSegment {
				text = strings.trim_space(format[lb + 1:rb]),
				style = strings.trim_space(format[rb + 2:rp]),
				styled = true,
			},
		)
		i = rp + 1
	}
	return segs
}

@(private = "file")
fish_prompt_flush_literal :: proc(b: ^strings.Builder, indent: string, lit: ^strings.Builder) {
	if strings.builder_len(lit^) == 0 {
		return
	}
	fmt.sbprintfln(
		b,
		"%sprintf '%%s' %s",
		indent,
		escape_fish_string(strings.to_string(lit^), context.temp_allocator),
	)
	strings.builder_reset(lit)
}

// `printf '%s' ...` lines printing `text`, with each occurrence of a
// vars key ({key, fish expression}, longest key wins) printed as its
// expression and everything else as a literal word.
fish_prompt_emit_text :: proc(b: ^strings.Builder, indent, text: string, vars: [][2]string) {
	lit := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(text) {
		best := -1
		for v, k in vars {
			if strings.has_prefix(text[i:], v[0]) && (best < 0 || len(v[0]) > len(vars[best][0])) {
				best = k
			}
		}
		if best >= 0 {
			fish_prompt_flush_literal(b, indent, &lit)
			fmt.sbprintfln(b, "%sprintf '%%s' %s", indent, vars[best][1])
			i += len(vars[best][0])
			continue
		}
		strings.write_byte(&lit, text[i])
		i += 1
	}
	fish_prompt_flush_literal(b, indent, &lit)
}

// A module format (DSL + vars) as fish code: styled segments are wrapped
// in their ANSI sequence and a reset.
fish_prompt_emit_module :: proc(b: ^strings.Builder, indent, format: string, vars: [][2]string) {
	for s in prompt_dsl_segments(format) {
		ansi := style_to_ansi(s.style) if s.styled else ""
		if len(ansi) > 0 {
			fmt.sbprintfln(b, "%sprintf '%s'", indent, ansi)
		}
		fish_prompt_emit_text(b, indent, s.text, vars)
		if len(ansi) > 0 {
			fmt.sbprintfln(b, "%sprintf '\\e[0m'", indent)
		}
	}
}

// Fish code for one {token} of [prompt] format (inside fish_prompt).
fish_prompt_emit_token :: proc(
	b: ^strings.Builder,
	cfg: PromptConfigFull,
	icfg: InteractiveConfig,
	name: string,
) {
	q :: proc(s: string) -> string {return escape_fish_string(s, context.temp_allocator)}
	switch name {
	case "username":
		indent := "    "
		if !cfg.username_show_always {
			fmt.sbprintln(
				b,
				"    if set -q SSH_CONNECTION; or set -q SSH_CLIENT; or set -q SSH_TTY; or begin; functions -q fish_is_root_user; and fish_is_root_user; end",
			)
			indent = "        "
		}
		fish_prompt_emit_module(b, indent, cfg.username_format, {{"$user", `"$USER"`}})
		if !cfg.username_show_always {
			fmt.sbprintln(b, "    end")
		}
	case "hostname":
		fish_prompt_emit_module(
			b,
			"    ",
			cfg.hostname_format,
			{{"$hostname", `(string replace -r '\..*' '' -- $hostname)`}},
		)
	case "localip":
		fish_prompt_emit_module(b, "    ", cfg.localip_format, {{"$localip", `"$_wayu_localip"`}})
	case "dir":
		fish_prompt_emit_module(
			b,
			"    ",
			cfg.dir_format,
			{
				{"$basename", "(_wayu_prompt_dir 1)"},
				{"$pwd", `"$PWD"`},
				{"$dir", "(_wayu_prompt_dir)"},
			},
		)
	case "git_branch":
		fmt.sbprintln(b, `    if test -n "$_wayu_git_branch"`)
		fish_prompt_emit_module(
			b,
			"        ",
			cfg.git_branch_format,
			{{"$branch", `"$_wayu_git_branch"`}},
		)
		fmt.sbprintln(b, "    end")
	case "language_context", "context_icon":
		fmt.sbprintln(b, `    switch "$_wayu_context"`)
		for lang in cfg.context_order {
			f, has := cfg.context_formats[lang]
			if !has {
				continue
			}
			fmt.sbprintfln(b, "        case %s", q(sanitize_ident(lang)))
			fish_prompt_emit_module(b, "            ", f, {{"$version", `"$_wayu_context_ver"`}})
		}
		fmt.sbprintln(b, "        case '*'")
		fmt.sbprintln(b, `            printf '%s' (string replace -r '.*/' '' -- "$SHELL")`)
		fmt.sbprintln(b, "    end")
	case "character":
		fmt.sbprintfln(b, "    set -l _wayu_sym %s", q(cfg.character_success))
		fmt.sbprintln(b, "    set -l _wayu_col 2")
		fmt.sbprintln(b, "    if test $_wayu_st -ne 0")
		fmt.sbprintfln(b, "        set _wayu_sym %s", q(cfg.character_error))
		fmt.sbprintln(b, "        set _wayu_col 1")
		fmt.sbprintln(b, "    end")
		if icfg.vi_mode && icfg.vi_mode_indicator {
			fmt.sbprintln(b, "    switch $fish_bind_mode")
			fmt.sbprintln(b, "        case insert")
			fmt.sbprintfln(
				b,
				"            set _wayu_sym %s; set _wayu_col 202",
				q(cfg.character_success),
			)
			fmt.sbprintln(b, "        case default")
			fmt.sbprintfln(
				b,
				"            set _wayu_sym %s; set _wayu_col 2",
				q(cfg.vimcmd_symbol),
			)
			fmt.sbprintln(b, "        case visual")
			fmt.sbprintfln(
				b,
				"            set _wayu_sym %s; set _wayu_col 129",
				q(cfg.vimcmd_visual_symbol),
			)
			fmt.sbprintln(b, "        case replace replace_one")
			fmt.sbprintfln(
				b,
				"            set _wayu_sym %s; set _wayu_col 129",
				q(cfg.vimcmd_replace_symbol),
			)
			fmt.sbprintln(b, "    end")
		}
		fmt.sbprintln(b, `    printf '\e[38;5;%sm\e[1m%s\e[0m' $_wayu_col $_wayu_sym`)
	}
}

// Prompt helpers: the directory module and the git branch, read like the
// zsh prompt (PROMPT_GIT_INFO_ZSH) with builtins only.
PROMPT_FISH_HELPERS :: `set -g _wayu_git_branch ''
set -g _wayu_context default
set -g _wayu_context_ver ''
function _wayu_prompt_dir
    set -l p $PWD
    if test "$p" = "$HOME"
        set p '~'
    else if test -n "$HOME"; and string match -q -- "$HOME/*" "$p"
        set p '~'(string sub -s (math (string length -- "$HOME") + 1) -- $p)
    end
    if set -q argv[1]; and test "$p" != /; and test "$p" != '~'
        set p (string replace -r '.*/' '' -- $p)
    end
    printf '%s' $p
end
function _wayu_update_git_info
    set -g _wayu_git_branch ''
    set -l d $PWD
    set -l g ''
    set -l l ''
    if test -n "$GIT_DIR"
        set g (path resolve -- $GIT_DIR)
    else
        while true
            if test -d "$d/.git"
                set g $d/.git
                break
            else if test -f "$d/.git"
                test -r "$d/.git"; and read l <"$d/.git"
                if string match -q -- 'gitdir: *' "$l"
                    set g (string replace -- 'gitdir: ' '' "$l")
                    string match -q -- '/*' $g; or set g $d/$g
                end
                break
            end
            test "$d" = /; and break
            test -z "$d"; and break
            set d (path dirname -- $d)
        end
    end
    test -n "$g"; and test -r "$g/HEAD"; or return 0
    set l ''
    read l <"$g/HEAD"
    switch "$l"
        case 'ref: refs/heads/.invalid'
            set -g _wayu_git_branch (command git symbolic-ref --short HEAD 2>/dev/null)
        case 'ref: refs/heads/*'
            set -g _wayu_git_branch (string replace -- 'ref: refs/heads/' '' "$l")
        case 'ref: *'
            set -g _wayu_git_branch (string replace -- 'ref: ' '' "$l")
        case '*'
            set -g _wayu_git_branch (string sub -l 7 -- "$l")
    end
    return 0
end
`

PromptFishContext :: struct {
	name:   string,
	detect: []string,
}

// Built-in context detection for fish: (name, files or `*` globs). Same
// rules as the zsh BUILTIN table in generate_context_feature.
PROMPT_FISH_BUILTIN_CONTEXTS := [?]PromptFishContext {
	{"rust", {"Cargo.toml"}},
	{"bun", {"bun.lockb", "bunfig.toml"}},
	{"gleam", {"gleam.toml"}},
	{"swift", {"Package.swift"}},
	{"dart", {"pubspec.yaml"}},
	{"php", {"composer.json"}},
	{"ruby", {"Gemfile", ".ruby-version"}},
	{"elixir", {"mix.exs"}},
	{"erlang", {"rebar.config", "erlang.mk"}},
	{"haskell", {"stack.yaml", "cabal.project"}},
	{"julia", {"Project.toml", "Manifest.toml"}},
	{"odin", {"ols.json", "*.odin", "src/*.odin"}},
	{"golang", {"go.mod"}},
	{"nim", {"nim.cfg"}},
	{"ocaml", {"dune"}},
	{"nix", {"flake.nix", "default.nix"}},
	{"deno", {"deno.json", "deno.jsonc"}},
	{"elm", {"elm.json"}},
	{"crystal", {"shard.yml"}},
	{"perl", {"cpanfile"}},
	{"buf", {"buf.yaml"}},
	{"nodejs", {"package.json"}},
	{"java", {"pom.xml", "build.gradle"}},
	{"scala", {"build.sbt"}},
	{"python", {"requirements.txt", "pyproject.toml"}},
	{"zig", {"build.zig", "build.zig.zon"}},
	{"rlang", {"DESCRIPTION"}},
	{"lua", {".lua-version"}},
	{"docker", {"Dockerfile", "docker-compose.yml"}},
	{"aws", {".aws"}},
}

// fish condition for a detect list: `test -e 'f'` per file, `count g >/dev/null`
// per `*` glob (a glob with no match is no error for count). Entries outside
// context_detect_condition's safe character set are skipped. Temp-allocated
// ("" when nothing is usable).
fish_detect_condition :: proc(detects: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	n := 0
	for raw in detects {
		item := strings.trim_space(raw)
		if len(item) == 0 || len(context_detect_condition({item})) == 0 {
			continue
		}
		if n > 0 {
			strings.write_string(&sb, "; or ")
		}
		if strings.contains(item, "*") {
			fmt.sbprintf(&sb, "count %s >/dev/null", item)
		} else {
			fmt.sbprintf(&sb, "test -e %s", escape_fish_string(item, context.temp_allocator))
		}
		n += 1
	}
	return strings.to_string(sb)
}

// The async worker, run as `fish --no-config -c <script> -- <dir> <branch>
// <context> <parent pid>` in the prompt's directory: pending count and tool
// version into <dir>/data (atomic rename), then USR1 to the shell.
// Temp-allocated.
fish_async_worker_script :: proc() -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&sb, "set -l n ''")
	fmt.sbprintln(&sb, `if test -n "$argv[2]"`)
	// See PROMPT_GIT_STATUS: no count when the repo defines a filter driver.
	fmt.sbprintfln(
		&sb,
		"    set -l fl (command git config --show-scope --get-regexp '%s' 2>/dev/null)",
		PROMPT_GIT_FILTER_RE,
	)
	fmt.sbprintln(&sb, "    set -l rc $status")
	fmt.sbprintln(&sb, `    set fl (string match -rv '^(global|system|command)\t' -- $fl)`)
	fmt.sbprintln(
		&sb,
		"    if test $rc -eq 1; or begin; test $rc -eq 0; and not set -q fl[1]; end",
	)
	fmt.sbprintfln(&sb, "        set -l st (command %s 2>/dev/null)", PROMPT_GIT_STATUS)
	fmt.sbprintln(&sb, "        set -q st[1]; and set n (count $st)")
	fmt.sbprintln(&sb, "    end")
	fmt.sbprintln(&sb, "end")
	fmt.sbprintln(&sb, "set -l ver ''")
	fmt.sbprintln(&sb, "switch $argv[3]")
	versions := PROMPT_VERSION_CMDS
	for v in versions {
		fmt.sbprintfln(&sb, "    case %s", v[0])
		fmt.sbprintfln(&sb, "        set ver (%s)", v[1])
	}
	fmt.sbprintln(&sb, "end")
	fmt.sbprintln(&sb, "set -l tmp $argv[1]/.w.$fish_pid")
	fmt.sbprintln(
		&sb,
		`printf '%s\n%s\n' "$n" "$ver" >$tmp; and command mv -f -- $tmp $argv[1]/data; and kill -USR1 $argv[4]`,
	)
	return strings.to_string(sb)
}

// The [prompt] format as fish_prompt body lines: literal text, {token} and
// [{token}](style), `\n` = a new line (same walk as generate_full_prompt).
@(private = "file")
fish_prompt_emit_format :: proc(
	b: ^strings.Builder,
	cfg: PromptConfigFull,
	icfg: InteractiveConfig,
) {
	format, _ := strings.replace_all(cfg.format, `\n`, "\n", context.temp_allocator)
	for part, i in strings.split(format, "\n", context.temp_allocator) {
		if i > 0 {
			fmt.sbprintln(b, "    echo")
		}
		pos := 0
		for pos < len(part) {
			ob := strings.index(part[pos:], "[{")
			oc := strings.index(part[pos:], "{")
			if ob != -1 && (oc == -1 || ob <= oc) {
				ob += pos
				fish_prompt_emit_text(b, "    ", part[pos:ob], {})
				cb := strings.index(part[ob:], "}]")
				if cb != -1 {
					cb += ob
					if cb + 2 < len(part) && part[cb + 2] == '(' {
						cp := strings.index(part[cb + 2:], ")")
						if cp != -1 {
							cp += cb + 2
							ansi := style_to_ansi(strings.trim_space(part[cb + 3:cp]))
							if len(ansi) > 0 {
								fmt.sbprintfln(b, "    printf '%s'", ansi)
							}
							fish_prompt_emit_token(b, cfg, icfg, part[ob + 2:cb])
							if len(ansi) > 0 {
								fmt.sbprintln(b, `    printf '\e[0m'`)
							}
							pos = cp + 1
							continue
						}
					}
				}
				fish_prompt_emit_text(b, "    ", "[", {})
				pos = ob + 1
				continue
			}
			if oc == -1 {
				fish_prompt_emit_text(b, "    ", part[pos:], {})
				break
			}
			oc += pos
			fish_prompt_emit_text(b, "    ", part[pos:oc], {})
			cc := strings.index(part[oc:], "}")
			if cc == -1 {
				fish_prompt_emit_text(b, "    ", part[oc:], {})
				break
			}
			cc += oc
			fish_prompt_emit_token(b, cfg, icfg, part[oc + 1:cc])
			pos = cc + 1
		}
	}
}

// Toggle (opt-in): bound from fish_user_key_bindings (run after the key
// bindings are set up), chaining one defined before wayu. Only `^X` keys
// have a fish form.
@(private = "file")
fish_prompt_emit_toggle :: proc(b: ^strings.Builder, icfg: InteractiveConfig) {
	key := icfg.toggle_key
	fmt.sbprintln(b, "# --- Feature: Toggle Prompt (Minimal/Full) ---")
	fmt.sbprintln(b, "set -g _wayu_prompt_mode full")
	fmt.sbprintln(b, "function _wayu_toggle_prompt")
	fmt.sbprintln(
		b,
		`    test "$_wayu_prompt_mode" = full; and set -g _wayu_prompt_mode minimal; or set -g _wayu_prompt_mode full`,
	)
	fmt.sbprintln(b, "    commandline -f repaint")
	fmt.sbprintln(b, "end")
	letter :=
		len(key) == 2 &&
		key[0] == '^' &&
		((key[1] >= 'A' && key[1] <= 'Z') || (key[1] >= 'a' && key[1] <= 'z'))
	if !letter {
		fmt.sbprintln(b, "# wayu: toggle_key has no fish form (use ^X); not bound")
		return
	}
	fkey := fmt.tprintf("\\c%c", rune(key[1] | 0x20))
	fmt.sbprintln(
		b,
		"if functions -q fish_user_key_bindings; and not functions -q _wayu_prev_fish_user_key_bindings; and not string match -q -- '*_wayu_toggle_prompt*' (functions fish_user_key_bindings)",
	)
	fmt.sbprintln(b, "    functions -c fish_user_key_bindings _wayu_prev_fish_user_key_bindings")
	fmt.sbprintln(b, "end")
	fmt.sbprintln(b, "function fish_user_key_bindings")
	fmt.sbprintln(
		b,
		"    functions -q _wayu_prev_fish_user_key_bindings; and _wayu_prev_fish_user_key_bindings",
	)
	if icfg.vi_mode {
		fmt.sbprintfln(b, "    bind -M insert %s _wayu_toggle_prompt", fkey)
		fmt.sbprintfln(b, "    bind -M default %s _wayu_toggle_prompt", fkey)
	} else {
		fmt.sbprintfln(b, "    bind %s _wayu_toggle_prompt", fkey)
	}
	fmt.sbprintln(b, "end")
}

// Context detection on directory change (file tests only).
@(private = "file")
fish_prompt_emit_context :: proc(b: ^strings.Builder, icfg: InteractiveConfig) {
	fmt.sbprintln(b, "# --- Feature: Context-Aware Prompt ---")
	fmt.sbprintln(b, "function _wayu_detect_context --on-variable PWD")
	fmt.sbprintln(b, "    set -g _wayu_context default")
	configured := make(map[string]bool, 16, context.temp_allocator)
	first := true
	if icfg.contexts != nil {
		for name in icfg.contexts.context_order {
			detects, has := icfg.contexts.context_detects[name]
			if !has || len(detects) == 0 {
				continue
			}
			cond := fish_detect_condition(detects[:])
			if len(cond) == 0 {
				continue
			}
			configured[name] = true
			fmt.sbprintfln(b, "    %s %s", "if" if first else "else if", cond)
			fmt.sbprintfln(b, "        set -g _wayu_context %s", sanitize_ident(name))
			first = false
		}
	}
	for entry in PROMPT_FISH_BUILTIN_CONTEXTS {
		if configured[entry.name] {
			continue
		}
		fmt.sbprintfln(
			b,
			"    %s %s",
			"if" if first else "else if",
			fish_detect_condition(entry.detect),
		)
		fmt.sbprintfln(b, "        set -g _wayu_context %s", entry.name)
		first = false
	}
	if !first {
		fmt.sbprintln(b, "    end")
	}
	fmt.sbprintln(b, "end")
	fmt.sbprintln(b, "_wayu_detect_context")
}

// Async right prompt: a worker per prompt, only where there is something to
// fetch (a git work tree, a context with a version command), like zsh.
@(private = "file")
fish_prompt_emit_async :: proc(b: ^strings.Builder, icfg: InteractiveConfig) {
	names := make([dynamic]string, context.temp_allocator)
	versions := PROMPT_VERSION_CMDS
	for v in versions {append(&names, v[0])}
	fmt.sbprintln(b, "# --- Feature: Async RPROMPT ---")
	fmt.sbprintln(b, "set -g _wayu_async_data ''")
	fmt.sbprintln(b, "set -q _wayu_async_dir; or set -g _wayu_async_dir ''")
	fmt.sbprintfln(
		b,
		"set -g _wayu_async_script %s",
		escape_fish_string(fish_async_worker_script(), context.temp_allocator),
	)
	fmt.sbprintln(b, "function _wayu_async_start")
	fmt.sbprintfln(
		b,
		`    if test -z "$_wayu_git_branch"; and not contains -- "$_wayu_context" %s`,
		strings.join(names[:], " ", context.temp_allocator),
	)
	fmt.sbprint(b, PROMPT_FISH_ASYNC)
	fmt.sbprintln(b, "function fish_right_prompt")
	fmt.sbprintln(b, `    test -n "$_wayu_async_data"; or return 0`)
	fish_prompt_emit_module(
		b,
		"    ",
		icfg.rprompt_format,
		{{"{git_pending}", `"$_wayu_async_data"`}, {"{git_branch}", `"$_wayu_git_branch"`}},
	)
	fmt.sbprintln(b, "end")
}

// Rest of _wayu_async_start, the USR1 handler and the exit cleanup. The
// private dir (mktemp -d, once per shell) holds the worker's result.
PROMPT_FISH_ASYNC :: `        set -g _wayu_async_data ''
        set -g _wayu_context_ver ''
        return 0
    end
    if test -z "$_wayu_async_dir"; or not test -d "$_wayu_async_dir"
        set -l t /tmp
        test -n "$TMPDIR"; and set t (string trim -r -c / -- "$TMPDIR")
        set -g _wayu_async_dir (command mktemp -d $t/wayu-async.XXXXXX 2>/dev/null); or set -g _wayu_async_dir ''
        test -n "$_wayu_async_dir"; or return 0
    end
    set -l fb (status fish-path)
    command $fb --no-config -c $_wayu_async_script -- $_wayu_async_dir "$_wayu_git_branch" "$_wayu_context" $fish_pid &
    disown $last_pid 2>/dev/null
    return 0
end
function _wayu_async_on_usr1 --on-signal SIGUSR1
    test -n "$_wayu_async_dir"; and test -f "$_wayu_async_dir/data"; or return 0
    set -l a ''
    set -l v ''
    read -L a v <"$_wayu_async_dir/data"
    set -g _wayu_async_data $a
    set -g _wayu_context_ver $v
    commandline -f repaint 2>/dev/null
end
function _wayu_async_cleanup --on-event fish_exit
    test -n "$_wayu_async_dir"; and test -d "$_wayu_async_dir"; and command rm -rf -- "$_wayu_async_dir"
end
`

// core.fish's prompt section (the caller wraps it in `if status
// is-interactive`). Caller owns the result.
generate_fish_prompt :: proc(cfg: PromptConfigFull, icfg: InteractiveConfig) -> string {
	b := strings.builder_make()
	fmt.sbprintln(&b, "# --- Wayu Native Prompt (fish) ---")
	fmt.sbprint(&b, PROMPT_FISH_HELPERS)
	has_localip := strings.contains(cfg.format, "{localip}")
	if has_localip {
		fmt.sbprintln(&b, "set -g _wayu_localip ''")
	}
	// Vi mode: fish's own vi bindings; the character shows the mode, so the
	// default mode prompt ([I]) is emptied (fish then repaints the whole
	// prompt on a mode change).
	if icfg.vi_mode {
		fmt.sbprintln(&b, "# --- Feature: VI Mode ---")
		fmt.sbprintln(&b, "set -g fish_key_bindings fish_vi_key_bindings")
		fmt.sbprintln(&b, "function fish_mode_prompt; end")
	}
	if icfg.toggle_enabled {
		fish_prompt_emit_toggle(&b, icfg)
	}
	if icfg.context_aware {
		fish_prompt_emit_context(&b, icfg)
	}
	if icfg.async_rprompt {
		fish_prompt_emit_async(&b, icfg)
	}

	// Per-prompt state, set before fish_prompt runs (the fish_prompt event).
	fmt.sbprintln(&b, "# --- Prompt ---")
	fmt.sbprintln(&b, "function _wayu_prompt_pre --on-event fish_prompt")
	fmt.sbprintln(&b, "    _wayu_update_git_info")
	if has_localip {
		fmt.sbprintln(
			&b,
			`    set -g _wayu_localip (command ipconfig getifaddr en0 2>/dev/null; or command ip -4 route get 1 2>/dev/null | command awk '{print $7; exit}')`,
		)
	}
	if icfg.async_rprompt {
		fmt.sbprintln(&b, "    _wayu_async_start")
	}
	fmt.sbprintln(&b, "end")

	// fish_prompt: a blank line, then the format (like zsh's PROMPT).
	fmt.sbprintln(&b, "function fish_prompt")
	fmt.sbprintln(&b, "    set -l _wayu_st $status")
	fmt.sbprintln(&b, "    echo")
	if icfg.toggle_enabled {
		fmt.sbprintln(&b, `    if test "$_wayu_prompt_mode" = minimal`)
		if icfg.transient_enabled {
			if strings.contains(icfg.transient_format, "{dir}") {
				fmt.sbprintln(&b, `        printf '%s ' (_wayu_prompt_dir)`)
			}
			if strings.contains(icfg.transient_format, "{character}") {
				fmt.sbprintln(
					&b,
					`        test $_wayu_st -eq 0; and printf '➜ '; or printf '✗ '`,
				)
			}
		} else {
			fmt.sbprintln(&b, `        printf '%s ➜ ' (_wayu_prompt_dir)`)
		}
		fmt.sbprintln(&b, "        return 0")
		fmt.sbprintln(&b, "    end")
	}
	fish_prompt_emit_format(&b, cfg, icfg)
	fmt.sbprintln(&b, "end")
	return strings.to_string(b)
}
