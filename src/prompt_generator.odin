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
}

// Parse config simple desde TOML
parse_full_prompt_config :: proc(toml: string) -> PromptConfigFull {
	cfg := PromptConfigFull{
		format = "{username}{dir}{git_branch}{character}",
		character_success = "➜",
		character_error = "✗",
	}
	
	lines := strings.split(toml, "\n")
	defer delete(lines)
	
	in_prompt_section := false
	
	for line in lines {
		trimmed := strings.trim_space(line)
		
		// Detectar sección [prompt]
		if trimmed == "[prompt]" {
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
	
	// Función principal de prompt
	fmt.sbprintln(&builder, "_wayu_prompt() {")
	fmt.sbprintln(&builder, "  local exit_code=$?")
	fmt.sbprintln(&builder, `  local result=""`)
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
			fmt.sbprintln(&builder, `    result+="🌱 %F{5}%B${_WAYU_GIT_BRANCH}%b%F{reset} "`)
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
			fmt.sbprintln(&builder, `    local ver="$(odin version 2>/dev/null | head -1 | awk '{print $2}')"`)
			fmt.sbprintln(&builder, `    if [[ -n "$ver" ]]; then`)
			fmt.sbprintln(&builder, `      result+="via %F{4}󰹩 ${ver}%F{reset} "`)
			fmt.sbprintln(&builder, "    fi")
			fmt.sbprintln(&builder, "  fi")
			fmt.sbprintln(&builder)
		}
		
		// Character (success/error)
		if strings.contains(part, "{character}") {
			fmt.sbprintln(&builder, "  # Character (success/error)")
			fmt.sbprintln(&builder, "  if [[ $exit_code -eq 0 ]]; then")
		// Usar símbolos directamente sin format
		fmt.sbprint(&builder, `    result+="%F{2}%B`)
		fmt.sbprint(&builder, cfg.character_success)
		fmt.sbprintln(&builder, `%b%F{reset} "`)
		fmt.sbprintln(&builder, "  else")
		fmt.sbprint(&builder, `    result+="%F{1}%B`)
		fmt.sbprint(&builder, cfg.character_error)
		fmt.sbprintln(&builder, `%b%F{reset} "`)
		fmt.sbprintln(&builder, "  fi")
		fmt.sbprintln(&builder)
	}
	}  // Cierre del for loop
	
	// Output final
	fmt.sbprintln(&builder, `  echo "$result"`)
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)
	
	// Configurar PROMPT
	fmt.sbprintln(&builder, "setopt promptsubst")
	fmt.sbprintln(&builder, `PROMPT='$(_wayu_prompt)'`)
	fmt.sbprintln(&builder, "unset RPROMPT")
	
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
