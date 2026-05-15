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
}

// Parse config simple desde TOML
parse_full_prompt_config :: proc(toml: string) -> PromptConfigFull {
	cfg := PromptConfigFull{
		format = "{username}{dir}{git_branch}{character}",
		character_success = "➜",
		character_error = "✗",
		vimcmd_symbol = "❮",
		vimcmd_visual_symbol = "❮",
		vimcmd_replace_symbol = "❮",
		username_show_always = false,
		username_style_user  = "white bold",
		username_format  = "[$user](white bold)",
		hostname_format  = "$hostname",
		localip_format   = "$localip",
		dir_format       = "[$dir](cyan bold)",
		git_branch_format = "[$branch](magenta bold)",
		context_formats = make(map[string]string),
		context_detects = make(map[string][dynamic]string),
	}
	
	lines := strings.split(toml, "\n")
	defer delete(lines)
	
	current_section := ""  // which [prompt.*] section we're in
	
	for line in lines {
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
				value = strings.trim_prefix(value, `"`)
				value = strings.trim_suffix(value, `"`)
				value = strings.trim_prefix(value, "'")
				value = strings.trim_suffix(value, "'")
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
				value = strings.trim_prefix(value, `"`)
				value = strings.trim_suffix(value, `"`)
				value = strings.trim_prefix(value, "'")
				value = strings.trim_suffix(value, "'")
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
				value = strings.trim_prefix(value, `"`)
				value = strings.trim_suffix(value, `"`)
				value = strings.trim_prefix(value, "'")
				value = strings.trim_suffix(value, "'")
				if len(value) > 0 { cfg.username_style_user = value }
			}
		}
	}
	
	return cfg
}

// Genera prompt nativo simplificado pero completo

// Generate shell code for a single prompt token (content only, no styling).
// Called by the format walker for both bare {token} and styled [{token}](style).
generate_prompt_token :: proc(builder: ^strings.Builder, cfg: PromptConfigFull, name: string) {
	// Each token has a per-module format string from [prompt.<name>].
	// The format uses the DSL ([text](style)) and module-specific variables
	// ($user, $hostname, $localip, $dir, $branch) that get replaced with
	// zsh escapes or shell commands.

	if name == "username" {
		rendered := dsl_to_zsh_format(cfg.username_format)
		defer delete(rendered)
		rendered, _ = strings.replace_all(rendered, "$user", "%n")
		strings.write_string(builder, `  result+="`)
		strings.write_string(builder, rendered)
		strings.write_string(builder, `"`)
		fmt.sbprintln(builder)
	} else if name == "hostname" {
		rendered := dsl_to_zsh_format(cfg.hostname_format)
		defer delete(rendered)
		rendered, _ = strings.replace_all(rendered, "$hostname", "%m")
		strings.write_string(builder, `  result+="`)
		strings.write_string(builder, rendered)
		strings.write_string(builder, `"`)
		fmt.sbprintln(builder)
	} else if name == "localip" {
		rendered := dsl_to_zsh_format(cfg.localip_format)
		defer delete(rendered)
		// $localip gets replaced with a shell subshell that fetches the IP
		rendered, _ = strings.replace_all(rendered, "$localip", `$(ipconfig getifaddr en0 2>/dev/null || ip -4 route get 1 2>/dev/null | awk '{print $7; exit}')`)
		strings.write_string(builder, `  result+="`)
		strings.write_string(builder, rendered)
		strings.write_string(builder, `"`)
		fmt.sbprintln(builder)
	} else if name == "dir" {
		rendered := dsl_to_zsh_format(cfg.dir_format)
		defer delete(rendered)
		rendered, _ = strings.replace_all(rendered, "$basename", "%1~")
		rendered, _ = strings.replace_all(rendered, "$pwd", "%/")
		rendered, _ = strings.replace_all(rendered, "$dir", "%~")
		strings.write_string(builder, `  result+="`)
		strings.write_string(builder, rendered)
		strings.write_string(builder, `"`)
		fmt.sbprintln(builder)
	} else if name == "git_branch" {
		rendered := dsl_to_zsh_format(cfg.git_branch_format)
		defer delete(rendered)
		rendered, _ = strings.replace_all(rendered, "$branch", "${_WAYU_GIT_BRANCH}")
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
			rendered := dsl_to_zsh_format(fmt_str)
			defer delete(rendered)
			// $version -> async-fetched version string
			rendered, _ = strings.replace_all(rendered, "$version", "${_WAYU_CONTEXT_VER}")
			strings.write_string(builder, `    `)
			strings.write_string(builder, lang)
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
		fmt.sbprint(builder, cfg.character_success)
		fmt.sbprintln(builder, `" ;;`)
		fmt.sbprint(builder, `    NORMAL) char_symbol="`)
		fmt.sbprint(builder, cfg.vimcmd_symbol)
		fmt.sbprintln(builder, `" ;;`)
		fmt.sbprint(builder, `    VISUAL) char_symbol="`)
		fmt.sbprint(builder, cfg.vimcmd_symbol)
		fmt.sbprintln(builder, `" ;;`)
		fmt.sbprint(builder, `    REPLACE|REPLACE_ONE) char_symbol="`)
		fmt.sbprint(builder, cfg.vimcmd_replace_symbol)
		fmt.sbprintln(builder, `" ;;`)
		fmt.sbprintln(builder, "    *)")
		fmt.sbprintln(builder, "      if [[ ${_WAYU_LAST_EXIT:-0} -eq 0 ]]; then")
		fmt.sbprint(builder, `        char_symbol="`)
		fmt.sbprint(builder, cfg.character_success)
		fmt.sbprintln(builder, `"`)
		fmt.sbprintln(builder, "      else")
		fmt.sbprint(builder, `        char_symbol="`)
		fmt.sbprint(builder, cfg.character_error)
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
	fmt.sbprintln(&builder, `  git_info="$(git rev-parse --short HEAD --show-toplevel 2>/dev/null)"`) 
	fmt.sbprintln(&builder, "  if [[ -n \"$git_info\" ]]; then")
	fmt.sbprintln(&builder, `    _WAYU_GIT_DIR="${git_info##*$'\n'}"`)  // last line = toplevel
	fmt.sbprintln(&builder, `    _WAYU_GIT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "${git_info%%$'\n'*}")"`)  // branch or short hash
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
					fmt.sbprint(&builder, literal)
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
					fmt.sbprint(&builder, remaining)
					fmt.sbprintln(&builder, `"`)
				}
				break
			}
			open_brace += pos

			// Emit literal text before the token
			if open_brace > pos {
				literal := part[pos:open_brace]
				fmt.sbprint(&builder, `  result+="`)
				fmt.sbprint(&builder, literal)
				fmt.sbprintln(&builder, `"`)
			}

			close_brace := strings.index(part[open_brace:], "}")
			if close_brace == -1 {
				// Unclosed — emit as literal
				fmt.sbprint(&builder, `  result+="`)
				fmt.sbprint(&builder, part[open_brace:])
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
	fmt.sbprintln(&builder, `  echo "$result"`)
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)
	
	// NOTA: PROMPT se configura en generate_interactive_prompt
	// para permitir integración con features interactivas
	
	return strings.clone(strings.to_string(builder))
}

// Para backward compatibility
PromptConfig :: struct {
	format:           string,
	symbols_success:  string,
	symbols_error:    string,
	colors_directory: string,
	colors_git_branch: string,
	colors_symbol_success: string,
	colors_symbol_error: string,
}

parse_prompt_config :: proc(toml_data: string) -> PromptConfig {
	full := parse_full_prompt_config(toml_data)
	
	return PromptConfig{
		format = full.format,
		symbols_success = "➜",
		symbols_error = "✗",
		colors_directory = "cyan",
		colors_git_branch = "magenta",
		colors_symbol_success = "green",
		colors_symbol_error = "red",
	}
}

generate_native_prompt :: proc(config: PromptConfig) -> string {
	full := PromptConfigFull{
		format = config.format,
		character_success = config.symbols_success,
		character_error = config.symbols_error,
	}
	return generate_full_prompt(full)
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

	// 1. TOGGLE FEATURE
	if cfg.toggle_enabled {
		generate_toggle_feature(&builder, cfg.toggle_key)
	}

	// 2. VI MODE INDICATOR
	if cfg.vi_mode_indicator {
		generate_vi_mode_feature(&builder, cfg)
	}

	// 3. CONTEXT AWARE
	if cfg.context_aware {
		generate_context_feature(&builder)
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
	fmt.sbprintln(&builder, `  echo "$result"`)
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

// 1. TOGGLE FEATURE
generate_toggle_feature :: proc(b: ^strings.Builder, key: string) {
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
	fmt.sbprintfln(b, "bindkey '%s' _wayu_toggle_prompt", key)
	fmt.sbprintln(b)
}

// 2. VI MODE FEATURE
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
generate_context_feature :: proc(b: ^strings.Builder) {
	fmt.sbprintln(b, "# === Feature: Context-Aware Prompt ===")
	fmt.sbprintln(b, "# File-only detection (instant). Version fetched async.")
	fmt.sbprintln(b, "_wayu_detect_context() {")
	fmt.sbprintln(b, `  _WAYU_CONTEXT_VER=""`)

	// Each entry: file test → context name. No subprocess calls.
	fmt.sbprintln(b, `  if [[ -f "Cargo.toml" ]]; then _WAYU_CONTEXT="rust"`)
	fmt.sbprintln(b, `  elif [[ -f "bun.lockb" ]] || [[ -f "bunfig.toml" ]]; then _WAYU_CONTEXT="bun"`)
	fmt.sbprintln(b, `  elif [[ -f "gleam.toml" ]]; then _WAYU_CONTEXT="gleam"`)
	fmt.sbprintln(b, `  elif [[ -f "Package.swift" ]]; then _WAYU_CONTEXT="swift"`)
	fmt.sbprintln(b, `  elif [[ -f "pubspec.yaml" ]]; then _WAYU_CONTEXT="dart"`)
	fmt.sbprintln(b, `  elif [[ -f "composer.json" ]]; then _WAYU_CONTEXT="php"`)
	fmt.sbprintln(b, `  elif [[ -f "Gemfile" ]] || [[ -f ".ruby-version" ]]; then _WAYU_CONTEXT="ruby"`)
	fmt.sbprintln(b, `  elif [[ -f "mix.exs" ]]; then _WAYU_CONTEXT="elixir"`)
	fmt.sbprintln(b, `  elif [[ -f "rebar.config" ]] || [[ -f "erlang.mk" ]]; then _WAYU_CONTEXT="erlang"`)
	fmt.sbprintln(b, `  elif [[ -f "stack.yaml" ]] || [[ -f "cabal.project" ]]; then _WAYU_CONTEXT="haskell"`)
	fmt.sbprintln(b, `  elif [[ -f "Project.toml" ]] || [[ -f "Manifest.toml" ]]; then _WAYU_CONTEXT="julia"`)
	fmt.sbprintln(b, `  elif [[ -f "ols.json" ]] || (){ [[ -e $1 ]] } *.odin(NY1) || (){ [[ -e $1 ]] } src/*.odin(NY1); then _WAYU_CONTEXT="odin"`)
	fmt.sbprintln(b, `  elif [[ -f "go.mod" ]]; then _WAYU_CONTEXT="golang"`)
	fmt.sbprintln(b, `  elif [[ -f "nim.cfg" ]]; then _WAYU_CONTEXT="nim"`)
	fmt.sbprintln(b, `  elif [[ -f "dune" ]]; then _WAYU_CONTEXT="ocaml"`)
	fmt.sbprintln(b, `  elif [[ -f "flake.nix" ]] || [[ -f "default.nix" ]]; then _WAYU_CONTEXT="nix"`)
	fmt.sbprintln(b, `  elif [[ -f "deno.json" ]] || [[ -f "deno.jsonc" ]]; then _WAYU_CONTEXT="deno"`)
	fmt.sbprintln(b, `  elif [[ -f "elm.json" ]]; then _WAYU_CONTEXT="elm"`)
	fmt.sbprintln(b, `  elif [[ -f "shard.yml" ]]; then _WAYU_CONTEXT="crystal"`)
	fmt.sbprintln(b, `  elif [[ -f "cpanfile" ]]; then _WAYU_CONTEXT="perl"`)
	fmt.sbprintln(b, `  elif [[ -f "buf.yaml" ]]; then _WAYU_CONTEXT="buf"`)
	fmt.sbprintln(b, `  elif [[ -f "package.json" ]]; then _WAYU_CONTEXT="nodejs"`)
	fmt.sbprintln(b, `  elif [[ -f "pom.xml" ]] || [[ -f "build.gradle" ]]; then _WAYU_CONTEXT="java"`)
	fmt.sbprintln(b, `  elif [[ -f "build.sbt" ]]; then _WAYU_CONTEXT="scala"`)
	fmt.sbprintln(b, `  elif [[ -f "requirements.txt" ]] || [[ -f "pyproject.toml" ]]; then _WAYU_CONTEXT="python"`)
	fmt.sbprintln(b, `  elif [[ -f "build.zig" ]] || [[ -f "build.zig.zon" ]]; then _WAYU_CONTEXT="zig"`)
	fmt.sbprintln(b, `  elif [[ -f "DESCRIPTION" ]]; then _WAYU_CONTEXT="rlang"`)
	fmt.sbprintln(b, `  elif [[ -f ".lua-version" ]]; then _WAYU_CONTEXT="lua"`)
	fmt.sbprintln(b, `  elif [[ -f "Dockerfile" ]] || [[ -f "docker-compose.yml" ]]; then _WAYU_CONTEXT="docker"`)
	fmt.sbprintln(b, `  elif [[ -f ".aws" ]] || [[ -d ".aws" ]]; then _WAYU_CONTEXT="aws"`)
	fmt.sbprintln(b, `  else _WAYU_CONTEXT="default"`)
	fmt.sbprintln(b, "  fi")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)
	fmt.sbprintln(b, "autoload -Uz add-zsh-hook")
	fmt.sbprintln(b, "add-zsh-hook chpwd _wayu_detect_context")
	fmt.sbprintln(b, "_wayu_detect_context  # Detect on startup")
	fmt.sbprintln(b)
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
	fmt.sbprintln(b, `    rust)    rustc --version 2>/dev/null | awk '{print $2}' ;;`)
	fmt.sbprintln(b, `    bun)     bun --version 2>/dev/null ;;`)
	fmt.sbprintln(b, `    dart)    dart --version 2>/dev/null | awk '{print $4}' ;;`)
	fmt.sbprintln(b, `    ruby)    ruby --version 2>/dev/null | awk '{print $2}' ;;`)
	fmt.sbprintln(b, `    elixir)  elixir --version 2>/dev/null | awk 'NR==1{print $2}' ;;`)
	fmt.sbprintln(b, `    odin)    odin version 2>/dev/null | awk '{print $3}' ;;`)
	fmt.sbprintln(b, `    golang)  go version 2>/dev/null | awk '{print $3}' | sed 's/go//' ;;`)
	fmt.sbprintln(b, `    deno)    deno --version 2>/dev/null | head -1 | awk '{print $2}' ;;`)
	fmt.sbprintln(b, `    nodejs)  node --version 2>/dev/null | sed 's/v//' ;;`)
	fmt.sbprintln(b, `    python)  python3 --version 2>/dev/null | awk '{print $2}' ;;`)
	fmt.sbprintln(b, `    zig)     zig version 2>/dev/null ;;`)
	fmt.sbprintln(b, `    *)       ;;`)
	fmt.sbprintln(b, "  esac")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)

	// The background worker
	fmt.sbprintln(b, "_wayu_async_worker() {")
	fmt.sbprintln(b, "  local git_pending=\"\"")
	fmt.sbprintln(b, "  if [[ -n \"$_WAYU_GIT_BRANCH\" ]]; then")
	fmt.sbprintln(b, `    git_pending="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"`) 
	fmt.sbprintln(b, "    if [[ \"$git_pending\" -gt 0 ]]; then")
	// Apply rprompt_format: DSL conversion + token substitution
	{
		rpfmt := dsl_to_zsh_format(rprompt_format)
		defer delete(rpfmt)
		rpfmt, _ = strings.replace_all(rpfmt, "{git_pending}", "${git_pending}")
		rpfmt, _ = strings.replace_all(rpfmt, "{git_branch}", "${_WAYU_GIT_BRANCH}")
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
	fmt.sbprintln(b, "  # Write results to temp file and signal parent")
	fmt.sbprintln(b, `  local tmpf="${TMPDIR:-/tmp}/.wayu_async_$$"`)
	fmt.sbprintln(b, `  printf '%s\n%s' "$git_pending" "$ver" > "$tmpf"`)
	fmt.sbprintln(b, "  kill -USR1 $$ 2>/dev/null || true")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)

	// Signal handler reads results from temp file
	fmt.sbprintln(b, "TRAPUSR1() {")
	fmt.sbprintln(b, `  local tmpf="${TMPDIR:-/tmp}/.wayu_async_$$"`)
	fmt.sbprintln(b, "  if [[ -f \"$tmpf\" ]]; then")
	fmt.sbprintln(b, `    local lines=("${(@f)$(< "$tmpf")}")`)
	fmt.sbprintln(b, `    _WAYU_ASYNC_DATA="${lines[1]}"`)
	fmt.sbprintln(b, `    _WAYU_CONTEXT_VER="${lines[2]}"`)
	fmt.sbprintln(b, `    rm -f "$tmpf"`)
	fmt.sbprintln(b, "  fi")
	fmt.sbprintln(b, "  zle && zle reset-prompt")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)

	fmt.sbprintln(b, "_wayu_start_async() {")
	fmt.sbprintln(b, "  (_wayu_async_worker &)")
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b)
	fmt.sbprintln(b, "add-zsh-hook precmd _wayu_start_async")
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
		fmt.sbprintln(b, "  if [[ $? -eq 0 ]]; then")
		fmt.sbprintln(b, `    result+="➜ "`)
		fmt.sbprintln(b, "  else")
		fmt.sbprintln(b, `    result+="✗ "`)
		fmt.sbprintln(b, "  fi")
	}

	fmt.sbprintln(b, `  echo "$result"`)
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
		toggle_enabled = true,
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

	lines := strings.split(toml, "\n")
	defer delete(lines)

	in_interactive := false

	for line in lines {
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
		if strings.contains(trimmed, "toggle_enabled") && strings.contains(trimmed, "false") {
			cfg.toggle_enabled = false
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
				value := strings.trim_space(trimmed[eq_idx+1:])
				value = strings.trim_prefix(value, `"`)
				value = strings.trim_suffix(value, `"`)
				if len(value) > 0 { cfg.rprompt_format = value }
			}
		}
	}

	return cfg
}
