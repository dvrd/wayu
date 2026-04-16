// prompt_generator.odin - Genera prompt nativo zsh pre-compilado
// Copied from starship.toml configuration - SIMPLIFIED VERSION
package wayu

import "core:fmt"
import "core:strings"

// Configuración del prompt (basada en starship.toml)
PromptConfigFull :: struct {
	format: string,
	character_success: string,
	character_error: string,
	vimcmd_symbol: string,
	vimcmd_visual_symbol: string,
	vimcmd_replace_symbol: string,
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
	}
	
	lines := strings.split(toml, "\n")
	defer delete(lines)
	
	in_prompt_section := false
	
	for line in lines {
		trimmed := strings.trim_space(line)
		
		// Detectar sección [prompt] o subsecciones [prompt.character]
		if trimmed == "[prompt]" || trimmed == "[prompt.character]" {
			in_prompt_section = true
			continue
		}
		if strings.has_prefix(trimmed, "[") && in_prompt_section {
			in_prompt_section = false
			continue
		}
		
		if !in_prompt_section { continue }
		
		// Buscar format = "..."
		if strings.has_prefix(trimmed, "format") && strings.contains(trimmed, "=") {
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
	}
	
	return cfg
}

// Genera prompt nativo simplificado pero completo
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
	
	// Función para actualizar git info
	fmt.sbprintln(&builder, "_wayu_update_git_info() {")
	fmt.sbprintln(&builder, "  if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then")
	fmt.sbprintln(&builder, `    _WAYU_GIT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)"`)
	fmt.sbprintln(&builder, `    _WAYU_GIT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)"`)
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
	format_with_newlines, _ := strings.replace_all(cfg.format, `\n`, "\n")
	defer delete(format_with_newlines)
	format_parts := strings.split(format_with_newlines, "\n")
	defer delete(format_parts)
	
	for part, i in format_parts {
		// Añadir newline antes de cada parte excepto la primera
		if i > 0 {
			fmt.sbprintln(&builder, `  result+=$'
'`)
		}
		
		if strings.contains(part, "{username}") {
			fmt.sbprintln(&builder, "  # Username (only in SSH)")
			fmt.sbprintln(&builder, `  if [[ -n "$SSH_CONNECTION" ]]; then`)
			fmt.sbprintln(&builder, `    result+="%F{7}%B%n%b%F{reset}@"`)
			fmt.sbprintln(&builder, "  fi")
			fmt.sbprintln(&builder)
		}
		
		if strings.contains(part, "{localip}") {
			fmt.sbprintln(&builder, "  # Local IP (only in SSH)")
			fmt.sbprintln(&builder, `  if [[ -n "$SSH_CONNECTION" ]]; then`)
			fmt.sbprintln(&builder, `    local ip="${$(ip route get 1 2>/dev/null | awk '{print $7; exit}')}"`)
			fmt.sbprintln(&builder, `    result+="%F{4}[$ip]%F{reset} "`)
			fmt.sbprintln(&builder, "  fi")
			fmt.sbprintln(&builder)
		}
		
		// Directory
		if strings.contains(part, "{dir}") {
			fmt.sbprintln(&builder, "  # Directory")
			fmt.sbprintln(&builder, `  result+="%F{6}%B%~%b%F{reset} "`)
			fmt.sbprintln(&builder)
		}
		
		// Git branch
		if strings.contains(part, "{git_branch}") {
			fmt.sbprintln(&builder, "  # Git branch")
			fmt.sbprintln(&builder, `  if [[ -n "$_WAYU_GIT_BRANCH" ]]; then`)
			fmt.sbprintln(&builder, `    result+="%F{5}%B${_WAYU_GIT_BRANCH}%b%F{reset} "`)
			fmt.sbprintln(&builder, "  fi")
			fmt.sbprintln(&builder)
		}
		
		// Context icon (from _WAYU_CONTEXT) con versiones
		if strings.contains(part, "{context_icon}") {
			fmt.sbprintln(&builder, "  # Context icon from Nerd Fonts (con versiones)")
			fmt.sbprintln(&builder, "  local _icon=\"\"")
			fmt.sbprintln(&builder, "  local _ver=\"$_WAYU_CONTEXT_VER\"")
			fmt.sbprintln(&builder)
			fmt.sbprintln(&builder, "  case \"$_WAYU_CONTEXT\" in")
			fmt.sbprintln(&builder, `    rust) _icon="\U000f1617" ;;`)
			fmt.sbprintln(&builder, `    nodejs) _icon="\ue718" ;;`)
			fmt.sbprintln(&builder, `    golang) _icon="\ue627" ;;`)
			fmt.sbprintln(&builder, `    python) _icon="\ue235" ;;`)
			fmt.sbprintln(&builder, `    zig) _icon="\ue6a9" ;;`)
			fmt.sbprintln(&builder, `    odin) _icon="\ue00b" ;;`)
			fmt.sbprintln(&builder, `    bun) _icon="\ue76f" ;;`)
			fmt.sbprintln(&builder, `    deno) _icon="\ue7c0" ;;`)
			fmt.sbprintln(&builder, `    ruby) _icon="\ue791" ;;`)
			fmt.sbprintln(&builder, `    elixir) _icon="\ue62d" ;;`)
			fmt.sbprintln(&builder, `    dart) _icon="\ue798" ;;`)
			fmt.sbprintln(&builder, `    java) _icon="\ue256" ;;`)
			fmt.sbprintln(&builder, `    kotlin) _icon="\ue634" ;;`)
			fmt.sbprintln(&builder, `    scala) _icon="\ue737" ;;`)
			fmt.sbprintln(&builder, `    gradle) _icon="\ue660" ;;`)
			fmt.sbprintln(&builder, `    c) _icon="\ue61e" ;;`)
			fmt.sbprintln(&builder, `    cpp) _icon="\ue61d" ;;`)
			fmt.sbprintln(&builder, `    elm) _icon="\ue62c" ;;`)
			fmt.sbprintln(&builder, `    haskell) _icon="\ue777" ;;`)
			fmt.sbprintln(&builder, `    erlang) _icon="\ue7b1" ;;`)
			fmt.sbprintln(&builder, `    ocaml) _icon="\ue67a" ;;`)
			fmt.sbprintln(&builder, `    fennel) _icon="\ue6af" ;;`)
			fmt.sbprintln(&builder, `    julia) _icon="\ue624" ;;`)
			fmt.sbprintln(&builder, `    nim) _icon="\U000f01a5" ;;`)
			fmt.sbprintln(&builder, `    crystal) _icon="\ue62f" ;;`)
			fmt.sbprintln(&builder, `    lua) _icon="\ue620" ;;`)
			fmt.sbprintln(&builder, `    perl) _icon="\ue67e" ;;`)
			fmt.sbprintln(&builder, `    php) _icon="\ue608" ;;`)
			fmt.sbprintln(&builder, `    swift) _icon="\ue755" ;;`)
			fmt.sbprintln(&builder, `    rlang) _icon="\U000f07d4" ;;`)
			fmt.sbprintln(&builder, `    nix) _icon="\uf313" ;;`)
			fmt.sbprintln(&builder, `    docker) _icon="\uf308" ;;`)
			fmt.sbprintln(&builder, `    aws) _icon="\ue33d" ;;`)
			fmt.sbprintln(&builder, `    buf) _icon="\uf49d" ;;`)
			fmt.sbprintln(&builder, `    gleam) _icon="\u2b50" ;;`)
			fmt.sbprintln(&builder, `    *) ;;`)
			fmt.sbprintln(&builder, "  esac")
			fmt.sbprintln(&builder)
			fmt.sbprintln(&builder, "  if [[ -n \"$_icon\" ]]; then")
			fmt.sbprintln(&builder, `    if [[ -n "$_ver" ]]; then`)
			fmt.sbprintln(&builder, `      result+="%F{4}$_icon $_ver%F{reset} "`)
			fmt.sbprintln(&builder, "    else")
			fmt.sbprintln(&builder, `      result+="$_icon "`)
			fmt.sbprintln(&builder, "    fi")
			fmt.sbprintln(&builder, "  fi")
			fmt.sbprintln(&builder)
		}
		
		// Git commit (solo detached HEAD)
		if strings.contains(part, "{git_commit}") {
			fmt.sbprintln(&builder, "  # Git commit (detached HEAD only)")
			fmt.sbprintln(&builder, `  if [[ -n "$_WAYU_GIT_BRANCH" ]] && [[ "$_WAYU_GIT_BRANCH" =~ ^[a-f0-9]+$ ]]; then`)
			fmt.sbprintln(&builder, `    result+="%F{3}${_WAYU_GIT_BRANCH}%F{reset} "`)
			fmt.sbprintln(&builder, "  fi")
			fmt.sbprintln(&builder)
		}
		
		// Git state (rebase, merge, cherry-pick)
		if strings.contains(part, "{git_state}") {
			fmt.sbprintln(&builder, "  # Git state")
			fmt.sbprintln(&builder, `  if [[ -d "$_WAYU_GIT_DIR/rebase-merge" ]] || [[ -d "$_WAYU_GIT_DIR/rebase-apply" ]]; then`)
			fmt.sbprintln(&builder, `    result+="%F{1}REBASING%F{reset} "`)
			fmt.sbprintln(&builder, `  elif [[ -f "$_WAYU_GIT_DIR/MERGE_HEAD" ]]; then`)
			fmt.sbprintln(&builder, `    result+="%F{1}MERGING%F{reset} "`)
			fmt.sbprintln(&builder, `  elif [[ -f "$_WAYU_GIT_DIR/CHERRY_PICK_HEAD" ]]; then`)
			fmt.sbprintln(&builder, `    result+="🍒 %F{1}PICKING%F{reset} "`)
			fmt.sbprintln(&builder, "  fi")
			fmt.sbprintln(&builder)
		}
		
		// Odin
		if strings.contains(part, "{odin}") {
			fmt.sbprintln(&builder, "  # Odin")
			fmt.sbprintln(&builder, `  if [[ -f "ols.json" ]] || ls *.odin >/dev/null 2>&1; then`)
			fmt.sbprintln(&builder, `    local ver="$(odin version 2>/dev/null | head -1 | awk '{print $3}')"`)
			fmt.sbprintln(&builder, `    if [[ -n "$ver" ]]; then`)
			fmt.sbprintln(&builder, `      result+="via %F{4} ${ver}%F{reset} "`)
			fmt.sbprintln(&builder, "    fi")
			fmt.sbprintln(&builder, "  fi")
			fmt.sbprintln(&builder)
		}
		
		// Character (success/error/vi-mode)
		if strings.contains(part, "{character}") {
			fmt.sbprintln(&builder, "  # Character (success/error with VI mode support)")
			fmt.sbprintln(&builder, "  local char_symbol char_color")
			
			// Determinar símbolo según modo VI
			fmt.sbprintln(&builder, "  case \"$_WAYU_VI_MODE\" in")
			fmt.sbprintln(&builder, "    INSERT)")
			fmt.sbprint(&builder, `      char_symbol="`)
			fmt.sbprint(&builder, cfg.character_success)
			fmt.sbprintln(&builder, `" ;;`)
			fmt.sbprintln(&builder, "    NORMAL)")
			fmt.sbprint(&builder, `      char_symbol="`)
			fmt.sbprint(&builder, cfg.vimcmd_symbol)
			fmt.sbprintln(&builder, `" ;;`)
			fmt.sbprintln(&builder, "    VISUAL)")
			fmt.sbprint(&builder, `      char_symbol="`)
			fmt.sbprint(&builder, cfg.vimcmd_symbol)  // mismo peso visual que NORMAL, color lo diferencia
			fmt.sbprintln(&builder, `" ;;`)
			fmt.sbprintln(&builder, "    REPLACE|REPLACE_ONE)")
			fmt.sbprint(&builder, `      char_symbol="`)
			fmt.sbprint(&builder, cfg.vimcmd_replace_symbol)
			fmt.sbprintln(&builder, `" ;;`)
			fmt.sbprintln(&builder, "    *)")
			fmt.sbprintln(&builder, "      # Fallback: usar exit code")
			fmt.sbprintln(&builder, "      if [[ ${_WAYU_LAST_EXIT:-0} -eq 0 ]]; then")
			fmt.sbprint(&builder, `        char_symbol="`)
			fmt.sbprint(&builder, cfg.character_success)
			fmt.sbprintln(&builder, `"`)
			fmt.sbprintln(&builder, "      else")
			fmt.sbprint(&builder, `        char_symbol="`)
			fmt.sbprint(&builder, cfg.character_error)
			fmt.sbprintln(&builder, `"`)
			fmt.sbprintln(&builder, "      fi")
			fmt.sbprintln(&builder, "    ;;")
			fmt.sbprintln(&builder, "  esac")
			
			// Color según modo VI (configuración del usuario)
			fmt.sbprintln(&builder, "  case \"$_WAYU_VI_MODE\" in")
			fmt.sbprintln(&builder, `    INSERT) char_color="202" ;;`)   // Naranja 256-color para insert
			fmt.sbprintln(&builder, `    NORMAL) char_color="2" ;;`)     // Verde para normal
			fmt.sbprintln(&builder, `    VISUAL) char_color="129" ;;`)      // Purple 256-color para visual
			fmt.sbprintln(&builder, `    REPLACE|REPLACE_ONE) char_color="129" ;;`) // Purple para replace
			fmt.sbprintln(&builder, `    *)`)
			fmt.sbprintln(&builder, "      # Fallback: usar exit code")
			fmt.sbprintln(&builder, "      if [[ ${_WAYU_LAST_EXIT:-0} -eq 0 ]]; then")
			fmt.sbprintln(&builder, `        char_color="2"`)
			fmt.sbprintln(&builder, "      else")
			fmt.sbprintln(&builder, `        char_color="1"`)
			fmt.sbprintln(&builder, "      fi")
			fmt.sbprintln(&builder, `    ;;`)
			fmt.sbprintln(&builder, "  esac")
			
			fmt.sbprintln(&builder, `  result+="%F{${char_color}}%B${char_symbol}%b%F{reset} "`)
			fmt.sbprintln(&builder)
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
