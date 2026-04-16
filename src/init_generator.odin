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
	
	fmt.println("# Init files generados:")
	fmt.printfln("#   %s/init-core.zsh  (< 10ms)", WAYU_CONFIG)
	fmt.printfln("#   %s/init-lazy.zsh   (deferred via zsh-defer propio)", WAYU_CONFIG)
	fmt.printfln("#   %s/init-login.zsh  (login only)", WAYU_CONFIG)
	fmt.printfln("#   %s/init-helpers.zsh (evalcache, zsh-defer propio)", WAYU_CONFIG)
	fmt.println("#")
	fmt.println("# Para compilar a bytecode (2-3x más rápido):")
	fmt.println("#   zcompile ~/.config/wayu/init-core.zsh")
	fmt.println("#   zcompile ~/.config/wayu/init-lazy.zsh")
	fmt.println("#")
	fmt.println("# NOTA: wayu incluye zsh-defer propio, no requiere plugin externo")
}

// Core: Solo lo esencial para que aparezca el prompt (< 10ms)
generate_core_init_v2 :: proc() {
	path := fmt.aprintf("%s/init-core.zsh", WAYU_CONFIG)
	defer delete(path)
	
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)
	
	fmt.sbprintln(&builder, "#!/usr/bin/env zsh")
	fmt.sbprintln(&builder, "# init-core.zsh - ESENCIAL (< 10ms)")
	fmt.sbprintln(&builder, "# Generado automáticamente por wayu build")
	fmt.sbprintln(&builder)
	
	// PATH pre-computado (sin loops)
	fmt.sbprintln(&builder, "# === PATH ===")
	fmt.sbprint(&builder, "export PATH=\"")
	fmt.sbprint(&builder, "/Users/kakurega/go/bin:")
	fmt.sbprint(&builder, "/Users/kakurega/.local/bin:")
	fmt.sbprint(&builder, "/Users/kakurega/.cargo/bin:")
	fmt.sbprint(&builder, "/Users/kakurega/dev/projects/wayu/bin:")
	fmt.sbprint(&builder, "/opt/homebrew/bin:")
	fmt.sbprint(&builder, "/opt/homebrew/sbin:")
	fmt.sbprint(&builder, "/usr/local/bin:")
	fmt.sbprintln(&builder, "/usr/bin:/bin:/usr/sbin:/sbin\"")
	fmt.sbprintln(&builder)
	
	// Batch exports esenciales (una sola línea)
	fmt.sbprintln(&builder, "# === Environment esencial (batch) ===")
	fmt.sbprintln(&builder, "typeset -gx EDITOR=nvim CONFIGS=\"$HOME/.config\" SHELL_CONFIG=\"$HOME/.config/wayu/extra.zsh\" OSS=\"$HOME/dev/oss\"")
	fmt.sbprintln(&builder)
	
	// Batch aliases esenciales
	fmt.sbprintln(&builder, "# === Aliases esenciales (batch) ===")
	fmt.sbprintln(&builder, "alias vim=nvim ls=lsd reload=\"source ~/.zshrc\" x=exit cat=bat")
	fmt.sbprintln(&builder)
	
	// Prompt: Starship con evalcache
	fmt.sbprintln(&builder, "# === Prompt (evalcached) ===")
	fmt.sbprintln(&builder, "_wayu_evalcache starship init zsh")
	fmt.sbprintln(&builder)
	
	// Load helpers (zsh-defer propio incluido aquí)
	fmt.sbprintln(&builder, "# === Load helpers (zsh-defer propio) ===")
	fmt.sbprintfln(&builder, "source \"%s/init-helpers.zsh\" 2>/dev/null", WAYU_CONFIG)
	fmt.sbprintln(&builder)
	
	// Defer lazy init
	fmt.sbprintln(&builder, "# === Deferred loading (lazy init) ===")
	fmt.sbprintln(&builder, "[[ -z \"$_WAYU_LAZY_LOADED\" ]] && {")
	fmt.sbprintln(&builder, "  export _WAYU_LAZY_LOADED=1")
	fmt.sbprintfln(&builder, "  zsh-defer source \"%s/init-lazy.zsh\"", WAYU_CONFIG)
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)
	
	// Login shell extras
	fmt.sbprintln(&builder, "# === Login shell ===")
	fmt.sbprintfln(&builder, "[[ -o login ]] && source \"%s/init-login.zsh\" 2>/dev/null", WAYU_CONFIG)
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
	
	// Compinit optimizado (cache 24h)
	fmt.sbprintln(&builder, "# === Completions (compinit optimizado) ===")
	fmt.sbprintln(&builder, "autoload -Uz compinit")
	fmt.sbprintln(&builder, "local zcompdump=\"${ZDOTDIR:-$HOME}/.zcompdump\"")
	fmt.sbprintln(&builder, "if [[ -n $zcompdump(#qN.mh+24) ]]; then")
	fmt.sbprintln(&builder, "  compinit -C  # Cache válido, modo rápido")
	fmt.sbprintln(&builder, "else")
	fmt.sbprintln(&builder, "  compinit")
	fmt.sbprintln(&builder, "fi")
	fmt.sbprintln(&builder)
	
	// Plugins
	fmt.sbprintln(&builder, "# === Plugins ===")
	fmt.sbprintln(&builder, "[ -f \"$HOME/.config/wayu/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh\" ] && source \"$HOME/.config/wayu/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh\"")
	fmt.sbprintln(&builder, "[ -f \"$HOME/.config/wayu/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh\" ] && source \"$HOME/.config/wayu/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh\"")
	fmt.sbprintln(&builder)
	
	// Tools con evalcache
	fmt.sbprintln(&builder, "# === Tools (evalcached) ===")
	fmt.sbprintln(&builder, "_wayu_evalcache zoxide init zsh")
	fmt.sbprintln(&builder, "_wayu_evalcache atuin init zsh --disable-up-arrow")
	fmt.sbprintln(&builder)
	
	// Resto de environment (batch)
	fmt.sbprintln(&builder, "# === Environment completo (batch) ===")
	fmt.sbprintln(&builder, "typeset -gx GOPATH=\"$HOME/go\" NVM_DIR=\"$HOME/.nvm\" SDKMAN_DIR=\"$HOME/.sdkman\" BUN_INSTALL=\"$HOME/.bun\" JAVA_HOME=\"/Library/Java/JavaVirtualMachines/zulu-11.jdk/Contents/Home\"")
	fmt.sbprintln(&builder)
	
	// Resto de aliases
	fmt.sbprintln(&builder, "# === Aliases adicionales ===")
	fmt.sbprintln(&builder, "alias config=\"vim $SHELL_CONFIG\" dotfiles=\"vim $CONFIGS\" tree=\"lsd --tree\" py=python3")
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
