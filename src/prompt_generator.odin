// prompt_generator.odin - Genera prompt nativo zsh pre-compilado
package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// Configuración del prompt
PromptConfig :: struct {
	format:           string,
	symbols_success:  string,
	symbols_error:    string,
	colors_directory: string,
	colors_git_branch: string,
	colors_symbol_success: string,
	colors_symbol_error: string,
}

// Genera prompt nativo zsh desde configuración
generate_native_prompt :: proc(config: PromptConfig) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)
	
	// Función de prompt nativa
	fmt.sbprintln(&builder, "# === Wayu Native Prompt (pre-compiled) ===")
	fmt.sbprintln(&builder, "_wayu_prompt() {")
	fmt.sbprintln(&builder, "  local exit_code=$?")
	fmt.sbprintln(&builder, "  local dir=\"%~\"")
	fmt.sbprintln(&builder, "  local git_branch=\"\"")
	fmt.sbprintln(&builder, "  local git_status=\"\"")
	fmt.sbprintln(&builder)
	
	// Git branch (fast check)
	fmt.sbprintln(&builder, "  # Fast git branch detection")
	fmt.sbprintln(&builder, "  if git rev-parse --git-dir > /dev/null 2>&1; then")
	fmt.sbprintln(&builder, "    git_branch=\"$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)\"")
	fmt.sbprint(&builder, "    [[ -n \"$git_branch\" ]] && git_branch=\"")
	fmt.sbprint(&builder, color_to_code(config.colors_git_branch))
	fmt.sbprintln(&builder, "($git_branch)%f\"")
	fmt.sbprintln(&builder, "  fi")
	fmt.sbprintln(&builder)
	
	// Symbol basado en exit code
	fmt.sbprintln(&builder, "  # Success/error symbol")
	fmt.sbprintln(&builder, "  local symbol")
	fmt.sbprintln(&builder, "  if [[ $exit_code -eq 0 ]]; then")
	fmt.sbprintfln(&builder, "    symbol=\"%s%s\"", color_to_code(config.colors_symbol_success), config.symbols_success)
	fmt.sbprintln(&builder, "  else")
	fmt.sbprintfln(&builder, "    symbol=\"%s%s\"", color_to_code(config.colors_symbol_error), config.symbols_error)
	fmt.sbprintln(&builder, "  fi")
	fmt.sbprintln(&builder)
	
	// Construir prompt
	fmt.sbprintln(&builder, "  # Build prompt")
	fmt.sbprint(&builder, "  echo \"")
	
	// Procesar format string manualmente
	parts := strings.split(config.format, " ")
	defer delete(parts)
	
	for part in parts {
		switch part {
		case "{dir}":
			fmt.sbprint(&builder, color_to_code(config.colors_directory))
			fmt.sbprint(&builder, "%~%f ")
		case "{git_branch}":
			fmt.sbprint(&builder, "${git_branch} ")
		case "{symbol}":
			fmt.sbprint(&builder, "${symbol}%f ")
		case "{exit_status}":
			fmt.sbprint(&builder, "${exit_code} ")
		case:
			fmt.sbprint(&builder, part)
			fmt.sbprint(&builder, " ")
		}
	}
	
	fmt.sbprintln(&builder, "\"")
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)
	
	// Configurar PROMPT
	fmt.sbprintln(&builder, "setopt promptsubst")
	fmt.sbprintln(&builder, "PROMPT='$(_wayu_prompt)'")
	fmt.sbprintln(&builder, "unset RPROMPT  # Clean right prompt")
	
	return strings.clone(strings.to_string(builder))
}

// Convierte nombre de color a código ANSI zsh
color_to_code :: proc(color: string) -> string {
	switch strings.to_lower(color) {
	case "black":   return "%F{0}"
	case "red":     return "%F{1}"
	case "green":   return "%F{2}"
	case "yellow":  return "%F{3}"
	case "blue":    return "%F{4}"
	case "magenta": return "%F{5}"
	case "cyan":    return "%F{6}"
	case "white":   return "%F{7}"
	case "gray", "grey": return "%F{8}"
	case "default": return "%f"
	case "reset":   return "%f"
	case:
		// Si es un número (0-255), usar directamente
		if is_numeric(color) {
			return fmt.aprintf("%%F{%s}", color)
		}
		return "%f"  // default
	}
}

is_numeric :: proc(s: string) -> bool {
	for c in s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return len(s) > 0
}

// Parsea prompt config desde TOML (simplificado)
parse_prompt_config :: proc(toml_data: string) -> PromptConfig {
	config := PromptConfig{
		format = "{dir} {git_branch} {symbol} ",
		symbols_success = "➜",
		symbols_error = "✗",
		colors_directory = "cyan",
		colors_git_branch = "magenta",
		colors_symbol_success = "green",
		colors_symbol_error = "red",
	}
	
	// Parse simple: buscar [prompt] section
	lines := strings.split(toml_data, "\n")
	defer delete(lines)
	
	in_prompt_section := false
	for line in lines {
		trimmed := strings.trim_space(line)
		
		// Detectar inicio de sección
		if strings.contains(trimmed, "[prompt]") && !strings.contains(trimmed, "[prompt.") {
			in_prompt_section = true
			continue
		}
		if strings.has_prefix(trimmed, "[") && in_prompt_section {
			in_prompt_section = false
			continue
		}
		
		if !in_prompt_section { continue }
		
		// Parsear key = value
		eq_idx := strings.index(trimmed, "=")
		if eq_idx > 0 {
			key := strings.trim_space(trimmed[:eq_idx])
			value := strings.trim_space(trimmed[eq_idx+1:])
			
			// Remover comillas
			value = strings.trim_prefix(value, `"`)
			value = strings.trim_suffix(value, `"`)
			value = strings.trim_prefix(value, "'")
			value = strings.trim_suffix(value, "'")
			
			switch key {
			case "format": config.format = value
			}
		}
		
		// Parsear subsecciones [prompt.symbols], [prompt.colors]
		if strings.contains(trimmed, "[prompt.symbols]") {
			in_prompt_section = false  // Cambiar a subsección
		}
	}
	
	return config
}
