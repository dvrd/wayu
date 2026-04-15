# Asignación de Workstreams a Subagentes

## 🎯 Resumen Visual de Paralelización

```
SEMANA 1: 4 Workstreams en paralelo
═══════════════════════════════════════════════════════════════

Agente 1: Core Infrastructure (WS1)
├─ Día 1-2: JSON Output ✅
├─ Día 3-5: Lock Files ✅
└─ Entregable: src/output.odin, src/lock.odin

Agente 2: Config System (WS2) ──► Espera día 3 de WS1
├─ Día 3-6: TOML Parser Integration
├─ Día 7-9: TOML Schema & Commands
└─ Entregable: src/config_toml.odin

Agente 3: Plugin System (WS3) ──► Espera día 3 de WS1
├─ Día 3-5: Plugins Locales/Remotos
├─ Día 6-9: Deferred Loading System
└─ Entregable: src/plugin_enhanced.odin

Agente 4: Fish/Integrations (WS6) ──► Paralelo desde día 1
├─ Día 1-3: Fish Shell Detection
├─ Día 4-7: Fish Templates
└─ Entregable: src/shell_fish.odin

CHECKPOINT DÍA 5: Merge Lock Files a main

SEMANA 2: 4 Workstreams en paralelo
═══════════════════════════════════════════════════════════════

Agente 1: Integration (cont.) + Hot Reload
├─ TOML finalización (WS2 cont.)
├─ Hot Reload implementation (WS4)
└─ Entregable: Hot reload system

Agente 2: Performance (WS4) ──► Espera TOML
├─ Static Loading Generation
├─ Benchmarks
└─ Entregable: src/static_gen.odin

Agente 3: Plugins (cont.) + Themes (WS5)
├─ Conditional Loading
├─ Starship Integration
└─ Entregable: Theme system

Agente 4: Integrations (cont.) (WS6)
├─ Direnv Integration
├─ Mise Integration
└─ Entregable: src/integrations.odin

CHECKPOINT DÍA 10: Merge TOML + Static Loading a main

SEMANA 3-4: Testing + Polish
═══════════════════════════════════════════════════════════════

Agente 5: QA/Benchmarking (WS7)
├─ Benchmarks vs Sheldon/Zinit
├─ Integration tests
├─ Documentation
└─ Entregable: Benchmarks publicados

Todos: Bug fixes + Polish
├─ Regression testing
├─ Performance tuning
└─ Release v3.5.0
```

---

## 📋 Detalle de Asignaciones

### Agente 1: Core Infrastructure Developer
**Workstream**: WS1  
**Skills needed**: Odin, serialization, hashing  
**Responsabilidades**:
- JSON output system
- Lock file format y operations
- Interfaces compartidas

**Entregables específicos**:
```
src/
  output.odin           # JSON/YAML serialization
  lock.odin             # wayu.lock read/write
  interfaces.odin       # Tipos compartidos

tests/unit/
  test_output.odin      # Tests JSON
  test_lock.odin        # Tests lock files
```

**Success criteria**:
- [ ] `wayu path list --json` funciona
- [ ] `wayu.lock` se genera con hashes correctos
- [ ] Tests pasan >90% coverage

---

### Agente 2: Configuration System Developer
**Workstream**: WS2  
**Skills needed**: Odin, parsers (TOML), schema design  
**Responsabilidades**:
- TOML parser integration
- Config schema y validación
- Per-profile configs

**Entregables específicos**:
```
src/
  config_toml.odin      # Parser y loader
  config_validate.odin  # Validación de schema
  config_profile.odin   # Per-profile logic

config/
  wayu.toml.example     # Ejemplo de config
  schema.json           # JSON Schema para validación

tests/unit/
  test_toml.odin
  test_profile.odin
```

**Success criteria**:
- [ ] `wayu init --toml` crea config válida
- [ ] `wayu validate` valida TOML
- [ ] `[profile.work]` funciona
- [ ] Tests pasan >90% coverage

---

### Agente 3: Plugin System Developer
**Workstream**: WS3  
**Skills needed**: Odin, shell scripting, async operations  
**Responsabilidades**:
- Plugins locales/remotos
- Deferred loading
- Conditional loading

**Entregables específicos**:
```
src/
  plugin_local.odin       # Soporte /path/to/plugin
  plugin_remote.odin    # Soporte URLs
  plugin_defer.odin     # Deferred loading
  plugin_conditional.odin # Conditional logic

tests/unit/
  test_plugin_local.odin
  test_plugin_defer.odin
```

**Success criteria**:
- [ ] `wayu plugin add /local/path` funciona
- [ ] `wayu plugin add https://...` funciona
- [ ] `--defer` carga plugins post-prompt
- [ ] `--if 'os == "macos"'` funciona
- [ ] Tests pasan >90% coverage

---

### Agente 4: Performance & Generation Developer
**Workstream**: WS4  
**Skills needed**: Odin, code generation, performance tuning  
**Responsabilidades**:
- Static loading generation
- Hot reload
- Benchmarks

**Entregables específicos**:
```
src/
  static_gen.odin       # Generador de .zsh estático
  hot_reload.odin       # File watcher
  benchmark.odin      # Benchmarking suite

tests/
  benchmark/
    bench_startup.odin  # Startup time benchmarks
    bench_operations.odin # Operation benchmarks
```

**Success criteria**:
- [ ] `wayu generate-static > ~/.wayu.zsh` genera válido
- [ ] Static loading >50% más rápido que dynamic
- [ ] Hot reload detecta cambios en <1s
- [ ] Benchmarks vs Sheldon/Zinit publicados

---

### Agente 5: UI/UX Developer
**Workstream**: WS5  
**Skills needed**: Odin, TUI, shell prompts  
**Responsabilidades**:
- Starship integration
- Custom themes
- TUI improvements

**Entregables específicos**:
```
src/
  theme.odin            # Theme system
  theme_starship.odin   # Starship integration
  tui_improved.odin     # TUI enhancements

themes/
  minimal.toml
  powerline.toml
  default.toml

tests/unit/
  test_theme.odin
```

**Success criteria**:
- [ ] `wayu theme enable starship` funciona
- [ ] `wayu theme list` muestra themes
- [ ] TUI tiene fuzzy search mejorado
- [ ] Preview pane funciona

---

### Agente 6: Integration Developer
**Workstream**: WS6  
**Skills needed**: Odin, shell scripting, tool integration  
**Responsabilidades**:
- Direnv integration
- Mise integration
- Fish shell support

**Entregables específicos**:
```
src/
  integration_direnv.odin  # Direnv support
  integration_mise.odin    # Mise support
  shell_fish.odin          # Fish templates

templates/
  fish/
    init.fish
    path.fish
    aliases.fish

tests/unit/
  test_fish.odin
  test_integrations.odin
```

**Success criteria**:
- [ ] `wayu direnv init` configura direnv
- [ ] `wayu mise sync` sincroniza versiones
- [ ] Fish shell support completo
- [ ] Tests en Fish shell pasan

---

### Agente 7: QA & Documentation Lead
**Workstream**: WS7  
**Skills needed**: Testing, writing, benchmarking  
**Responsabilidades**:
- Benchmarking suite
- Integration tests
- Documentation

**Entregables específicos**:
```
docs/
  BENCHMARKS.md          # Resultados comparativos
  MIGRATION.md           # Guía migración desde otros
  TOML_GUIDE.md          # Guía configuración TOML

tests/integration/
  test_migration.odin    # Tests migración
  test_e2e.odin         # End-to-end tests

.github/
  workflows/
    benchmark.yml        # CI benchmarks
```

**Success criteria**:
- [ ] Benchmarks publicados en README
- [ ] wayu >2x más rápido que Sheldon en startup
- [ ] Documentación actualizada
- [ ] Integration tests >95% pass

---

## 📅 Timeline Detallado por Agente

### Agente 1 (Core): Días 1-10
```
Día 1-2:  JSON Output
          ├─ Agregar --json flag
          ├─ Implementar serialización
          └─ Tests

Día 3-5:  Lock Files
          ├─ Diseñar schema
          ├─ Implementar read/write
          └─ Integrar hashes

Día 6-7:  CHECKPOINT Merge
          ├─ Merge a main
          └─ Soporte a otros agentes

Día 8-10: Hot Reload (con WS4)
          ├─ File watcher
          └─ Auto-regeneración
```

### Agente 2 (Config): Días 3-12
```
Día 3-4:  Setup + Parser TOML
          ├─ Evaluar librerías Odin
          └─ Integrar parser

Día 5-7:  Schema y Commands
          ├─ Definir schema completo
          ├─ wayu init --toml
          └─ wayu validate

Día 8-10: Per-Profile Config
          ├─ [profile.*] support
          └─ wayu --profile work

Día 11-12: CHECKPOINT Merge
            ├─ Merge a main
            └─ Documentación schema
```

### Agente 3 (Plugins): Días 3-12
```
Día 3-5:  Plugins Locales/Remotos
          ├─ wayu plugin add /path
          └─ wayu plugin add https://

Día 6-9:  Deferred Loading
          ├─ --defer flag
          └─ Post-prompt loading

Día 10-12: Conditional Loading
            ├─ --if 'condition'
            └─ Os detection
```

### Agente 4 (Performance): Días 8-17
```
Día 8-10: Setup (espera TOML)
           └─ Integrar con interfaces

Día 11-13: Static Loading
            ├─ Generador de .zsh
            └─ Optimization

Día 14-15: Hot Reload
            └─ File watcher

Día 16-17: Benchmarks
            ├─ Scripts comparativos
            └─ CI integration
```

### Agente 5 (UI): Días 10-19
```
Día 10-12: Setup
            └─ Theme system base

Día 13-15: Starship Integration
            ├─ Detectar instalación
            └─ Configurar

Día 16-17: Custom Themes
            └─ 3 themes básicos

Día 18-19: TUI Improvements
            └─ Fuzzy mejorado
```

### Agente 6 (Integrations): Días 1-17
```
Día 1-7:   Fish Support
            ├─ Detection
            ├─ Templates
            └─ Tests

Día 8-12:  Direnv Integration
            ├─ wayu direnv init
            └─ .envrc management

Día 13-17: Mise Integration
            ├─ wayu mise sync
            └─ .mise.toml support
```

### Agente 7 (QA): Días 15-28
```
Día 15-19: Benchmarking
            ├─ Scripts de prueba
            ├─ Comparativas
            └─ Resultados

Día 20-23: Integration Tests
            ├─ Tests end-to-end
            └─ Regression tests

Día 24-28: Documentation
            ├─ README updates
            ├─ Migration guide
            └─ TOML guide
```

---

## 🔗 Dependencias Críticas

```
JSON Output ───────┐
                    ├──► Lock Files ────┐
                    │                    ├──► TOML Config ────┐
Plugins Locales ────┤                    │                    ├──► Static Loading
                    │                    └──► Per-Profile      │
Deferred ──────────┤                         Config            ├──► Hot Reload
                    │                                           │
Conditional ───────┘                                           ├──► Themes
                                                                 │
                                                                 ├──► Benchmarks
                                                                 │
Fish ────────────────────────────────────────────────────────────┤
Direnv ────────────────────────────────────────────────────────┤
Mise ──────────────────────────────────────────────────────────┘
```

**Regla**: Si un nodo no está listo, los que dependen de él esperan o usan mocks.

---

## ⚡ Velocity Esperada

| Agente | Features | Días | Velocity |
|--------|----------|------|----------|
| Core | 2 | 10 | 0.2 feature/día |
| Config | 2 | 10 | 0.2 feature/día |
| Plugins | 3 | 10 | 0.3 feature/día |
| Performance | 2 | 10 | 0.2 feature/día |
| UI | 2 | 10 | 0.2 feature/día |
| Integration | 3 | 17 | 0.18 feature/día |
| QA | 3 | 14 | 0.21 feature/día |

**Total**: 17 features en 28 días = **0.61 features/día/persona**

**Comparación Serial**:
- Serial: 17 features × 3 días = 51 días
- Paralelo: 28 días
- **Ahorro: 45% más rápido**

---

## ✅ Checklist de Preparación

### Antes de Empezar (Día 0)

- [ ] Crear 7 branches feature/* en GitHub
- [ ] Definir `src/interfaces.odin` compartido
- [ ] Setup CI/CD en GitHub Actions
- [ ] Crear canal Slack/Discord para coordinación
- [ ] Asignar agentes a workstreams
- [ ] Schedule daily standups (async)
- [ ] Documentar convenciones de código

### Interfaces a Definir (Día 0)

```odin
// src/interfaces.odin - VERSIÓN 1.0 COMPARTIDA

package wayu

// ============ Lock File ============
LockFile :: struct {
    version: string,
    generated_at: string,
    entries: []LockEntry,
}

LockEntry :: struct {
    type: ConfigType,
    name: string,
    hash: string,
    added_at: string,
    metadata: map[string]string,
}

// ============ TOML Config ============
TomlConfig :: struct {
    version: string,
    shell: string,
    path: []string,
    aliases: []TomlAlias,
    constants: []TomlConstant,
    plugins: []TomlPlugin,
    profiles: map[string]ProfileConfig,
}

TomlPlugin :: struct {
    name: string,
    source: string,
    defer: bool,
    condition: string,
    priority: int,
}

ProfileConfig :: struct {
    path: []string,
    aliases: []TomlAlias,
    constants: []TomlConstant,
    plugins: []TomlPlugin,
}

// ============ Output Formats ============
OutputFormat :: enum {
    Plain,
    JSON,
    YAML,
}

// ============ Plugin Types ============
PluginSource :: enum {
    GitHub,
    Local,
    Remote,
    Git,
}

// ============ Shell Types ============
ShellType :: enum {
    Zsh,
    Bash,
    Fish,
}

// ============ Functions Compartidas ============
lock_read :: proc(path: string) -> (LockFile, bool)
lock_write :: proc(path: string, lock: LockFile) -> bool
lock_generate_hash :: proc(entry: ConfigEntry) -> string

toml_parse :: proc(content: string) -> (TomlConfig, bool)
toml_validate :: proc(config: TomlConfig) -> ValidationResult
toml_merge_profiles :: proc(base: TomlConfig, profile: string) -> TomlConfig

output_json :: proc(data: any) -> string
output_yaml :: proc(data: any) -> string
```

---

## 🚀 Comando para Empezar

```bash
# Día 0: Setup de paralelización
cd /Users/kakurega/dev/projects/wayu

# Crear branches
git checkout -b feature/core-infrastructure
git checkout -b feature/config-system
git checkout -b feature/plugin-system
git checkout -b feature/performance
git checkout -b feature/ui-themes
git checkout -b feature/integrations
git checkout -b feature/qa-benchmarks

# Definir interfaces
# (Agente 1 escribe src/interfaces.odin)

# Compartir con todos los agentes
# (subagent dispatch con contexto de interfaces)

# Empezar!
echo "Let's go! 🚀"
```

---

## 📞 Coordinación

### Daily Standup (Async)
Cada agente postea al final del día:
```
Agente X (WSY): 
- Hoy completé: Z, W
- Bloqueado por: Nada / Agente N (feature F)
- Mañana: X, Y
- Riesgos: Ninguno / Merge conflict potencial en file Z
```

### Checkpoints Sincrónicos
- **Día 5**: 30min sync - Lock files integración
- **Día 10**: 30min sync - TOML + Plugins merge
- **Día 17**: 30min sync - Performance + UI merge
- **Día 24**: 1h - Final integration testing

---

## 💰 ROI de Paralelización

| Métrica | Serial | Paralelo | Mejora |
|---------|--------|----------|--------|
| Tiempo total | 15 semanas | 4 semanas | **73%** |
| Features/semana | 1.0 | 4.25 | **325%** |
| Costo estimado | 15 dev-weeks | 28 dev-days | **53%** |
| Time to market | Oct 2025 | Jul 2025 | **3 meses antes** |
| Riesgo | Bajo | Medio | Mitigable |

**Conclusión**: Vale la pena el riesgo de coordinación por el 3x speedup.

---

## ¿Procedemos?

**Requisitos para empezar mañana**:
- [ ] 7 subagentes disponibles
- [ ] Interfaces definidas
- [ ] Branches creados
- [ ] CI/CD configurado
- [ ] Canal de comunicación activo

**¿Listos para lanzar los workstreams en paralelo? 🚀**
