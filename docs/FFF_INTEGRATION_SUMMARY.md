# Resumen de Integración fff.nvim con wayu

## ¿Qué es fff.nvim?

fff.nvim es un fuzzy finder ultrarrápido escrito en Rust por Dmitriy Kovalenko. Proporciona:
- **Búsqueda fuzzy** de archivos con scoring inteligente (frecency, git status, tamaño)
- **Live grep** con soporte regex, fuzzy y plain text
- **Indexación en background** con notificaciones de progreso
- **Memoria integrada** que aprende de los patrones de uso

## Arquitectura FFI

fff expone una API C mediante el crate `fff-c`:
```
libfff_c.dylib (macOS)
libfff_c.so    (Linux)
fff_c.dll      (Windows)
```

La API es **instance-based**: creas un handle opaco, lo usas para todas las operaciones, y luego lo destruyes.

## Archivos Creados

| Archivo | Descripción |
|---------|-------------|
| `src/fff.odin` | FFI bindings completos para Odin |
| `examples/fff_integration_example.odin` | Ejemplos de uso |
| `scripts/download-fff.sh` | Script para descargar/compilar la biblioteca |
| `docs/fff-ffi-integration.md` | Documentación técnica completa |

## Uso Rápido

### 1. Descargar la biblioteca fff

```bash
# Descargar prebuilt a ./lib
./scripts/download-fff.sh

# O especificar directorio
./scripts/download-fff.sh /usr/local/lib

# O compilar desde fuente
./scripts/download-fff.sh --build
```

### 2. Usar en código Odin

```odin
import "wayu"  // o tu package

// Crear finder
finder, ok := fff_create("/ruta/a/buscar", ai_mode=true)
defer fff_destroy_finder(&finder)

// Esperar scan inicial
fff_wait_scan(finder, 5000)

// Buscar archivos
results, found := fff_fuzzy_search(finder, "query", page_size=20)
if found {
    for item in results.items {
        fmt.println(item.file_name)
    }
    fff_free_search_result(results)
}

// Live grep
matches, _ := fff_live_grep(finder, "pattern", mode=.Fuzzy)
```

## Opciones de Build

### Opción A: Biblioteca en directorio local
```bash
# Descargar a ./lib
./scripts/download-fff.sh

# Compilar wayu con rpath
odin build src -out:wayu \
    -extra-linker-flags:"-rpath @loader_path/lib -L./lib -lfff_c"
```

### Opción B: Biblioteca del sistema
```bash
# Instalar en sistema
sudo ./scripts/download-fff.sh /usr/local/lib

# Compilar (sin rpath necesario si está en ld path)
odin build src -out:wayu -extra-linker-flags:"-lfff_c"
```

### Opción C: Descarga automática en build
Agregar a tu build script:
```bash
if [ ! -f "lib/libfff_c.$(ext)" ]; then
    ./scripts/download-fff.sh
fi
```

## Casos de Uso para wayu

### 1. Búsqueda Dinámica de Comandos
Permitir al usuario buscar comandos wayu fuzzy:
```odin
finder := fff_create_for_commands()
results := fff_fuzzy_search(finder, user_query)
```

### 2. Explorador de PATH
Al agregar entradas PATH, fuzzy-find directorios:
```odin
finder := fff_create("/home/user")
results := fff_fuzzy_search(finder, "proyectos/go")
```

### 3. Búsqueda en Configuración
Indexar `~/.config/wayu/` para búsqueda rápida:
```odin
finder := fff_create_for_config()
results := fff_fuzzy_search(finder, "alias git")
```

### 4. Live Grep en Plugins
Buscar en código de plugins:
```odin
finder := fff_create(PLUGIN_DIR)
matches := fff_live_grep(finder, "func handle_", mode=.Fuzzy)
```

## API C Disponible

### Lifecycle
- `fff_create_instance()` → `*FffResult` con handle
- `fff_destroy(handle)`

### Búsqueda
- `fff_search()` - Fuzzy file search
- `fff_live_grep()` - Grep con contexto
- `fff_multi_grep()` - Múltiples patrones

### Scanning
- `fff_scan_files()` - Iniciar scan en background
- `fff_is_scanning()` - Check estado
- `fff_wait_for_scan()` - Esperar con timeout
- `fff_get_scan_progress()` - Progreso

### Tracking
- `fff_track_query()` - Registrar selección para ML
- `fff_refresh_git_status()` - Actualizar estado git
- `fff_health_check()` - Verificar salud

### Memory
- `fff_free_result()` - Liberar resultados
- `fff_free_string()` - Liberar strings

## Integración TUI

El módulo `fff.odin` incluye helpers para integración TUI:

```odin
FffTuiState :: struct {
    finder: FileFinder,
    query: [dynamic]u8,
    results: FffSearchResult,
    selected_index: int,
}

fff_tui_init(&state, base_path)
fff_tui_update_query(&state, new_query)  // Llamar en cada keystroke
fff_tui_get_selected(state)  // Obtener selección actual
fff_tui_track_selection(state)  // Registrar para ML
fff_tui_cleanup(&state)
```

## Platform Support

| Plataforma | Estado | Método de obtención |
|------------|--------|---------------------|
| macOS arm64 | ✅ | npm, build from source |
| macOS x64 | ✅ | npm, build from source |
| Linux x64 | ✅ | npm, build from source |
| Linux arm64 | ✅ | npm, build from source |
| Windows x64 | ✅ | npm, build from source |

## Recursos

- **fff.nvim**: https://github.com/dmtrKovalenko/fff.nvim
- **Instalación MCP**: `curl -L https://dmtrkovalenko.dev/install-fff-mcp.sh | bash`
- **npm package**: `@ff-labs/fff-node`
- **Crate Rust**: `fff-c`

## Próximos Pasos Sugeridos

1. **Probar bindings**: Ejecutar script de descarga y compilar ejemplo
2. **Integrar TUI**: Crear nueva vista FFF_SEARCH en la TUI
3. **Caso de uso 1**: Búsqueda de comandos wayu
4. **Caso de uso 2**: Explorador de directorios para PATH
5. **Optimizar**: Caché de instancias finder para reutilización

## Ejemplo Completo

Ver `examples/fff_integration_example.odin` para ejemplos funcionales de:
- Búsqueda básica
- Live grep
- Integración TUI
- Búsqueda de comandos
