# Plan de Implementación Paralela con Subagentes

## 🎯 Visión

Implementar las 15 features críticas en **4 semanas** (vs 15 semanas serial) usando subagentes paralelos.

## 📊 Análisis de Dependencias

### Grafo de Dependencias

```
JSON Output
    │
    ├──► Lock Files (usa JSON para formato)
    │       │
    │       ├──► TOML Config (usa Lock format)
    │       │       │
    │       │       ├──► Static Loading (genera desde TOML)
    │       │       │       │
    │       │       │       ├──► Hot Reload (regenera static)
    │       │       │
    │       │       ├──► Per-Profile Config (extiende TOML)
    │       │
    │       └──► Plugins Locales/Remotos (registran en Lock)
    │               │
    │               ├──► Deferred Loading (ejecución)
    │               │       │
    │               │       └──► Themes/Prompts (usa defer)
    │               │
    │               └──► Conditional Loading (metadata)
    │
    └──► CLI Improvements (usa JSON output)

Workstreams Independientes:
    ├──► Direnv Integration
    ├──► Mise Integration
    ├──► Fish Support
    └──► Benchmarking Suite
```

## 🚀 Estructura de Workstreams Paralelos

### Workstream 1: Core Infrastructure (Semana 1) - 1 agente
**Agente**: Core Developer  
**Scope**: Fundamentos compartidos

- [ ] **JSON Output** (1-2 días)
  - Agregar flag `--json` a todos los comandos list/get
  - Implementar serialization en `src/output.odin`
  - Tests

- [ ] **Lock File Format** (2-3 días)  
  - Diseñar schema `wayu.lock` (YAML/JSON)
  - Implementar `src/lock.odin` con read/write
  - Integrar hashes SHA256
  - Tests

**Entregable**: `src/output.odin`, `src/lock.odin` con tests
**Dependencias**: Ninguna (puede empezar inmediatamente)

---n

### Workstream 2: Config System (Semana 1-2) - 1 agente
**Agente**: Config System Developer  
**Scope**: Sistema de configuración declarativa

- [ ] **TOML Config** (3-4 días)
  - Integrar parser TOML (buscar/lib en Odin)
  - Crear `src/config_toml.odin`
  - Schema: path, aliases, constants, plugins
  - Comando `wayu init --toml`
  - Comando `wayu validate`
  - Tests

- [ ] **Per-Profile Config** (2 días)
  - Extender schema TOML con `[profile.*]`
  - Implementar `wayu --profile work`
  - Tests

**Entregable**: `src/config_toml.odin`, schema definido
**Dependencias**: 
  - Necesita Lock Files de Workstream 1 (para guardar state)
  - Puede empezar en día 3 de Workstream 1

---

### Workstream 3: Plugin System Enhanced (Semana 1-2) - 1 agente
**Agente**: Plugin Developer  
**Scope**: Mejoras al sistema de plugins

- [ ] **Plugins Locales/Remotos** (2 días)
  - Extender `src/plugin.odin`
  - `wayu plugin add /path/local`
  - `wayu plugin add https://example.com/script.zsh`
  - Tests

- [ ] **Deferred Loading** (3-4 días)
  - Implementar sistema de defer
  - Flag `--defer` en plugin add
  - Generar código de carga diferida
  - Tests con timing

- [ ] **Conditional Loading** (2 días)
  - Flag `--if 'condition'`
  - Soporte: os, shell version, command exists
  - Tests

**Entregable**: Plugin system mejorado con defer y condicionales
**Dependencias**:
  - Lock Files de Workstream 1 (para registrar plugins)
  - Puede empezar en día 3 de Workstream 1

---

### Workstream 4: Performance & Generation (Semana 2) - 1 agente
**Agente**: Performance Developer  
**Scope**: Optimizaciones de velocidad

- [ ] **Static Loading** (3 días)
  - Comando `wayu generate-static`
  - Generar archivo `.zsh` optimizado desde TOML
  - Inline de plugins, concatenación
  - Benchmarks vs dynamic loading

- [ ] **Hot Reload** (2 días)
  - File watcher (platform-specific)
  - Auto-regenerar static file
  - Signal shell para reload (opcional)

**Entregable**: `src/static_gen.odin`, hot reload
**Dependencias**:
  - TOML Config de Workstream 2 (genera desde TOML)
  - Deferred Loading de Workstream 3 (incluir en static)
  - Puede empezar en día 5 (cuando WS2 y WS3 tienen base)

---

### Workstream 5: Themes & UI (Semana 2) - 1 agente
**Agente**: UI/UX Developer  
**Scope**: Themes y mejoras visuales

- [ ] **Starship Integration** (2 días)
  - Detectar Starship instalado
  - `wayu theme enable starship`
  - Configurar en TOML

- [ ] **Custom Themes** (2 días)
  - Soporte themes nativos wayu
  - `wayu theme list/add/remove`
  - TOML config para themes

- [ ] **TUI Improvements** (2 días)
  - Mejorar navegación fuzzy
  - Preview pane
  - Atajos de teclado adicionales

**Entregable**: Theme system, TUI mejorada
**Dependencias**:
  - TOML Config de Workstream 2
  - Puede empezar en día 4 de Workstream 2

---

### Workstream 6: Integrations (Semana 2-3) - 1 agente
**Agente**: Integration Developer  
**Scope**: Integraciones con ecosistema

- [ ] **Direnv Integration** (2 días)
  - Detectar `.envrc`
  - `wayu direnv init`
  - Auto-configurar direnv
  - Documentación

- [ ] **Mise Integration** (2 días)
  - Detectar `.mise.toml` / `.tool-versions`
  - `wayu mise sync`
  - Sincronizar versiones de tools

- [ ] **Fish Support** (3 días)
  - Extender shell detection a Fish
  - Templates Fish-compatible
  - Tests en Fish

**Entregable**: Integraciones funcionales
**Dependencias**:
  - TOML Config de Workstream 2 (para guardar config integraciones)
  - Puede empezar en paralelo en día 5

---

### Workstream 7: Documentation & Benchmarking (Semana 3) - 1 agente
**Agente**: Technical Writer / QA  
**Scope**: Docs y pruebas

- [ ] **Benchmarking Suite** (3 días)
  - Scripts comparativos vs Zinit, Sheldon, OMZ
  - Startup time, plugin load, list operations
  - GitHub Actions para CI benchmarks
  - Publicar resultados

- [ ] **Documentation** (2 días)
  - README actualizado con nuevas features
  - Guía de migración desde otros managers
  - Ejemplos de TOML config

- [ ] **Testing** (2 días)
  - Integration tests para nuevas features
  - Regression tests
  - CI pipeline

**Entregable**: Benchmarks publicados, docs actualizadas
**Dependencias**: Necesita todas las features implementadas para benchmark completo

---

## 📅 Timeline de Paralelización

```
Semana 1:
  Día 1-2:  WS1 (JSON Output)
           WS2 (TOML start - puede empezar día 2)
           WS3 (Plugin locales start - día 2)
           
  Día 3-5:  WS1 (Lock Files - completo día 5)
           WS2 (TOML continúa)
           WS3 (Deferred Loading)
           WS6 (Fish Support start - paralelo)

  Día 5:    CHECKPOINT 1 - Lock Files listo
           WS2 acelera (usa Lock)
           WS3 acelera (usa Lock)

Semana 2:
  Día 1-3:  WS2 (Per-Profile Config)
           WS3 (Conditional Loading)
           WS4 (Static Loading start - día 3)
           WS5 (Starship start)
           
  Día 3-5:  WS4 (Hot Reload)
           WS5 (Custom Themes)
           WS6 (Direnv + Mise)
           
  Día 5:    CHECKPOINT 2 - Core features listas
           Merge a main branch

Semana 3:
  Día 1-3:  WS5 (TUI Improvements)
           WS7 (Benchmarking)
           
  Día 3-5:  WS7 (Documentation + Testing)
           Bug fixes de todos los WS
           
  Día 5:    RELEASE CANDIDATE 1
           Testing completo

Semana 4:
  Día 1-5:  Buffer para bug fixes
           Performance tuning
           Polishing
           
  Día 5:    FINAL RELEASE v3.5.0
```

---

## 🔧 Estrategia de Coordinación

### 1. Interfaces Compartidas

Definir en `src/interfaces.odin` antes de empezar:

```odin
// Lock file interface
LockFile :: struct {
    version: string,
    generated_at: string,
    entries: []LockEntry,
}

LockEntry :: struct {
    type: ConfigType,
    name: string,
    hash: string,
    metadata: map[string]string,
}

// TOML config interface  
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
    condition: string, // para conditional loading
}
```

### 2. Convenciones de Código

- Todos los nuevos módulos en `src/<feature>.odin`
- Tests en `tests/unit/test_<feature>.odin`
- Prefijo de funciones: `<feature>_<action>` (ej: `lock_read`, `toml_parse`)
- Documentación de funciones públicas

### 3. Branching Strategy

```
main
├── feature/json-output (WS1)
├── feature/lock-files (WS1)
├── feature/toml-config (WS2)
├── feature/plugins-enhanced (WS3)
├── feature/static-loading (WS4)
├── feature/themes (WS5)
├── feature/integrations (WS6)
└── feature/benchmarks (WS7)

Merge a main cada 3-4 días con checkpoint
```

### 4. Checkpoints de Integración

| Checkpoint | Fecha | Requisitos | Verificación |
|------------|-------|------------|--------------|
| CP1 | Día 5 | Lock Files + JSON listo | `odin check` pasa, tests pasan |
| CP2 | Día 10 | TOML + Plugins mejorado | Integration test básico |
| CP3 | Día 15 | Static + Hot reload | Benchmark >50% faster |
| CP4 | Día 20 | All features merged | Full test suite pasa |

### 5. Resolución de Conflictos

Si dos workstreams editan el mismo archivo:

1. **Archivos core** (`main.odin`, `config_entry.odin`):
   - Solo WS1 puede modificar
   - Otros WS usan hooks/bridges

2. **Nuevos archivos**: Cada WS crea sus propios archivos

3. **Tests**: Merge automático, tests independientes

---

## ⚠️ Riesgos y Mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|--------|--------------|---------|------------|
| Dependencias bloquean | Media | Alto | Definir interfaces antes, mock si es necesario |
| Conflictos de merge | Media | Medio | Checkpoints frecuentes, branches por feature |
| Tests fallan en paralelo | Baja | Alto | CI en cada PR, integration tests semanales |
| Diferencias de estilo | Baja | Medio | Guía de estilo compartida, code review |
| Feature creep | Media | Medio | Scope claro por WS, no agregar features mid-flight |

---

## 🛠️ Recursos Necesarios

### Humanos (Subagentes)

1. **Core Developer** (WS1) - JSON + Lock files
2. **Config Developer** (WS2) - TOML + Profiles
3. **Plugin Developer** (WS3) - Plugins mejorados
4. **Performance Developer** (WS4) - Static + Hot reload
5. **UI Developer** (WS5) - Themes + TUI
6. **Integration Developer** (WS6) - Direnv + Mise + Fish
7. **QA/Writer** (WS7) - Benchmarks + Docs

**Total**: 7 subagentes en paralelo (aunque WS7 empieza más tarde)

### Infraestructura

- GitHub repo con branches protegidas
- GitHub Actions para CI (tests, benchmarks)
- Slack/Discord para coordinación rápida
- Documentación compartida (Notion/GitHub Wiki)

---

## 📊 Métricas de Éxito

### Técnicas

- [ ] 15 features implementadas en 4 semanas
- [ ] 0 regressions (tests existentes pasan)
- [ ] Benchmark: wayu >2x más rápido que Sheldon
- [ ] 80%+ code coverage en nuevos módulos
- [ ] 0 conflictos de merge no resueltos

### De Producto

- [ ] wayu.lock funciona (reproducibilidad)
- [ ] wayu.toml es válido y parseable
- [ ] Static loading reduce startup >50%
- [ ] TUI mantiene/usability
- [ ] Fish support funcional

---

## 🎬 Plan de Acción Inmediato

### Hoy (Día 0)

1. [ ] **Checkpoint**: Validar plan con equipo
2. [ ] Crear 7 branches en GitHub
3. [ ] Definir `src/interfaces.odin` compartido
4. [ ] Asignar subagentes a workstreams

### Mañana (Día 1)

1. [ ] WS1, WS2, WS3 empiezan en paralelo
2. [ ] Daily standup async (mensajes de status)
3. [ ] End-of-day checkpoint

### Cada 3 días

1. [ ] Checkpoint de integración
2. [ ] Merge a main si estable
3. [ ] Replanificar si delays

---

## 💡 Ventajas de Paralelización

| Serial | Paralelo | Mejora |
|--------|----------|--------|
| 15 semanas | 4 semanas | **73% más rápido** |
| 1 persona | 7 personas | 7x throughput |
| Single point failure | Distribuido | Resiliente |
| Context switching | Foco profundo | Mejor calidad |

---

## ❓ Preguntas Clave para Decisión

1. ¿Tenemos 7 subagentes disponibles?
2. ¿El repositorio soporta branching strategy?
3. ¿Tenemos CI/CD para testing automático?
4. ¿Definimos interfaces antes de empezar?
5. ¿Asignamos un "architect lead" para coordinar?

**Si la respuesta es sí a 4+**: Proceder con plan paralelo

**Si la respuesta es no**: Híbrido (algunos features en paralelo, otros serial)

---

## 🚀 Recomendación

**IR EN PARALELO** con:
- 4-5 workstreams simultáneos máximo inicialmente
- Checkpoints cada 3 días
- Un architect lead revisando integración
- CI automático para detectar conflictos temprano

**Tiempo estimado**: 4 semanas para paridad competitiva (vs 15 semanas serial)

¿Quieres que procedamos con la asignación de subagentes y definición de interfaces?
