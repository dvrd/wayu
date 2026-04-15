# Plan de Corrección e Integración Final - wayu v3.5.0

**Objetivo**: Completar v3.5.0 en 5-7 días mediante corrección de errores e implementación de archivos faltantes.

**Estado inicial**: 90% completado, 3 errores de compilación, archivos faltantes documentados.
**Estado objetivo**: 100% completado, 0 errores, todos los tests pasan, release listo.

---

## 📅 Timeline de Corrección (5-7 días)

```
DÍA 1: Fixes Críticos de Compilación
├─ Corregir config_toml.odin (3 errores)
├─ Verificar odin check pasa
└─ Merge a main

DÍA 2-3: Implementación de Plugins Faltantes
├─ plugin_local.odin
├─ plugin_remote.odin
├─ plugin_defer.odin
└─ plugin_conditional.odin

DÍA 4: Implementación de Themes
├─ theme.odin
├─ theme_starship.odin
└─ themes/ (minimal, powerline, default)

DÍA 5: Integraciones
├─ shell_fish.odin
├─ templates/fish/*.fish
├─ integration_direnv.odin
└─ integration_mise.odin

DÍA 6-7: Testing & Release
├─ Integration tests
├─ Benchmarks reales
├─ Documentación final
└─ Release v3.5.0
```

---

## 🔧 FASE 1: Fixes Críticos (Día 1)

### Tarea 1.1: Corregir config_toml.odin

**Errores identificados**:
```
Error 1 (línea 676): Cannot take the pointer address of 'tokens[:]'\
Error 2 (línea 797): No procedures 'append' match for []TomlAlias\
Error 3 (línea 830): No procedures 'append' match for []TomlConstant
```

**Soluciones**:

```odin
// CAMBIO 1: Línea ~797 y ~830
// DE:
config.aliases: []TomlAlias  // slice fijo
// A:
config.aliases: [dynamic]TomlAlias  // array dinámico

// El append(&config.aliases, alias) ahora funciona

// CAMBIO 2: Línea 676
// DE:
val, ok := parse_toml_value(&p, &tokens[:], &idx)
// A:
tokens_dyn := make([dynamic]Token, len(tokens))
for t, i in tokens { tokens_dyn[i] = t }
val, ok := parse_toml_value(&p, &tokens_dyn, &idx)
```

**Agente asignado**: Agente 2 (Config Dev) o developer Odin experimentado
**Tiempo estimado**: 4-6 horas
**Entregable**: `config_toml.odin` compilando sin errores

---

## 🧩 FASE 2: Implementación de Plugins (Días 2-3)

### Tarea 2.1: plugin_local.odin

**Funcionalidad**:
- `wayu plugin add /local/path/to/plugin`
- `wayu plugin add ./relative/path`
- Soporte para symlinks

**API**:
```odin
package wayu

plugin_local_install :: proc(local_path: string, name: string) -> bool
plugin_local_validate :: proc(local_path: string) -> ValidationResult
plugin_local_load :: proc(local_path: string) -> bool
```

**Agente asignado**: Agente 3 (Plugin Dev)
**Tiempo estimado**: 6-8 horas
**Tests**: test_plugin_local.odin

---

### Tarea 2.2: plugin_remote.odin

**Funcionalidad**:
- `wayu plugin add https://example.com/plugin.zsh`
- `wayu plugin add https://raw.githubusercontent.com/...`
- Download + caching

**API**:
```odin
plugin_remote_install :: proc(url: string, name: string) -> bool
plugin_remote_download :: proc(url: string, dest: string) -> bool
plugin_remote_validate :: proc(url: string) -> ValidationResult
```

**Agente asignado**: Agente 3 (Plugin Dev)
**Tiempo estimado**: 6-8 horas
**Tests**: test_plugin_remote.odin

---

### Tarea 2.3: plugin_defer.odin

**Funcionalidad**:
- `wayu plugin add user/repo --defer`
- `wayu plugin add user/repo --priority 50`
- Post-prompt loading

**API**:
```odin
plugin_defer_load :: proc(plugins: []EnhancedPlugin)
plugin_defer_process_queue :: proc()
plugin_defer_set_priority :: proc(name: string, priority: int)
```

**Estrategia de implementación**:
```zsh
# Generar en static file:
# 1. Plugins normales: load immediately
# 2. Plugins defer: add to DEFERRED_PLUGINS array
# 3. After prompt, iterate DEFERRED_PLUGINS and source
```

**Agente asignado**: Agente 3 (Plugin Dev)
**Tiempo estimado**: 8-10 horas
**Tests**: test_plugin_defer.odin

---

### Tarea 2.4: plugin_conditional.odin

**Funcionalidad**:
- `wayu plugin add user/repo --if 'os == "macos"'`
- `wayu plugin add user/repo --if 'shell_version >= "5.8"'`
- `wayu plugin add user/repo --if 'command_exists "docker"'`

**Condiciones soportadas**:
```odin
ConditionType :: enum {
    OS,              // os == "macos", os == "linux"
    Shell,           // shell == "zsh"
    ShellVersion,    // shell_version >= "5.8"
    CommandExists,   // command_exists "docker"
    Env,             // env == "VAR == value"
}
```

**API**:
```odin
plugin_evaluate_condition :: proc(condition: string) -> bool
plugin_condition_parse :: proc(condition: string) -> (Condition, bool)
```

**Agente asignado**: Agente 3 (Plugin Dev)
**Tiempo estimado**: 6-8 horas
**Tests**: test_plugin_conditional.odin

---

## 🎨 FASE 3: Implementación de Themes (Día 4)

### Tarea 3.1: theme.odin

**Funcionalidad**:
- `wayu theme list`
- `wayu theme add <name>`
- `wayu theme remove <name>`
- `wayu theme enable <name>`

**API**:
```odin
theme_list :: proc() -> []ThemeConfig
theme_apply :: proc(name: string) -> bool
theme_exists :: proc(name: string) -> bool
theme_get_active :: proc() -> string
```

**Estructura**:
```
~/.config/wayu/
  themes/
    minimal.toml
    powerline.toml
    default.toml
```

**Agente asignado**: Agente 5 (UI Dev)
**Tiempo estimado**: 6-8 horas

---

### Tarea 3.2: theme_starship.odin

**Funcionalidad**:
- `wayu theme enable starship`
- Detectar instalación de starship
- Generar config básico si no existe

**API**:
```odin
theme_starship_detect :: proc() -> bool
theme_starship_get_version :: proc() -> string
theme_starship_generate_config :: proc() -> string
theme_starship_apply :: proc() -> bool
```

**Comportamiento**:
```bash
# Si starship no instalado:
# 1. Sugerir: curl -sS https://starship.rs/install.sh | sh
# 2. O: wayu install starship (si package manager ready)

# Si starship instalado:
# 1. Verificar ~/.config/starship.toml existe
# 2. Si no, crear config básica
# 3. Añadir 'eval "$(starship init zsh)"' a init file
```

**Agente asignado**: Agente 5 (UI Dev)
**Tiempo estimado**: 4-6 horas

---

### Tarea 3.3: Themes built-in

**Archivos a crear**:

`themes/minimal.toml`:
```toml
name = "minimal"
type = "minimal"
[colors]
primary = "cyan"
secondary = "white"
error = "red"
```

`themes/powerline.toml`:
```toml
name = "powerline"
type = "powerline"
[colors]
primary = "blue"
secondary = "green"
separator = "⟩"
```

`themes/default.toml`:
```toml
name = "default"
type = "default"
[colors]
primary = "cyan"
secondary = "dim"
```

**Agente asignado**: Agente 5 (UI Dev)
**Tiempo estimado**: 2-4 horas

---

## 🔌 FASE 4: Integraciones (Día 5)

### Tarea 4.1: shell_fish.odin

**Funcionalidad**:
- Detectar fish shell
- Generar fish-compatible configs
- Templates fish

**API**:
```odin
shell_fish_detect :: proc() -> bool
shell_fish_get_version :: proc() -> string
shell_fish_generate_init :: proc(config: TomlConfig) -> string
shell_fish_generate_path :: proc(entries: []string) -> string
shell_fish_generate_aliases :: proc(aliases: []TomlAlias) -> string
shell_fish_generate_constants :: proc(constants: []TomlConstant) -> string
shell_fish_generate_plugins :: proc(plugins: []TomlPlugin) -> string
```

**Templates** (crear en `templates/fish/`):

`templates/fish/init.fish`:
```fish
# wayu initialization for fish
set -gx WAYU_CONFIG "$HOME/.config/wayu"

# Source wayu generated config
source $WAYU_CONFIG/wayu.fish
```

`templates/fish/path.fish`:
```fish
# Generated by wayu - do not edit manually
set -gx PATH "/usr/local/bin" $PATH
set -gx PATH "$HOME/.cargo/bin" $PATH
```

`templates/fish/aliases.fish`:
```fish
# Aliases
alias gcm 'git commit -m'
alias gs 'git status'
```

**Agente asignado**: Agente 6 (Integration Dev)
**Tiempo estimado**: 8-10 horas

---

### Tarea 4.2: integration_direnv.odin

**Funcionalidad**:
- `wayu direnv init` - crear/modificar .envrc
- `wayu direnv allow` - ejecutar direnv allow
- Exportar wayu constants a direnv

**API**:
```odin
integration_direnv_detect :: proc() -> bool
integration_direnv_init :: proc() -> bool
integration_direnv_allow :: proc() -> bool
integration_direnv_generate_envrc :: proc(config: TomlConfig) -> string
integration_direnv_export_constants :: proc(constants: []TomlConstant) -> string
```

**Comportamiento**:
```bash
# wayu direnv init
# 1. Verificar direnv instalado
# 2. Si .envrc no existe, crearlo
# 3. Añadir línea: source <(wayu export-env)
# 4. Ejecutar: direnv allow

# Contenido .envrc generado:
export API_KEY="value"
export EDITOR="nvim"
```

**Agente asignado**: Agente 6 (Integration Dev)
**Tiempo estimado**: 6-8 horas

---

### Tarea 4.3: integration_mise.odin

**Funcionalidad**:
- `wayu mise sync` - sincronizar versiones
- `wayu mise generate` - crear .mise.toml
- Leer .mise.toml y exportar a wayu

**API**:
```odin
integration_mise_detect :: proc() -> bool
integration_mise_sync :: proc(config: TomlConfig) -> bool
integration_mise_generate_config :: proc(config: TomlConfig) -> string
integration_mise_parse_tool_versions :: proc(path: string) -> map[string]string
integration_mise_export_to_constants :: proc(tools: map[string]string) -> []TomlConstant
```

**Comportamiento**:
```bash
# .mise.toml -> wayu constants
# .mise.toml:
# [tools]
# node = "20.0.0"
# python = "3.11"

# wayu constants:
# export MISE_NODE_VERSION="20.0.0"
# export MISE_PYTHON_VERSION="3.11"
```

**Agente asignado**: Agente 6 (Integration Dev)
**Tiempo estimado**: 6-8 horas

---

## ✅ FASE 5: Testing & Release (Días 6-7)

### Tarea 5.1: Integration Tests

**Coverage**:
- [ ] TOML config roundtrip (parse -> generate -> parse)
- [ ] Lock file generation and verification
- [ ] Plugin local install/remove/load
- [ ] Plugin deferred loading actually defers
- [ ] Hot reload detects changes
- [ ] Static generation produces valid shell script
- [ ] Theme application changes prompt
- [ ] Fish shell compatibility (if fish available)

**Agente asignado**: Agente 7 (QA Dev) + todos los agentes
**Tiempo estimado**: 6-8 horas

---

### Tarea 5.2: Real Benchmarks

**Ejecutar**:
```bash
cd /Users/kakurega/dev/projects/wayu
./tests/benchmark/compare.sh
```

**Verificar**:
- [ ] wayu startup < 50ms (10 plugins)
- [ ] wayu más rápido que Sheldon
- [ ] wayu comparable a Zinit Turbo
- [ ] wayu 10x+ más rápido que OMZ

**Documentar resultados en**: BENCHMARKS.md

**Agente asignado**: Agente 7 (QA Dev)
**Tiempo estimado**: 4-6 horas

---

### Tarea 5.3: Final Review & Release

**Checklist**:
- [ ] `odin check src` pasa sin errores
- [ ] `odin test tests/unit` pasa >95%
- [ ] Todos los features implementados funcionan
- [ ] Documentación actualizada
- [ ] CHANGELOG.md actualizado
- [ ] Version bumped a v3.5.0
- [ ] Git tag v3.5.0 creado
- [ ] Release notes escritas

**Comandos**:
```bash
# 1. Verificar
cd /Users/kakurega/dev/projects/wayu
odin check src -collection:tui=src/tui
odin test tests/

# 2. Update version
# Editar src/main.odin: VERSION :: "3.5.0"

# 3. Changelog
# Añadir entry a CHANGELOG.md

# 4. Commit
git add .
git commit -m "release: wayu v3.5.0

Features:
- JSON output for all list commands
- Lock file system (wayu.lock) with SHA256
- TOML configuration support (wayu.toml)
- Per-profile configuration
- Enhanced plugin system with local/remote support
- Deferred loading for plugins
- Conditional loading (os, shell, version)
- Static loading generation (ultra-fast)
- Hot reload with file watching
- Theme system with Starship integration
- Fish shell support
- Direnv integration
- Mise integration
- Complete benchmarking suite

wayu is now the most feature-complete shell environment manager."

# 5. Tag
git tag v3.5.0
git push origin v3.5.0

# 6. Build release binaries
task build-release
```

**Agente asignado**: Lead + Agente 7 (QA)
**Tiempo estimado**: 4-6 horas

---

## 👥 Asignación de Subagentes para Fixes

### Subagente 1: Odin Fix Specialist
**Tarea**: Corregir config_toml.odin
**Skills**: Odin, type system, debugging
**Tiempo**: 4-6 horas

### Subagente 2: Plugin Developer
**Tarea**: plugin_local.odin, plugin_remote.odin
**Skills**: Odin, file operations, HTTP
**Tiempo**: 12-16 horas (2 días)

### Subagente 3: Plugin Advanced Developer
**Tarea**: plugin_defer.odin, plugin_conditional.odin
**Skills**: Odin, shell scripting, zsh internals
**Tiempo**: 14-18 horas (2 días)

### Subagente 4: UI Developer
**Tarea**: theme.odin, theme_starship.odin, themes/
**Skills**: Odin, UX design, TUI
**Tiempo**: 12-16 horas

### Subagente 5: Integration Developer
**Tarea**: shell_fish.odin, integration_direnv.odin, integration_mise.odin
**Skills**: Odin, Fish shell, tool integration
**Tiempo**: 20-26 horas (3 días)

### Subagente 6: QA Lead
**Tarea**: Integration tests, benchmarks, release
**Skills**: Testing, CI/CD, documentation
**Tiempo**: 10-14 horas (2 días)

---

## 📊 Métricas de Éxito

### Antes de Fixes (90%)
- 10 features completos
- 5 features documentados pero no implementados
- 3 errores de compilación
- ~70% tests pasando

### Después de Fixes (100% - Objetivo)
- 15+ features completos
- 0 features pendientes
- 0 errores de compilación
- 100% tests pasando
- Benchmarks demuestran superioridad
- Documentación completa

---

## 🚀 Comando para Iniciar Fixes

```bash
# 1. Crear branch para fixes
cd /Users/kakurega/dev/projects/wayu
git checkout -b fix/v3.5.0-final

# 2. Asignar subagentes (ejemplo con 3 agentes para empezar)
# /subagent agent=fix-specialist task="Corregir config_toml.odin - 3 errores de compilación"
# /subagent agent=plugin-dev task="Implementar plugin_local.odin y plugin_remote.odin"
# /subagent agent=theme-dev task="Implementar theme.odin y 3 themes built-in"

# 3. Checkpoints diarios
# Día 1: Verificar config_toml compila
# Día 3: Verificar plugins funcionan
# Día 5: Verificar themes + integraciones
# Día 7: Release v3.5.0
```

---

## 💡 Riesgos y Mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|--------|--------------|---------|------------|
| Errores de Odin más complejos | Baja | Alto | Tener Odin expert on standby |
| Features toman más tiempo | Media | Medio | Priorizar: plugins > themes > integrations |
| Tests fallan | Media | Medio | Mock external tools (fish, direnv, mise) |
| Conflicts en merge | Baja | Medio | Integración diaria a fix branch |

---

## ✅ Checklist Final de v3.5.0

### Features Críticos (MUST HAVE)
- [x] JSON output
- [x] Lock files
- [x] Hot reload
- [x] Static generation
- [x] Benchmarks
- [ ] TOML config (fix pending)
- [ ] Plugin enhanced (implement pending)
- [ ] Themes (implement pending)
- [ ] Fish support (implement pending)

### Quality Gates
- [ ] `odin check` passes
- [ ] All unit tests pass
- [ ] All integration tests pass
- [ ] Benchmarks show wayu > competitors
- [ ] Documentation complete
- [ ] No TODO/FIXME comments in code

### Release Checklist
- [ ] Version updated to 3.5.0
- [ ] CHANGELOG.md updated
- [ ] Git tag v3.5.0 created
- [ ] Release notes published
- [ ] Binaries built for major platforms

---

## 🎯 RESULTADO ESPERADO

**wayu v3.5.0**: El manager de entornos shell más completo y rápido del mercado.

**Diferenciadores únicos**:
1. Fuzzy matching nativo (único)
2. TUI completa interactiva (único)
3. Odin nativo = máxima velocidad
4. Multi-shell real (Zsh + Bash + Fish)
5. 15+ features vs 8-10 de competidores

**Tiempo al mercado**: 5-7 días adicionales (vs 15+ semanas serial).

**¿Procedemos con el plan de fixes?**
