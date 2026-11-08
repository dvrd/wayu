// prompt_generator.odin - Genera prompt nativo zsh pre-compilado
// Copied from starship.toml configuration - SIMPLIFIED VERSION
package wayu
import "core:fmt"
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
		if len(t) == 0 { continue }
		switch t {
		case "bold":       strings.write_string(&b, "%B")
		case "italic":     strings.write_string(&b, "%3m")
		case "underline":  strings.write_string(&b, "%U")
		case "dim":        strings.write_string(&b, "%2m")
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
	case "black":   return 0
	case "red":     return 1
	case "green":   return 2
	case "yellow":  return 3
	case "blue":    return 4
	case "magenta": return 5
	case "cyan":    return 6
	case "white":   return 7
	case "orange":  return 208
	case "pink":    return 205
	case "purple":  return 129
	case "gray", "grey": return 242
	case "lime":    return 118
	case "teal":    return 30
	case: return -1
	}
}

all_digits :: proc(s: string) -> bool {
	for c in s { if c < '0' || c > '9' { return false } }
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
		if lbracket == -1 { strings.write_string(&b, format[i:]); break }
		lbracket += i
		strings.write_string(&b, format[i:lbracket])
		rbracket := strings.index(format[lbracket:], "]")
		if rbracket == -1 { strings.write_string(&b, format[lbracket:]); break }
		rbracket += lbracket
		if rbracket+1 >= len(format) || format[rbracket+1] != '(' {
			strings.write_string(&b, format[lbracket:rbracket+1])
			i = rbracket + 1
			continue
		}
		lparen := rbracket + 1
		rparen := strings.index(format[lparen:], ")")
		if rparen == -1 { strings.write_string(&b, format[lbracket:]); break }
		rparen += lparen
		text := strings.trim_space(format[lbracket+1 : rbracket])
		style_str := strings.trim_space(format[lparen+1 : rparen])
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
	format: string,
	character_success: string,
	character_error: string,
	vimcmd_symbol: string,
	vimcmd_visual_symbol: string,
	vimcmd_replace_symbol: string,
	username_show_always: bool,
	username_style_user:  string,

	// Per-module format strings (from each [prompt.*] section)
	username_format:  string,
	hostname_format:  string,
	localip_format:   string,
	dir_format:       string,
	git_branch_format: string,

	// Per-language context entries from [prompt.contexts]
	// Key = language name, value = format string for {language_context}
	context_formats: map[string]string,
	context_detects: map[string][dynamic]string,
	// Context names in [prompt.contexts] file order (first match wins).
	context_order:   [dynamic]string,
}

// Free the heap parts of a PromptConfigFull (detect lists + containers).
// Format strings are slices of the TOML text and are not owned.
destroy_full_prompt_config :: proc(cfg: ^PromptConfigFull) {
	for _, list in cfg.context_detects {
		for item in list { delete(item) }
		delete(list)
	}
	delete(cfg.context_detects)
	delete(cfg.context_formats)
	delete(cfg.context_order)
}

// Parse config simple desde TOML
parse_full_prompt_config :: proc(toml: string) -> PromptConfigFull {
	cfg := PromptConfigFull{
		// Modules carry their own trailing separators (starship defaults).
		format = "{username}{dir}{git_branch}{character} ",
		character_success = "➜",
		character_error = "✗",
		vimcmd_symbol = "❮",
		vimcmd_visual_symbol = "❮",
		vimcmd_replace_symbol = "❮",
		username_show_always = false,
		username_style_user  = "white bold",
		username_format  = "[$user](white bold) in ",
		hostname_format  = "$hostname",
		localip_format   = "$localip",
		dir_format       = "[$dir](cyan bold) ",
		git_branch_format = "on [$branch](magenta bold) ",
		context_formats = make(map[string]string),
		context_detects = make(map[string][dynamic]string),
		context_order   = make([dynamic]string),
	}
	
	it := make_line_iter(toml)
	current_section := ""  // which [prompt.*] section we're in
	
	for line in line_iter_next(&it) {
		trimmed := strings.trim_space(line)
		
		if trimmed == "[prompt]" {
			current_section = "prompt"
			continue
		} else if trimmed == "[prompt.character]" {
			current_section = "character"
			continue
		} else if trimmed == "[prompt.username]" {
			current_section = "username"
			continue
		} else if trimmed == "[prompt.hostname]" {
			current_section = "hostname"
			continue
		} else if trimmed == "[prompt.localip]" {
			current_section = "localip"
			continue
		} else if trimmed == "[prompt.dir]" {
			current_section = "dir"
			continue
		} else if trimmed == "[prompt.git_branch]" {
			current_section = "git_branch"
			continue
		} else if trimmed == "[prompt.contexts]" {
			current_section = "contexts"
			continue
		}
		if strings.has_prefix(trimmed, "[") {
			current_section = ""
			continue
		}
		
		if len(current_section) == 0 { continue }
		
		// format = "..." only in [prompt] section
		if current_section == "prompt" && strings.has_prefix(trimmed, "format") && strings.contains(trimmed, "=") {
			eq_idx := strings.index(trimmed, "=")
			if eq_idx > 0 {
				value := strings.trim_space(trimmed[eq_idx+1:])
				value = prompt_strip_matching_quotes(value)
				if len(value) > 0 && value != "true" && value != "false" {
					cfg.format = value
				}
			}
		}
		
		if strings.contains(trimmed, "success_symbol") && strings.contains(trimmed, "=") {
			eq_idx := strings.index(trimmed, "=")
			if eq_idx > 0 {
				value := strings.trim_space(trimmed[eq_idx+1:])
				// Extraer emoji/caracter del formato [icon ](style)
				start := strings.index(value, "[")
				end := strings.index(value, "]")
				if start >= 0 && end > start {
					cfg.character_success = strings.trim_space(value[start+1:end])
				}
			}
		}
		
		if strings.contains(trimmed, "error_symbol") && strings.contains(trimmed, "=") {
			eq_idx := strings.index(trimmed, "=")
			if eq_idx > 0 {
				value := strings.trim_space(trimmed[eq_idx+1:])
				start := strings.index(value, "[")
				end := strings.index(value, "]")
				if start >= 0 && end > start {
					cfg.character_error = strings.trim_space(value[start+1:end])
				}
			}
		}
		
		// VI mode symbols - procesar específicos primero para evitar substring matches
		if strings.contains(trimmed, "vimcmd_visual_symbol") && strings.contains(trimmed, "=") {
			eq_idx := strings.index(trimmed, "=")
			if eq_idx > 0 {
				value := strings.trim_space(trimmed[eq_idx+1:])
				start := strings.index(value, "[")
				end := strings.index(value, "]")
				if start >= 0 && end > start {
					cfg.vimcmd_visual_symbol = strings.trim_space(value[start+1:end])
				}
			}
		}
		
		if strings.contains(trimmed, "vimcmd_replace_symbol") && strings.contains(trimmed, "=") {
			eq_idx := strings.index(trimmed, "=")
			if eq_idx > 0 {
				value := strings.trim_space(trimmed[eq_idx+1:])
				start := strings.index(value, "[")
				end := strings.index(value, "]")
				if start >= 0 && end > start {
					cfg.vimcmd_replace_symbol = strings.trim_space(value[start+1:end])
				}
			}
		}
		
		if strings.contains(trimmed, "vimcmd_symbol") && strings.contains(trimmed, "=") {
			eq_idx := strings.index(trimmed, "=")
			if eq_idx > 0 {
				value := strings.trim_space(trimmed[eq_idx+1:])
				start := strings.index(value, "[")
				end := strings.index(value, "]")
				if start >= 0 && end > start {
					cfg.vimcmd_symbol = strings.trim_space(value[start+1:end])
				}
			}
		}
		// Parse [prompt.contexts] entries: name = { format = "...", detect = [...] }
		if current_section == "contexts" && strings.contains(trimmed, "=") && strings.contains(trimmed, "format") {
			// Extract language name (before first =)
			first_eq := strings.index(trimmed, "=")
			if first_eq > 0 {
				lang_name := strings.trim_space(trimmed[:first_eq])
				seen := false
				for n in cfg.context_order {
					if n == lang_name { seen = true; break }
				}
				if !seen { append(&cfg.context_order, lang_name) }
				// Extract format value between quotes after "format"
				fmt_idx := strings.index(trimmed, "format")
				if fmt_idx > 0 {
					// Find the value after format =
					fmt_eq := strings.index(trimmed[fmt_idx:], "=")
					if fmt_eq > 0 {
						rest := strings.trim_space(trimmed[fmt_idx + fmt_eq + 1:])
						// Strip quotes and trailing content
						rest = strings.trim_prefix(rest, `"`)
						// Find closing quote
						end_quote := strings.index(rest, `"`)
						if end_quote > 0 {
							format_val := rest[:end_quote]
							cfg.context_formats[lang_name] = format_val
						}
					}
				}
				// Extract detect array
				det_idx := strings.index(trimmed, "detect")
				if det_idx > 0 {
					bracket_start := strings.index(trimmed[det_idx:], "[")
					bracket_end := strings.index(trimmed[det_idx:], "]")
					if bracket_start >= 0 && bracket_end > bracket_start {
						arr_content := trimmed[det_idx + bracket_start + 1 : det_idx + bracket_end]
						// Split by comma, strip quotes
						items := strings.split(arr_content, ",")
						defer delete(items)
						detect_list := make([dynamic]string)
						for item in items {
							val := strings.trim_space(item)
							val = strings.trim_prefix(val, `"`)
							val = strings.trim_suffix(val, `"`)
							if len(val) > 0 {
								append(&detect_list, strings.clone(val))
							}
						}
						if old, exists := cfg.context_detects[lang_name]; exists {
							for item in old { delete(item) }
							delete(old)
						}
						cfg.context_detects[lang_name] = detect_list
					}
				}
			}
		}

		// Per-section format parsing
		if (current_section == "username" || current_section == "hostname" ||
		    current_section == "localip" || current_section == "dir" ||
		    current_section == "git_branch") &&
		   strings.has_prefix(trimmed, "format") && strings.contains(trimmed, "=") {
			eq_idx := strings.index(trimmed, "=")
			if eq_idx > 0 {
				value := strings.trim_space(trimmed[eq_idx+1:])
				value = prompt_strip_matching_quotes(value)
				if len(value) > 0 {
					switch current_section {
					case "username":   cfg.username_format = value
					case "hostname":   cfg.hostname_format = value
					case "localip":    cfg.localip_format = value
					case "dir":        cfg.dir_format = value
					case "git_branch": cfg.git_branch_format = value
					}
				}
			}
		}

		// [prompt.username] keys
		if current_section == "username" && strings.contains(trimmed, "show_always") && strings.contains(trimmed, "true") {
			cfg.username_show_always = true
		}
		if current_section == "username" && strings.contains(trimmed, "style_user") && strings.contains(trimmed, "=") {
			eq_idx := strings.index(trimmed, "=")
			if eq_idx > 0 {
				value := strings.trim_space(trimmed[eq_idx+1:])
				value = prompt_strip_matching_quotes(value)
				if len(value) > 0 { cfg.username_style_user = value }
			}
		}
	}
	
	return cfg
}

// The native prompt is opt-in: it (and its vi keymap, zle widgets and precmd
// hooks) is generated only when wayu.toml has `enabled = true` under [prompt].
// Without it wayu leaves PROMPT, keymaps and zle widgets alone.
prompt_is_enabled :: proc(toml: string) -> bool {
	it := make_line_iter(toml)
	in_prompt := false
	for line in line_iter_next(&it) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "[") {
			in_prompt = trimmed == "[prompt]"
			continue
		}
		if !in_prompt { continue }
		eq := strings.index_byte(trimmed, '=')
		if eq <= 0 || strings.trim_space(trimmed[:eq]) != "enabled" { continue }
		value := strings.trim_space(trimmed[eq+1:])
		if hash := strings.index_byte(value, '#'); hash >= 0 {
			value = strings.trim_space(value[:hash])
		}
		return value == "true"
	}
	return false
}

// Escape `s` for splicing inside a zsh double-quoted string: backslash, `"`,
// `$` and backtick are backslash-escaped so config text is always literal (no `$(...)` execution,
// no broken quoting). Prompt `%` escapes are left for prompt expansion.
// Returns a temp-allocated string.
prompt_dq_escape :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i in 0..<len(s) {
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
			fmt.sbprintln(builder, `  if [[ -n "${SSH_CONNECTION-}${SSH_CLIENT-}${SSH_TTY-}" ]] || (( EUID == 0 )); then`)
			indent = "    "
		}
		strings.write_string(builder, indent)
		strings.write_string(builder, `result+="`)
		strings.write_string(builder, rendered)
		strings.write_string(builder, `"`)
		fmt.sbprintln(builder)
		if !cfg.username_show_always { fmt.sbprintln(builder, "  fi") }
	} else if name == "hostname" {
		rendered := prompt_render_module(cfg.hostname_format, {{`\$hostname`, "%m"}})
		strings.write_string(builder, `  result+="`)
		strings.write_string(builder, rendered)
		strings.write_string(builder, `"`)
		fmt.sbprintln(builder)
	} else if name == "localip" {
		// $localip gets replaced with a shell subshell that fetches the IP
		rendered := prompt_render_module(cfg.localip_format, {{`\$localip`, `$(command ipconfig getifaddr en0 2>/dev/null || command ip -4 route get 1 2>/dev/null | command awk '{print $7; exit}')`}})
		strings.write_string(builder, `  result+="`)
		strings.write_string(builder, rendered)
		strings.write_string(builder, `"`)
		fmt.sbprintln(builder)
	} else if name == "dir" {
		rendered := prompt_render_module(cfg.dir_format, {{`\$basename`, "%1~"}, {`\$pwd`, "%/"}, {`\$dir`, "%~"}})
		strings.write_string(builder, `  result+="`)
		strings.write_string(builder, rendered)
		strings.write_string(builder, `"`)
		fmt.sbprintln(builder)
	} else if name == "git_branch" {
		rendered := prompt_render_module(cfg.git_branch_format, {{`\$branch`, "${_WAYU_GIT_BRANCH}"}})
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
			rendered := prompt_render_module(fmt_str, {{`\$version`, "${_WAYU_CONTEXT_VER}"}})
			strings.write_string(builder, `    `)
			// Same sanitizing as _wayu_detect_context's _WAYU_CONTEXT values.
			strings.write_string(builder, sanitize_ident(lang))
			strings.write_string(builder, `) result+="`)
			strings.write_string(builder, rendered)
			strings.write_string(builder, `" ;;`)
			fmt.sbprintln(builder)
		}
		// Default: show shell name
		fmt.sbprintln(builder, `    *) result+="$SHELL:t" ;;`)
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

generate_full_prompt :: proc(cfg: PromptConfigFull) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)
	
	fmt.sbprintln(&builder, "# === Wayu Native Prompt (from starship.toml) ===")
	fmt.sbprintln(&builder)
	
	// Variables globales para cachear git info
	fmt.sbprintln(&builder, "typeset -g _WAYU_GIT_BRANCH=\"\"")
	fmt.sbprintln(&builder, "typeset -g _WAYU_GIT_DIR=\"\"")
	fmt.sbprintln(&builder)
	
	// Git info — single rev-parse call, runs synchronously on precmd
	// because the prompt needs _WAYU_GIT_BRANCH immediately.
	// Uses one `git` invocation instead of three.
	fmt.sbprintln(&builder, "_wayu_update_git_info() {")
	fmt.sbprintln(&builder, "  local git_info")
	fmt.sbprintln(&builder, `  git_info="$(command git rev-parse --short HEAD --show-toplevel 2>/dev/null)"`) 
	fmt.sbprintln(&builder, "  if [[ -n \"$git_info\" ]]; then")
	fmt.sbprintln(&builder, `    _WAYU_GIT_DIR="${git_info##*$'\n'}"`)  // last line = toplevel
	fmt.sbprintln(&builder, `    _WAYU_GIT_BRANCH="$(command git symbolic-ref --short HEAD 2>/dev/null || builtin echo "${git_info%%$'\n'*}")"`)  // branch or short hash
	fmt.sbprintln(&builder, "  else")
	fmt.sbprintln(&builder, `    _WAYU_GIT_BRANCH=""`)
	fmt.sbprintln(&builder, `    _WAYU_GIT_DIR=""`)
	fmt.sbprintln(&builder, "  fi")
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)
	
	// Hook precmd
	fmt.sbprintln(&builder, "autoload -Uz add-zsh-hook")
	fmt.sbprintln(&builder, "add-zsh-hook precmd _wayu_update_git_info")
	fmt.sbprintln(&builder)
	
	// Función principal de prompt (full version)
	fmt.sbprintln(&builder, "_wayu_prompt_full() {")
	fmt.sbprintln(&builder, `  local result=""`)
	fmt.sbprintln(&builder, "  # _WAYU_LAST_EXIT set by _wayu_prompt_master")
	fmt.sbprintln(&builder)
	
	// Procesar cada componente según el format
	// Manejar newlines en el format (reemplazar \n literal con newline real)
	format_with_newlines, was_alloc := strings.replace_all(cfg.format, `\n`, "\n")
	defer if was_alloc { delete(format_with_newlines) }
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
					token_name := part[open_bracket+2 : close_bracket]  // between [{ and }]
					
					// Check for (style) after }]
					if close_bracket+2 < len(part) && part[close_bracket+2] == '(' {
						close_paren := strings.index(part[close_bracket+2:], ")")
						if close_paren != -1 {
							close_paren += close_bracket + 2
							style_str := strings.trim_space(part[close_bracket+3 : close_paren])
							
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
			token := part[open_brace+1 : close_brace]
			pos = close_brace + 1

			// Generate shell code for known token
			generate_prompt_token(&builder, cfg, token)
		}
	}  // Cierre del for loop
	
	// Output final
	fmt.sbprintln(&builder, `  print -r -- "$result"`)
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)
	
	// NOTA: PROMPT se configura en generate_interactive_prompt
	// para permitir integración con features interactivas
	
	return strings.clone(strings.to_string(builder))
}

InteractiveConfig :: struct {
	// Toggle
	toggle_key: string,
	toggle_enabled: bool,

	// VI Mode
	vi_mode_indicator: bool,
	vi_insert_symbol: string,
	vi_normal_symbol: string,
	vi_visual_symbol: string,

	// Context
	context_aware: bool,

	// Async
	async_rprompt: bool,
	async_interval: int,
	rprompt_format:  string,

	// Transient
	transient_enabled: bool,
	transient_format: string,

	// [prompt.contexts] (detect lists) used to generate context detection.
	// Optional; nil means built-in detection only.
	contexts: ^PromptConfigFull,
}

// Genera todo el código interactivo
generate_interactive_prompt :: proc(base_prompt: string, cfg: InteractiveConfig) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	fmt.sbprintln(&builder, "# === Interactive Prompt Features ===")
	fmt.sbprintln(&builder)

	// Include base prompt function
	fmt.sbprintln(&builder, "# === Base Prompt (from starship.toml) ===")
	fmt.sbprint(&builder, base_prompt)
	fmt.sbprintln(&builder)

	// Variables de estado
	fmt.sbprintln(&builder, "# State variables")
	fmt.sbprintln(&builder, "typeset -g _WAYU_PROMPT_MODE=\"full\"")
	fmt.sbprintln(&builder, "typeset -g _WAYU_VI_MODE=\"INSERT\"")
	fmt.sbprintln(&builder, "typeset -g _WAYU_CONTEXT=\"default\"")
	fmt.sbprintln(&builder, "typeset -g _WAYU_CONTEXT_VER=\"\"")
	fmt.sbprintln(&builder, "typeset -g _WAYU_ASYNC_DATA=\"\"")
	fmt.sbprintln(&builder)

	// 1. VI MODE INDICATOR (first: `bindkey -v` resets the main keymap, so
	// any binding made before it would land in the wrong keymap)
	if cfg.vi_mode_indicator {
		generate_vi_mode_feature(&builder, cfg)
	}

	// 2. TOGGLE FEATURE (opt-in)
	if cfg.toggle_enabled {
		generate_toggle_feature(&builder, cfg.toggle_key, cfg.vi_mode_indicator)
	}

	// 3. CONTEXT AWARE
	if cfg.context_aware {
		generate_context_feature(&builder, cfg.contexts)
	}

	// 4. ASYNC RPROMPT
	if cfg.async_rprompt {
		generate_async_feature(&builder, cfg.async_interval, cfg.rprompt_format)
	}

	// 5. TRANSIENT PROMPT
	if cfg.transient_enabled {
		generate_transient_feature(&builder, cfg.transient_format)
	}

	// 6. SEPARATOR LINE (línea entre output y prompt)
	generate_separator_feature(&builder)

	// Función de prompt maestra que combina todo
	fmt.sbprintln(&builder, "# === Master Prompt Function ===")
	fmt.sbprintln(&builder, "_wayu_prompt_master() {")
	fmt.sbprintln(&builder, "  local exit_code=$?")
	fmt.sbprintln(&builder, "  local result=\"\"")
	fmt.sbprintln(&builder)

	// Guardar exit_code para que _wayu_prompt_full lo use
	fmt.sbprintln(&builder, "  # Guardar exit_code para funciones hijas")
	fmt.sbprintln(&builder, "  export _WAYU_LAST_EXIT=$exit_code")
	fmt.sbprintln(&builder)

	// Usar prompt según modo (full/minimal)
	if cfg.toggle_enabled || cfg.transient_enabled {
		fmt.sbprintln(&builder, "  # Select prompt based on mode")
		fmt.sbprintln(&builder, "  if [[ \"$_WAYU_PROMPT_MODE\" == \"minimal\" ]]; then")
		if cfg.transient_enabled {
			fmt.sbprintln(&builder, "    result+=\"$(_wayu_prompt_transient)\"")
		} else {
			fmt.sbprintln(&builder, "    result+=\"%~ ➜ \"")
		}
		fmt.sbprintln(&builder, "  else")
		fmt.sbprintln(&builder, "    result+=\"$(_wayu_prompt_full)\"")
		fmt.sbprintln(&builder, "  fi")
	} else {
		fmt.sbprintln(&builder, "  # Full prompt only")
		fmt.sbprintln(&builder, "  result+=\"$(_wayu_prompt_full)\"")
	}

	fmt.sbprintln(&builder)
	fmt.sbprintln(&builder, `  print -r -- "$result"`)
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)

	// Configurar PROMPT final
	fmt.sbprintln(&builder, "setopt promptsubst")
	// PROMPT: newline + $() in single quotes → promptsubst re-evaluates each render
	fmt.sbprintln(&builder, `PROMPT=$'\n''$(_wayu_prompt_master)'`)

	// RPROMPT async si está habilitado
	if cfg.async_rprompt {
		fmt.sbprintln(&builder, `RPROMPT='${_WAYU_ASYNC_DATA}'`)
	} else {
		fmt.sbprintln(&builder, "unset RPROMPT")
	}

	return strings.clone(strings.to_string(builder))
}

// TOGGLE FEATURE. Bound in explicit keymaps: viins + vicmd with the vi
// keymap wayu sets up, emacs otherwise.
generate_toggle_feature :: proc(b: ^strings.Builder, key: string, vi: bool) {
	fmt.sbprintln(b, "# === Feature: Toggle Prompt (Minimal/Full) ===")
	fmt.sbprintln(b, "_wayu_toggle_prompt() {")
	fmt.sbprintln(b, "  if [[ \"$_WAYU_PROMPT_MODE\" == \"full\" ]]; then")
	fmt.sbprintln(b, `    _WAYU_PROMPT_MODE="minimal"`)
	fmt.sbprintln(b, "  else")
	fmt.sbprintln(b, `    _WAYU_PROMPT_MODE="full"`)
	fmt.sbprintln(b, "  fi")
	fmt.sbprintln(b, "  zle reset-prompt")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "zle -N _wayu_toggle_prompt")
	key_q := shell_single_quote(key, context.temp_allocator)
	for keymap in ([]string{"viins", "vicmd"} if vi else []string{"emacs"}) {
		fmt.sbprintfln(b, "bindkey -M %s %s _wayu_toggle_prompt", keymap, key_q)
	}
	fmt.sbprintln(b)
}

// VI MODE FEATURE
generate_vi_mode_feature :: proc(b: ^strings.Builder, cfg: InteractiveConfig) {
	fmt.sbprintln(b, "# === Feature: VI Mode Indicator ===")
	fmt.sbprintln(b, "# Activar modo VI para selección visual")
	fmt.sbprintln(b, "bindkey -v")
	fmt.sbprintln(b, "export KEYTIMEOUT=1  # Reducir delay al cambiar modos")
	fmt.sbprintln(b, "bindkey -M viins '^?' backward-delete-char")
	fmt.sbprintln(b, "bindkey -M viins '^H' backward-delete-char")
	fmt.sbprintln(b)
	fmt.sbprintln(b, "# Variables para tracking de modo")
	fmt.sbprintln(b, "typeset -g _WAYU_VI_MODE=\"INSERT\"")
	fmt.sbprintln(b)
	fmt.sbprintln(b, "function zle-keymap-select {")
	fmt.sbprintln(b, "  case $KEYMAP in")
	fmt.sbprintln(b, `    vicmd) _WAYU_VI_MODE="NORMAL" ;;`)
	fmt.sbprintln(b, `    main|viins) _WAYU_VI_MODE="INSERT" ;;`)
	fmt.sbprintln(b, `    visual|vivis) _WAYU_VI_MODE="VISUAL" ;;`)
	fmt.sbprintln(b, "  esac")
	fmt.sbprintln(b, "  zle reset-prompt")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "zle -N zle-keymap-select")
	fmt.sbprintln(b, "zle -N zle-line-init zle-keymap-select")
	fmt.sbprintln(b)
	// Wrappers para visual mode: zle-keymap-select no se dispara al entrar a visual
	fmt.sbprintln(b, "# Wrappers para visual mode (zle-keymap-select no lo detecta solo)")
	fmt.sbprintln(b, "_wayu_visual_mode() {")
	fmt.sbprintln(b, "  zle visual-mode")
	fmt.sbprintln(b, `  _WAYU_VI_MODE="VISUAL"`)
	fmt.sbprintln(b, "  zle reset-prompt")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "_wayu_visual_line_mode() {")
	fmt.sbprintln(b, "  zle visual-line-mode")
	fmt.sbprintln(b, `  _WAYU_VI_MODE="VISUAL"`)
	fmt.sbprintln(b, "  zle reset-prompt")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "zle -N _wayu_visual_mode")
	fmt.sbprintln(b, "zle -N _wayu_visual_line_mode")
	fmt.sbprintln(b, "bindkey -M vicmd 'v' _wayu_visual_mode")
	fmt.sbprintln(b, "bindkey -M vicmd 'V' _wayu_visual_line_mode")
	fmt.sbprintln(b)
	fmt.sbprintln(b, "# Salir de visual mode: 'i' → INSERT, Esc → NORMAL (cancelando selección)")
	fmt.sbprintln(b, "bindkey -M visual 'i' vi-insert")
	fmt.sbprintln(b, "_wayu_visual_exit() {")
	fmt.sbprintln(b, "  zle deactivate-region")
	fmt.sbprintln(b, "  zle vi-cmd-mode")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "zle -N _wayu_visual_exit")
	fmt.sbprintln(b, "bindkey -M visual $'\\e' _wayu_visual_exit")
	fmt.sbprintln(b)
}

// 3. CONTEXT AWARE
// File-existence only detection (instant, no subprocesses).
// Version string is fetched asynchronously by the async worker.
generate_context_feature :: proc(b: ^strings.Builder, contexts: ^PromptConfigFull = nil) {
	fmt.sbprintln(b, "# === Feature: Context-Aware Prompt ===")
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
			if !has || len(detects) == 0 { continue }
			cond := context_detect_condition(detects[:])
			if len(cond) == 0 { continue }
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
	BUILTIN :: [?][2]string{
		{"rust",    `[[ -f "Cargo.toml" ]]`},
		{"bun",     `[[ -f "bun.lockb" ]] || [[ -f "bunfig.toml" ]]`},
		{"gleam",   `[[ -f "gleam.toml" ]]`},
		{"swift",   `[[ -f "Package.swift" ]]`},
		{"dart",    `[[ -f "pubspec.yaml" ]]`},
		{"php",     `[[ -f "composer.json" ]]`},
		{"ruby",    `[[ -f "Gemfile" ]] || [[ -f ".ruby-version" ]]`},
		{"elixir",  `[[ -f "mix.exs" ]]`},
		{"erlang",  `[[ -f "rebar.config" ]] || [[ -f "erlang.mk" ]]`},
		{"haskell", `[[ -f "stack.yaml" ]] || [[ -f "cabal.project" ]]`},
		{"julia",   `[[ -f "Project.toml" ]] || [[ -f "Manifest.toml" ]]`},
		{"odin",    `[[ -f "ols.json" ]] || (){ [[ -e $1 ]] } *.odin(NY1) || (){ [[ -e $1 ]] } src/*.odin(NY1)`},
		{"golang",  `[[ -f "go.mod" ]]`},
		{"nim",     `[[ -f "nim.cfg" ]]`},
		{"ocaml",   `[[ -f "dune" ]]`},
		{"nix",     `[[ -f "flake.nix" ]] || [[ -f "default.nix" ]]`},
		{"deno",    `[[ -f "deno.json" ]] || [[ -f "deno.jsonc" ]]`},
		{"elm",     `[[ -f "elm.json" ]]`},
		{"crystal", `[[ -f "shard.yml" ]]`},
		{"perl",    `[[ -f "cpanfile" ]]`},
		{"buf",     `[[ -f "buf.yaml" ]]`},
		{"nodejs",  `[[ -f "package.json" ]]`},
		{"java",    `[[ -f "pom.xml" ]] || [[ -f "build.gradle" ]]`},
		{"scala",   `[[ -f "build.sbt" ]]`},
		{"python",  `[[ -f "requirements.txt" ]] || [[ -f "pyproject.toml" ]]`},
		{"zig",     `[[ -f "build.zig" ]] || [[ -f "build.zig.zon" ]]`},
		{"rlang",   `[[ -f "DESCRIPTION" ]]`},
		{"lua",     `[[ -f ".lua-version" ]]`},
		{"docker",  `[[ -f "Dockerfile" ]] || [[ -f "docker-compose.yml" ]]`},
		{"aws",     `[[ -e ".aws" ]]`},
	}
	for entry in BUILTIN {
		if configured[entry[0]] { continue }
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
		if len(item) == 0 { continue }
		safe := true
		is_glob := false
		for i in 0..<len(item) {
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
		if !safe { continue }
		if n > 0 { strings.write_string(&sb, " || ") }
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
generate_async_feature :: proc(b: ^strings.Builder, interval: int, rprompt_format: string) {
	fmt.sbprintln(b, "# === Feature: Async RPROMPT ===")
	fmt.sbprintln(b, "typeset -g _WAYU_ASYNC_FD=")
	fmt.sbprintln(b)

	// Version command lookup — maps context name to version command.
	// Runs in the background worker so it never blocks the prompt.
	fmt.sbprintln(b, "_wayu_version_cmd() {")
	fmt.sbprintln(b, `  case "$1" in`)
	fmt.sbprintln(b, `    rust)    command rustc --version 2>/dev/null | command awk '{print $2}' ;;`)
	fmt.sbprintln(b, `    bun)     command bun --version 2>/dev/null ;;`)
	fmt.sbprintln(b, `    dart)    command dart --version 2>/dev/null | command awk '{print $4}' ;;`)
	fmt.sbprintln(b, `    ruby)    command ruby --version 2>/dev/null | command awk '{print $2}' ;;`)
	fmt.sbprintln(b, `    elixir)  command elixir --version 2>/dev/null | command awk 'NR==1{print $2}' ;;`)
	fmt.sbprintln(b, `    odin)    command odin version 2>/dev/null | command awk '{print $3}' ;;`)
	fmt.sbprintln(b, `    golang)  command go version 2>/dev/null | command awk '{print $3}' | command sed 's/go//' ;;`)
	fmt.sbprintln(b, `    deno)    command deno --version 2>/dev/null | command head -1 | command awk '{print $2}' ;;`)
	fmt.sbprintln(b, `    nodejs)  command node --version 2>/dev/null | command sed 's/v//' ;;`)
	fmt.sbprintln(b, `    python)  command python3 --version 2>/dev/null | command awk '{print $2}' ;;`)
	fmt.sbprintln(b, `    zig)     command zig version 2>/dev/null ;;`)
	fmt.sbprintln(b, `    *)       ;;`)
	fmt.sbprintln(b, "  esac")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)

	// The background worker
	fmt.sbprintln(b, "_wayu_async_worker() {")
	fmt.sbprintln(b, "  local git_pending=\"\"")
	fmt.sbprintln(b, "  if [[ -n \"$_WAYU_GIT_BRANCH\" ]]; then")
	fmt.sbprintln(b, `    git_pending="$(command git status --porcelain 2>/dev/null | command wc -l | command tr -d ' ')"`) 
	fmt.sbprintln(b, "    if [[ \"$git_pending\" -gt 0 ]]; then")
	// Apply rprompt_format: DSL conversion + escaping + token substitution
	{
		rpfmt := prompt_render_module(rprompt_format, {
			{"{git_pending}", "${git_pending}"},
			{"{git_branch}", "${_WAYU_GIT_BRANCH}"},
		})
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
	fmt.sbprintln(b, "  # Fetch version string for current context (async — never blocks prompt)")
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
	fmt.sbprintln(b, `  if builtin printf '%s\n%s' "$git_pending" "$ver" > "$tmpf" && command mv -f -- "$tmpf" "$dir/data" 2>/dev/null; then`)
	fmt.sbprintln(b, "    builtin kill -USR1 $$ 2>/dev/null || true")
	fmt.sbprintln(b, "  else")
	fmt.sbprintln(b, `    command rm -f -- "$tmpf"`)
	fmt.sbprintln(b, "  fi")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)

	// USR1 handler body. helpers.zsh owns the single TRAPUSR1 (shared with
	// zsh-defer) and forwards here; defining TRAPUSR1 in the prompt used to
	// clobber the zsh-defer trap. Fallback TRAPUSR1 only if none exists.
	fmt.sbprintln(b, "_wayu_async_on_usr1() {")
	fmt.sbprintln(b, `  local f="$_WAYU_ASYNC_DIR/data"`)
	fmt.sbprintln(b, "  if [[ -n \"$_WAYU_ASYNC_DIR\" && -f \"$f\" ]]; then")
	fmt.sbprintln(b, `    local lines=("${(@f)$(< "$f")}")`)
	fmt.sbprintln(b, `    _WAYU_ASYNC_DATA="${lines[1]-}"`)
	fmt.sbprintln(b, `    _WAYU_CONTEXT_VER="${lines[2]-}"`)
	fmt.sbprintln(b, `    command rm -f -- "$f"`)
	fmt.sbprintln(b, "  fi")
	fmt.sbprintln(b, "  zle && zle reset-prompt")
	fmt.sbprintln(b, "  return 0")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "if (( ! ${+functions[TRAPUSR1]} )); then")
	fmt.sbprintln(b, "  TRAPUSR1() { _wayu_async_on_usr1; return 0; }")
	fmt.sbprintln(b, "fi")
	fmt.sbprintln(b)

	// The private dir is created lazily on the first prompt (one mktemp per
	// shell, nothing at startup) and removed when the shell exits.
	// Re-sourcing core keeps the existing dir (no orphaned dirs).
	fmt.sbprintln(b, `typeset -g _WAYU_ASYNC_DIR="${_WAYU_ASYNC_DIR-}"`)
	fmt.sbprintln(b, "_wayu_start_async() {")
	fmt.sbprintln(b, "  local ret=$?")
	fmt.sbprintln(b, `  if [[ -z "$_WAYU_ASYNC_DIR" || ! -d "$_WAYU_ASYNC_DIR" ]]; then`)
	fmt.sbprintln(b, `    _WAYU_ASYNC_DIR="$(command mktemp -d "${TMPDIR:-/tmp}/wayu-async.XXXXXX" 2>/dev/null)" || _WAYU_ASYNC_DIR=""`)
	fmt.sbprintln(b, "  fi")
	fmt.sbprintln(b, `  [[ -n "$_WAYU_ASYNC_DIR" ]] && (_wayu_async_worker &)`)
	fmt.sbprintln(b, "  return $ret")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "_wayu_async_cleanup() {")
	fmt.sbprintln(b, `  [[ -n "$_WAYU_ASYNC_DIR" && -d "$_WAYU_ASYNC_DIR" ]] && command rm -rf -- "$_WAYU_ASYNC_DIR"`)
	fmt.sbprintln(b, "  return 0")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)
	fmt.sbprintln(b, "add-zsh-hook precmd _wayu_start_async")
	fmt.sbprintln(b, "add-zsh-hook zshexit _wayu_async_cleanup")
	fmt.sbprintln(b)
}

// 5. TRANSIENT FEATURE
generate_transient_feature :: proc(b: ^strings.Builder, format: string) {
	fmt.sbprintln(b, "# === Feature: Transient Prompt ===")
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

	fmt.sbprintln(b, `  print -r -- "$result"`)
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)
}

// 6. SEPARATOR LINE FEATURE (líneas continuas con espacios)
generate_separator_feature :: proc(b: ^strings.Builder) {
	// Separator lines disabled
}

// Parse config interactiva desde TOML (simplificado)
parse_interactive_config :: proc(toml: string) -> InteractiveConfig {
	cfg := InteractiveConfig{
		toggle_key = "^P",
		toggle_enabled = false, // opt-in: ^P is history navigation
		vi_mode_indicator = true,
		vi_insert_symbol = "[I]",
		vi_normal_symbol = "[N]",
		vi_visual_symbol = "[V]",
		context_aware = true,
		async_rprompt = true,
		async_interval = 2,
		rprompt_format = "[ {git_pending}](242)",
		transient_enabled = true,
		transient_format = "{dir} {character}",
	}

	it := make_line_iter(toml)
	in_interactive := false

	for line in line_iter_next(&it) {
		trimmed := strings.trim_space(line)

		if trimmed == "[prompt.interactive]" {
			in_interactive = true
			continue
		}
		if strings.has_prefix(trimmed, "[") && in_interactive {
			in_interactive = false
			continue
		}

		if !in_interactive { continue }

		if strings.contains(trimmed, "toggle_key") {
			start := strings.index(trimmed, `"`)
			end := strings.last_index(trimmed, `"`)
			if start >= 0 && end > start {
				cfg.toggle_key = trimmed[start+1:end]
			}
		}
		if strings.contains(trimmed, "toggle_enabled") {
			if strings.contains(trimmed, "true") { cfg.toggle_enabled = true }
			if strings.contains(trimmed, "false") { cfg.toggle_enabled = false }
		}
		if strings.contains(trimmed, "vi_mode_indicator") && strings.contains(trimmed, "false") {
			cfg.vi_mode_indicator = false
		}
		if strings.contains(trimmed, "context_aware") && strings.contains(trimmed, "false") {
			cfg.context_aware = false
		}
		if strings.contains(trimmed, "async_rprompt") && strings.contains(trimmed, "false") {
			cfg.async_rprompt = false
		}
		if strings.contains(trimmed, "transient_enabled") && strings.contains(trimmed, "false") {
			cfg.transient_enabled = false
		}
		if strings.contains(trimmed, "rprompt_format") && strings.contains(trimmed, "=") {
			eq_idx := strings.index(trimmed, "=")
			if eq_idx > 0 {
				value := prompt_strip_matching_quotes(strings.trim_space(trimmed[eq_idx+1:]))
				if len(value) > 0 { cfg.rprompt_format = value }
			}
		}
	}

	return cfg
}

// Strip exactly one MATCHING pair of surrounding quotes ("…" or '…').
// Borrowed slice, no allocation. Independent trimming of " and ' used to cut
// a trailing ' off values such as "[%n]'".
prompt_strip_matching_quotes :: proc(v: string) -> string {
	n := len(v)
	if n >= 2 && ((v[0] == '"' && v[n-1] == '"') || (v[0] == '\'' && v[n-1] == '\'')) {
		return v[1:n-1]
	}
	return v
}
