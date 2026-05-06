// prompt_interactive.odin - Interactive prompt features
// All techniques: toggle, vi-mode, context-aware, async, transient
package wayu

import "core:fmt"
import "core:strings"

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
		generate_async_feature(&builder, cfg.async_interval)
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
generate_async_feature :: proc(b: ^strings.Builder, interval: int) {
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
	fmt.sbprintln(b, `      git_pending="%F{242} ✎${git_pending}%f"`)
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
	}

	return cfg
}
