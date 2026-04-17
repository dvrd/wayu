// init_generator.odin - Genera init optimizado con todas las técnicas
package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// Técnica 1: zsh-defer propio (no requiere plugin externo)
// Técnica 2: zcompile bytecode
// Técnica 3: batch exports (typeset -gx)
// Técnica 4: evalcache para tools
// Técnica 5: compinit optimizado (24h cache)
// Técnica 6: split files (core/lazy/login)

// Genera todos los archivos de init optimizados (versión v2 con todas las optimizaciones)
generate_optimized_init_all :: proc() {
	// 1. Core - Esencial para el prompt (PATH, prompt básico)
	generate_core_init_v2()
	
	// 2. Lazy - Plugins, tools, completions (via zsh-defer propio)
	generate_lazy_init_v2()
	
	// 3. Login - Solo para shells de login (NVM, etc.)
	generate_login_init_v2()
	
	// 4. Helper functions (evalcache, zsh-defer propio, etc.)
	generate_helpers_init_v2()

	// 5. Runtime plugin config generated from wayu.toml
	_ = generate_plugins_runtime_config(DETECTED_SHELL)
	
	fmt.println("# Init files generados:")
	fmt.printfln("#   %s/init-core.zsh  (menos de 10ms)", WAYU_CONFIG)
	fmt.printfln("#   %s/init-lazy.zsh   (deferred via zsh-defer propio)", WAYU_CONFIG)
	fmt.printfln("#   %s/init-login.zsh  (login only)", WAYU_CONFIG)
	fmt.printfln("#   %s/init-helpers.zsh (evalcache, zsh-defer propio)", WAYU_CONFIG)
	fmt.println("#")
	fmt.println("# Para compilar a bytecode (2-3x mas rapido):")
	fmt.println("#   zcompile ~/.config/wayu/init-core.zsh")
	fmt.println("#   zcompile ~/.config/wayu/init-lazy.zsh")
	fmt.println("#")
	fmt.println("# NOTA: wayu incluye zsh-defer propio, no requiere plugin externo")
}

// Core: Solo lo esencial para que aparezca el prompt (menos de 10ms)
generate_core_init_v2 :: proc() {
	shell_ext := get_shell_extension(DETECTED_SHELL)
	path := fmt.aprintf("%s/init-core.%s", WAYU_CONFIG, shell_ext)
	defer delete(path)

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	// Use correct shebang for shell type
	shebang := "#!/usr/bin/env zsh"
	if DETECTED_SHELL == .BASH {
		shebang = "#!/usr/bin/env bash"
	} else if DETECTED_SHELL == .FISH {
		shebang = "#!/usr/bin/env fish"
	}
	fmt.sbprintln(&builder, shebang)

	init_file_name := fmt.aprintf("init-core.%s", shell_ext)
	fmt.sbprintfln(&builder, "# %s - ESENCIAL (menos de 10ms)", init_file_name)
	delete(init_file_name)
	fmt.sbprintln(&builder, "# Generado automáticamente por wayu build")
	fmt.sbprintln(&builder)

	// PATH leído dinámicamente desde [[paths]] en wayu.toml
	fmt.sbprintln(&builder, "# === PATH ===")
	toml_paths := read_wayu_toml_paths()
	defer {
		for p in toml_paths { delete(p) }
		delete(toml_paths)
	}
	if len(toml_paths) > 0 {
		fmt.sbprint(&builder, "export PATH=\"")
		for p, i in toml_paths {
			if i > 0 { fmt.sbprint(&builder, ":") }
			fmt.sbprint(&builder, p)
		}
		fmt.sbprintln(&builder, ":$PATH\"")
	} else {
		source_file := fmt.aprintf("$HOME/.config/wayu/path.%s", shell_ext)
		fmt.sbprintfln(&builder, `source "%s"`, source_file)
		delete(source_file)
	}

	// Deduplicación de PATH - usar syntax correcta por shell type
	fmt.sbprintln(&builder, "# Deduplicate PATH (preserva orden, elimina duplicados)")
	if DETECTED_SHELL == .ZSH {
		fmt.sbprintln(&builder, "typeset -U path PATH")
	} else if DETECTED_SHELL == .BASH {
		// Bash doesn't have typeset -U, use a different dedup method
		fmt.sbprintln(&builder, `# Bash PATH deduplication`)
		fmt.sbprintln(&builder, `export PATH=$(echo "$PATH" | tr ':' '\n' | nl | sort -uk2 | sort -n | cut -f2- | tr '\n' ':' | sed 's/:$//g')`)
	} else if DETECTED_SHELL == .FISH {
		// Fish handles PATH specially
		fmt.sbprintln(&builder, `# Fish PATH deduplication`)
		fmt.sbprintln(&builder, `set -U fish_user_paths (printf '%s\n' $fish_user_paths | awk '!seen[$0]++')`)
	}
	fmt.sbprintln(&builder)
	
	// Batch exports esenciales (una sola línea)
	// Environment desde wayu.toml [env]
	fmt.sbprintln(&builder, "# === Environment (from wayu.toml [env]) ===")
	toml_env := read_wayu_toml_env()
defer {
		for e in toml_env { delete(e.name); delete(e.value) }
		delete(toml_env)
	}
	for e in toml_env {
		// Expand $HOME to literal for export compatibility
		home := os.get_env_alloc("HOME", context.allocator)
		defer delete(home)
		if len(home) == 0 { home = os.get_env_alloc("HOME", context.temp_allocator) }
		expanded, _ := strings.replace_all(e.value, "$HOME", home)
		fmt.sbprint(&builder, "export ")
		fmt.sbprint(&builder, e.name)
		fmt.sbprint(&builder, `="`)
		fmt.sbprint(&builder, expanded)
		fmt.sbprintln(&builder, `"`)
	}
	fmt.sbprintln(&builder)
	
	// Aliases desde wayu.toml [[aliases]]
	fmt.sbprintln(&builder, "# === Aliases (from wayu.toml [[aliases]]) ===")
	toml_aliases := read_wayu_toml_aliases()
	defer {
		for a in toml_aliases { delete(a.name); delete(a.command) }
		delete(toml_aliases)
	}
	for a in toml_aliases {
		fmt.sbprint(&builder, "alias ")
		fmt.sbprint(&builder, a.name)
		fmt.sbprint(&builder, `="`)
		fmt.sbprint(&builder, a.command)
		fmt.sbprintln(&builder, `"`)
	}
	fmt.sbprintln(&builder)

	// Shell wrapper para wayu: intercepta "path add" y exporta al shell actual
	fmt.sbprintln(&builder, "# === wayu shell wrapper ===")
	fmt.sbprintln(&builder, "wayu() {")
	fmt.sbprintln(&builder, "  command wayu \"$@\"")
	fmt.sbprintln(&builder, "  local _exit=$?")
	fmt.sbprintln(&builder, "  if [[ $_exit -eq 0 && \"$1\" == \"path\" && \"$2\" == \"add\" ]]; then")
	fmt.sbprintln(&builder, "    command wayu build eval > /dev/null 2>&1")
	fmt.sbprintln(&builder, "    export PATH=\"${3}:$PATH\"")
	fmt.sbprintln(&builder, "  fi")
	fmt.sbprintln(&builder, "  return $_exit")
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)
	
	// Completions (necesario para autocomplete)
	fmt.sbprintln(&builder, "# === Completions ===")
	fmt.sbprintln(&builder, "fpath=(\"$HOME/.config/wayu/completions\" $fpath)")
	fmt.sbprintln(&builder, "autoload -Uz compinit && compinit -C")
	fmt.sbprintln(&builder)
	
	// Plugins críticos (autocomplete, autosuggestions) - NO deferred
	fmt.sbprintln(&builder, "# === Plugins críticos (inmediato) ===")
	fmt.sbprintln(&builder, "[ -f \"$HOME/.config/wayu/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh\" ] && source \"$HOME/.config/wayu/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh\"")
	fmt.sbprintln(&builder, "[ -f \"$HOME/.config/wayu/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh\" ] && source \"$HOME/.config/wayu/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh\"")
	fmt.sbprintln(&builder, "[ -f \"$HOME/.config/wayu/plugins/config.zsh\" ] && source \"$HOME/.config/wayu/plugins/config.zsh\"")
	fmt.sbprintln(&builder)
	
	// User configuration from config.zsh
	config_zsh := fmt.aprintf("%s/config.zsh", WAYU_CONFIG)
	defer delete(config_zsh)
	
	if os.exists(config_zsh) {
		content, ok := safe_read_file(config_zsh)
		if ok && len(content) > 0 {
			fmt.sbprintln(&builder, "# === User configuration (from config.zsh) ===")
			fmt.sbprintln(&builder, string(content))
			fmt.sbprintln(&builder)
		}
	}
	
	// Load helpers (para zsh-defer y utilidades)
	fmt.sbprintln(&builder, "# === Load helpers (zsh-defer propio) ===")
	fmt.sbprintfln(&builder, "source \"%s/init-helpers.zsh\" 2>/dev/null || true", WAYU_CONFIG)
	fmt.sbprintln(&builder)
	
	// Prompt: Nativo wayu completo (copied from starship.toml)
	// Ahora con features interactivas
	fmt.sbprintln(&builder, "# === Prompt (wayu native, interactive) ===")
	
	// Parse configs from TOML
	toml_path := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG)
	defer delete(toml_path)
	
	if os.exists(toml_path) {
		toml_data, ok := safe_read_file(toml_path)
		if ok {
			defer delete(toml_data)
			
			// Base prompt
			prompt_cfg := parse_full_prompt_config(string(toml_data))
			base_prompt := generate_full_prompt(prompt_cfg)
			
			// Interactive features
			interactive_cfg := parse_interactive_config(string(toml_data))
			interactive_code := generate_interactive_prompt(base_prompt, interactive_cfg)
			
			fmt.sbprint(&builder, interactive_code)
			delete(base_prompt)
			delete(interactive_code)
		}
	}
	fmt.sbprintln(&builder)
	
	// Defer resto (completions, tools, etc.)
	fmt.sbprintln(&builder, "# === Deferred loading (lazy init) ===")
	fmt.sbprintln(&builder, "[[ -z \"$_WAYU_LAZY_LOADED\" ]] && {")
	fmt.sbprintln(&builder, "  export _WAYU_LAZY_LOADED=1")
	fmt.sbprintfln(&builder, "  zsh-defer source \"%s/init-lazy.zsh\"", WAYU_CONFIG)
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)
	
	// Login shell extras (|| true para que no falle en non-login shells)
	fmt.sbprintln(&builder, "# === Login shell ===")
	fmt.sbprintfln(&builder, "[[ -o login ]] && source \"%s/init-login.zsh\" 2>/dev/null || true", WAYU_CONFIG)
	fmt.sbprintln(&builder)
	
	content := strings.to_string(builder)
	_ = os.write_entire_file(path, transmute([]byte)content)
}

// Lazy: Plugins, tools, completions (carga diferida via zsh-defer)
generate_lazy_init_v2 :: proc() {
	path := fmt.aprintf("%s/init-lazy.zsh", WAYU_CONFIG)
	defer delete(path)
	
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)
	
	fmt.sbprintln(&builder, "#!/usr/bin/env zsh")
	fmt.sbprintln(&builder, "# init-lazy.zsh - CARGA DIFERIDA")
	fmt.sbprintln(&builder)
	
	// Tools con evalcache
	fmt.sbprintln(&builder, "# === Tools (evalcached) ===")
	fmt.sbprintln(&builder, "_wayu_evalcache zoxide init zsh")
	fmt.sbprintln(&builder, "_wayu_evalcache atuin init zsh --disable-up-arrow")
	fmt.sbprintln(&builder)
	
	// Tools con evalcache
	fmt.sbprintln(&builder, "# === Tools (evalcached) ===")
	fmt.sbprintln(&builder, "_wayu_evalcache zoxide init zsh")
	fmt.sbprintln(&builder, "_wayu_evalcache atuin init zsh --disable-up-arrow")
	fmt.sbprintln(&builder)
	
	// Environment ya exportado en init-core.zsh desde wayu.toml [env]
	fmt.sbprintln(&builder)
	
	// Aliases ya exportados en init-core.zsh desde wayu.toml [[aliases]]
	fmt.sbprintln(&builder)
	fmt.sbprintln(&builder)
	
	// Extra config
	fmt.sbprintln(&builder, "# === Extra config ===")
	fmt.sbprintln(&builder, "[ -f \"$HOME/.config/wayu/extra.zsh\" ] && source \"$HOME/.config/wayu/extra.zsh\"")
	fmt.sbprintln(&builder)
	
	content := strings.to_string(builder)
	_ = os.write_entire_file(path, transmute([]byte)content)
}

// Login: Solo para shells de login (heavy tools)
generate_login_init_v2 :: proc() {
	path := fmt.aprintf("%s/init-login.zsh", WAYU_CONFIG)
	defer delete(path)
	
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)
	
	fmt.sbprintln(&builder, "#!/usr/bin/env zsh")
	fmt.sbprintln(&builder, "# init-login.zsh - LOGIN SHELL ONLY")
	fmt.sbprintln(&builder, "# NVM, Conda, SDKMAN lazy loaders")
	fmt.sbprintln(&builder)
	
	// tools.zsh contiene los lazy loaders pesados
	fmt.sbprintln(&builder, "[ -f \"$HOME/.config/wayu/tools.zsh\" ] && source \"$HOME/.config/wayu/tools.zsh\"")
	fmt.sbprintln(&builder)
	
	content := strings.to_string(builder)
	_ = os.write_entire_file(path, transmute([]byte)content)
}

// Helpers: Funciones de soporte (evalcache, zsh-defer propio, etc.)
generate_helpers_init_v2 :: proc() {
	path := fmt.aprintf("%s/init-helpers.zsh", WAYU_CONFIG)
	defer delete(path)
	
	helper := `# init-helpers.zsh - Funciones de soporte para wayu

# ============================================================================
# EVALCACHE - Cachea output de eval, regenera si el binario cambió
# ============================================================================
_wayu_evalcache() {
  local cmd="$1"
  shift
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/wayu/evalcache"
  local cache_file="$cache_dir/${cmd//\//_}"
  local bin_path="$(command -v $cmd 2>/dev/null)"
  
  [[ -d "$cache_dir" ]] || mkdir -p "$cache_dir"
  
  # Regenerar si: no existe cache, o binario es más nuevo que cache
  if [[ ! -f "$cache_file" ]] || [[ "$bin_path" -nt "$cache_file" ]]; then
    "$cmd" "$@" > "$cache_file" 2>/dev/null
  fi
  
  [[ -f "$cache_file" ]] && source "$cache_file"
}

# ============================================================================
# ZSH-DEFER PROPIO - Implementación sin plugin externo
# Difiere ejecución hasta que el prompt esté listo y idle
# ============================================================================

# Cola de comandos diferidos
(( ${+_wayu_defer_queue} )) || typeset -a _wayu_defer_queue

# Función principal zsh-defer
zsh-defer() {
  local delay=0
  
  # Parsear opciones
  while [[ "$1" == -* ]]; do
    case "$1" in
      -t|--time) delay="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  
  # Agregar a la cola
  local cmd="$*"
  [[ -n "$cmd" ]] && _wayu_defer_queue+=("$cmd:$delay")
}

# Procesar un comando diferido
_wayu_defer_process_one() {
  [[ ${#_wayu_defer_queue} -eq 0 ]] && return 0
  
  local item="${_wayu_defer_queue[1]}"
  local cmd="${item%:*}"
  local delay="${item##*:}"
  
  shift _wayu_defer_queue
  
  # Ejecutar
  if [[ "$delay" != "0" && "$delay" != "" ]]; then
    (sleep "$delay" && eval "$cmd") &
  else
    eval "$cmd" 2>/dev/null
  fi
  
  return ${#_wayu_defer_queue}
}

# Hook precmd - ejecuta diferidos después del primer prompt
_wayu_defer_precmd() {
  [[ ${#_wayu_defer_queue} -eq 0 ]] && return
  
  # Ejecutar primero inmediatamente
  _wayu_defer_process_one
  
  # Si quedan más, programar para ejecutar entre comandos
  if [[ ${#_wayu_defer_queue} -gt 0 ]]; then
    # Usar un pequeño truco: TMOUT con trap
    ( sleep 0.1 && kill -USR1 $$ 2>/dev/null ) &
  fi
}

# Signal handler para continuar procesando
trap '_wayu_defer_process_one' USR1

# Instalar hook
autoload -Uz add-zsh-hook
add-zsh-hook precmd _wayu_defer_precmd

# ============================================================================
# WAYU COMPILE - Compilar init files a bytecode (comando manual)
# ============================================================================
wayu_compile() {
  echo "Compilando init files a bytecode..."
  zcompile ~/.config/wayu/init-core.zsh 2>/dev/null && echo "✓ init-core.zsh"
  zcompile ~/.config/wayu/init-lazy.zsh 2>/dev/null && echo "✓ init-lazy.zsh"
  zcompile ~/.config/wayu/init-login.zsh 2>/dev/null && echo "✓ init-login.zsh"
  echo "Done. Carga 2-3x más rápido."
}
`
	
	_ = os.write_entire_file(path, transmute([]byte)helper)
}

// Lee los [[paths]] de wayu.toml y retorna la lista de rutas
read_wayu_toml_paths :: proc() -> [dynamic]string {
	config_path := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG)
	defer delete(config_path)

	content, ok := safe_read_file(config_path)
	if !ok { return make([dynamic]string) }
	defer delete(content)

	paths := make([dynamic]string)
	lines := strings.split(string(content), "\n")
	defer delete(lines)

	in_paths_section := false
	for line in lines {
		trimmed := strings.trim_space(line)

		if trimmed == "[[paths]]" {
			in_paths_section = true
			continue
		}

		// Cualquier otro header termina la sección actual
		if strings.has_prefix(trimmed, "[") {
			in_paths_section = false
			continue
		}

		if in_paths_section && strings.has_prefix(trimmed, "path = ") {
			value := strings.trim_space(trimmed[7:])
			if len(value) >= 2 && value[0] == '"' && value[len(value)-1] == '"' {
				p := value[1 : len(value)-1]
				if os.exists(p) {
					append(&paths, strings.clone(p))
				} else {
					fmt.eprintf("wayu: warning: path does not exist, skipping: %s\n", p)
				}
				in_paths_section = false
			}
		}
	}

	return paths
}


// Lee las variables [env] de wayu.toml y retorna lista de (nombre, valor)
EnvEntry :: struct {
	name: string,
	value: string,
}

read_wayu_toml_env :: proc() -> [dynamic]EnvEntry {
	config_path := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG)
	defer delete(config_path)

	content, ok := safe_read_file(config_path)
	if !ok { return make([dynamic]EnvEntry) }
	defer delete(content)

	entries := make([dynamic]EnvEntry)
	lines := strings.split(string(content), "\n")
	defer delete(lines)

	in_env := false
	for line in lines {
		trimmed := strings.trim_space(line)

		if trimmed == "[env]" {
			in_env = true
			continue
		}

		// Cualquier otro header termina [env]
		if strings.has_prefix(trimmed, "[") {
			in_env = false
			continue
		}

		if !in_env { continue }
		if strings.has_prefix(trimmed, "#") { continue }

		eq_idx := strings.index(trimmed, "=")
		if eq_idx < 1 { continue }

		name := strings.trim_space(trimmed[:eq_idx])
		value := strings.trim_space(trimmed[eq_idx+1:])

		// Remove quotes
		value = strings.trim_prefix(value, `"`)
		value = strings.trim_suffix(value, `"`)
		value = strings.trim_prefix(value, "'")
		value = strings.trim_suffix(value, "'")

		if len(name) > 0 && len(value) > 0 {
			append(&entries, EnvEntry{
				name = strings.clone(name),
				value = strings.clone(value),
			})
		}
	}

	return entries
}

// Lee los aliases de wayu.toml y retorna lista de (nombre, comando)
// Soporta ambos formatos: [aliases] tabla y [[aliases]] array of tables.
// Uses AliasEntry from output.odin
read_wayu_toml_aliases :: proc() -> [dynamic]AliasEntry {
	config_path := fmt.aprintf("%s/wayu.toml", WAYU_CONFIG)
	defer delete(config_path)

	content, ok := safe_read_file(config_path)
	if !ok { return make([dynamic]AliasEntry) }
	defer delete(content)

	entries := make([dynamic]AliasEntry)
	lines := strings.split(string(content), "\n")
	defer delete(lines)

	in_alias_table := false
	in_alias_array := false
	current_name := ""
	current_cmd := ""

	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") {
			continue
		}

		if trimmed == "[aliases]" {
			if len(current_name) > 0 {
				append(&entries, AliasEntry{
					name = strings.clone(current_name),
					command = strings.clone(current_cmd),
				})
			}
			current_name = ""
			current_cmd = ""
			in_alias_table = true
			in_alias_array = false
			continue
		}
		if trimmed == "[[aliases]]" {
			if len(current_name) > 0 {
				append(&entries, AliasEntry{
					name = strings.clone(current_name),
					command = strings.clone(current_cmd),
				})
			}
			current_name = ""
			current_cmd = ""
			in_alias_table = false
			in_alias_array = true
			continue
		}

		if strings.has_prefix(trimmed, "[") {
			if len(current_name) > 0 {
				append(&entries, AliasEntry{
					name = strings.clone(current_name),
					command = strings.clone(current_cmd),
				})
			}
			current_name = ""
			current_cmd = ""
			in_alias_table = false
			in_alias_array = false
			continue
		}

		eq_idx := strings.index(trimmed, "=")
		if eq_idx < 1 { continue }

		name := strings.trim_space(trimmed[:eq_idx])
		val := strings.trim_space(trimmed[eq_idx+1:])
		val = strings.trim_prefix(val, `"`)
		val = strings.trim_suffix(val, `"`)
		val = strings.trim_prefix(val, "'")
		val = strings.trim_suffix(val, "'")

		if in_alias_table {
			append(&entries, AliasEntry{
				name = strings.clone(name),
				command = strings.clone(val),
			})
			continue
		}

		if in_alias_array {
			switch name {
			case "name":
				current_name = val
			case "command":
				current_cmd = val
			}
		}
	}

	if len(current_name) > 0 {
		append(&entries, AliasEntry{
			name = strings.clone(current_name),
			command = strings.clone(current_cmd),
		})
	}
	return entries
}
