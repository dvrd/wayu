# Integración de fff.nvim con wayu via FFI

## Resumen Ejecutivo

fff.nvim es un fuzzy finder ultrarrápido escrito en Rust que expone una API C/FFI. Proporciona:
- Búsqueda fuzzy de archivos con scoring avanzado (frecency, git status, etc.)
- Live grep con soporte para regex, fuzzy y plain text
- Multi-grep para múltiples patrones
- Indexación en background con notificaciones de progreso
- Memoria integrada (frecency) para mejorar resultados basados en uso

## Arquitectura FFI de fff

### Estructura de la Biblioteca

```
fff.nvim/
├── crates/
│   ├── fff-search/      # Core de búsqueda (rlib, staticlib, cdylib)
│   └── fff-c/           # Bindings C/FFI (expone libfff_c.{so,dylib,dll})
└── packages/
    └── fff-node/        # Ejemplo de uso desde Node.js via ffi-rs
```

### Convenciones de la API C

1. **Modelo basado en instancias**: Cada instancia tiene un handle opaco (`*mut c_void`)
2. **Todas las funciones devuelven `*mut FffResult`**: Estructura con campos:
   - `success: bool` - indicador de éxito
   - `data: *mut c_char` - string JSON con resultado (si aplica)
   - `error: *mut c_char` - mensaje de error si falló
   - `handle: *mut c_void` - handle a instancia/recurso
   - `int_value: i64` - valor entero de retorno
3. **Memoria**: El llamador debe liberar resultados con `fff_free_result()` y strings con `fff_free_string()`

### Funciones Principales Exportadas

```c
// Crear/Destruir instancia
*mut FffResult fff_create_instance(
    *const c_char base_path,
    *const c_char frecency_db_path,    // opcional
    *const c_char history_db_path,     // opcional
    bool use_unsafe_no_lock,
    bool warmup_mmap_cache,
    bool ai_mode
);
void fff_destroy(*mut c_void handle);

// Búsqueda fuzzy de archivos
*mut FffResult fff_search(
    *mut c_void handle,
    *const c_char query,
    u32 max_threads,        // 0 = auto
    *const c_char current_file,  // para depriorizar
    u32 combo_boost_multiplier,
    u32 min_combo_count,
    u32 page_index,
    u32 page_size
);

// Live grep
*mut FffResult fff_live_grep(
    *mut c_void handle,
    *const c_char query,
    u8 mode,                // 0=plain, 1=regex, 2=fuzzy
    *const c_char current_file,
    u32 max_results,
    u32 max_results_per_file,
    u32 context_lines,
    bool invert_match
);

// Multi-grep (múltiples patrones separados por \n)
*mut FffResult fff_multi_grep(
    *mut c_void handle,
    *const c_char patterns,  // "pattern1\npattern2\npattern3"
    u32 n_patterns,
    u32 max_results,
    u32 max_results_per_file
);

// Escanear y monitorear
*mut FffResult fff_scan_files(*mut c_void handle);
bool fff_is_scanning(*mut c_void handle);
*mut FffResult fff_get_scan_progress(*mut c_void handle);
*mut FffResult fff_wait_for_scan(*mut c_void handle, u32 timeout_ms);
*mut FffResult fff_restart_index(*mut c_void handle, *const c_char new_base_path);

// Git y tracking
*mut FffResult fff_refresh_git_status(*mut c_void handle);
*mut FffResult fff_track_query(*mut c_void handle, *const c_char query, *const c_char selected_path);
*mut FffResult fff_get_historical_query(*mut c_void handle, *const c_char query);

// Health check
*mut FffResult fff_health_check(*mut c_void handle);

// Liberar memoria
void fff_free_result(*mut FffResult result);
void fff_free_string(*mut c_char s);
```

## Opciones de Integración en wayu

### Opción 1: Wrapper FFI Nativo en Odin (Recomendado)

Crear un módulo `src/fff.odin` que declare las foreign functions y envuelva en procs idiomatic de Odin.

**Ventajas:**
- Sin dependencias externas
- Control total sobre la API
- Performance nativa
- Fácil distribución (solo binario + librería compartida)

**Desventajas:**
- Requiere mantener bindings manualmente si cambia la API

**Ejemplo de implementación:**

```odin
// src/fff.odin
package wayu

import "core:c"
import "core:fmt"
import "core:strings"
import "core:os"
import "core:encoding/json"

// ============================================================================
// Foreign Function Declarations
// ============================================================================

when ODIN_OS == .Darwin {
    foreign import fff "libfff_c.dylib"
} else when ODIN_OS == .Linux {
    foreign import fff "libfff_c.so"
} else when ODIN_OS == .Windows {
    foreign import fff "fff_c.dll"
}

FffResult :: struct {
    success:   c.bool,
    _padding:  [7]u8,      // alineación a 8 bytes
    data:      cstring,    // *mut c_char
    error:     cstring,    // *mut c_char
    handle:    rawptr,     // *mut c_void
    int_value: c.longlong,
}

FffInstance :: distinct rawptr

foreign fff {
    // Lifecycle
    fff_create_instance :: proc(
        base_path: cstring,
        frecency_db_path: cstring,
        history_db_path: cstring,
        use_unsafe_no_lock: c.bool,
        warmup_mmap_cache: c.bool,
        ai_mode: c.bool,
    ) -> ^FffResult ---
    
    fff_destroy :: proc(handle: rawptr) ---
    
    // Search
    fff_search :: proc(
        handle: rawptr,
        query: cstring,
        max_threads: c.uint,
        current_file: cstring,
        combo_boost_multiplier: c.uint,
        min_combo_count: c.uint,
        page_index: c.uint,
        page_size: c.uint,
    ) -> ^FffResult ---
    
    // Grep
    fff_live_grep :: proc(
        handle: rawptr,
        query: cstring,
        mode: c.uchar,
        current_file: cstring,
        max_results: c.uint,
        max_results_per_file: c.uint,
        context_lines: c.uint,
        invert_match: c.bool,
    ) -> ^FffResult ---
    
    fff_multi_grep :: proc(
        handle: rawptr,
        patterns: cstring,
        n_patterns: c.uint,
        max_results: c.uint,
        max_results_per_file: c.uint,
    ) -> ^FffResult ---
    
    // Scanning
    fff_scan_files :: proc(handle: rawptr) -> ^FffResult ---
    fff_is_scanning :: proc(handle: rawptr) -> c.bool ---
    fff_get_scan_progress :: proc(handle: rawptr) -> ^FffResult ---
    fff_wait_for_scan :: proc(handle: rawptr, timeout_ms: c.uint) -> ^FffResult ---
    fff_restart_index :: proc(handle: rawptr, new_base_path: cstring) -> ^FffResult ---
    
    // Git & tracking
    fff_refresh_git_status :: proc(handle: rawptr) -> ^FffResult ---
    fff_track_query :: proc(handle: rawptr, query: cstring, selected_path: cstring) -> ^FffResult ---
    fff_get_historical_query :: proc(handle: rawptr, query: cstring) -> ^FffResult ---
    
    // Health & memory
    fff_health_check :: proc(handle: rawptr) -> ^FffResult ---
    fff_free_result :: proc(result: ^FffResult) ---
    fff_free_string :: proc(s: cstring) ---
}

// ============================================================================
// Odin-idiomatic Wrapper API
// ============================================================================

FffError :: struct {
    message: string,
}

FffSearchResult :: struct {
    path: string,
    relative_path: string,
    file_name: string,
    size: u64,
    modified: u64,
    total_frecency_score: i64,
    git_status: string,
}

FffGrepMatch :: struct {
    file_path: string,
    line_number: u32,
    column: u32,
    match_text: string,
    context_before: []string,
    context_after: []string,
}

FileFinder :: struct {
    handle: FffInstance,
    base_path: string,
}

// Crear instancia de file finder
fff_create :: proc(base_path: string, ai_mode := true) -> (FileFinder, bool) {
    base_path_c := strings.clone_to_cstring(base_path)
    defer delete(base_path_c)
    
    // Opcional: usar db para frecency
    frecency_path := fmt.tprintf("{}/.cache/wayu/fff-frecency", os.get_env("HOME"))
    frecency_c := strings.clone_to_cstring(frecency_path)
    defer delete(frecency_c)
    
    result := fff_create_instance(
        base_path_c,
        frecency_c,      // frecency_db_path
        nil,             // history_db_path (opcional)
        false,           // use_unsafe_no_lock
        false,           // warmup_mmap_cache
        c.bool(ai_mode), // ai_mode
    )
    
    if result == nil {
        return FileFinder{}, false
    }
    defer fff_free_result(result)
    
    if !result.success {
        if result.error != nil {
            err_msg := string(result.error)
            fmt.eprintf("fff error: %s\n", err_msg)
        }
        return FileFinder{}, false
    }
    
    return FileFinder{
        handle = FffInstance(result.handle),
        base_path = strings.clone(base_path),
    }, true
}

// Destruir instancia
fff_destroy_finder :: proc(finder: ^FileFinder) {
    if finder.handle != nil {
        fff_destroy(rawptr(finder.handle))
        finder.handle = nil
    }
    delete(finder.base_path)
}

// Búsqueda fuzzy de archivos
fff_search_files :: proc(finder: FileFinder, query: string, current_file: string = "") -> ([]FffSearchResult, bool) {
    if finder.handle == nil {
        return nil, false
    }
    
    query_c := strings.clone_to_cstring(query)
    defer delete(query_c)
    
    current_c := strings.clone_to_cstring(current_file) if current_file != "" else cstring(nil)
    if current_file != "" {
        defer delete(current_c)
    }
    
    result := fff_search(
        rawptr(finder.handle),
        query_c,
        0,      // max_threads (auto)
        current_c,
        100,    // combo_boost_multiplier
        3,      // min_combo_count
        0,      // page_index
        50,     // page_size
    )
    
    if result == nil {
        return nil, false
    }
    defer fff_free_result(result)
    
    if !result.success {
        return nil, false
    }
    
    // Parsear JSON de resultado
    if result.data == nil {
        return nil, false
    }
    
    json_str := string(result.data)
    // TODO: parsear JSON y convertir a []FffSearchResult
    
    return nil, false
}

// Live grep
fff_grep :: proc(finder: FileFinder, query: string, mode := 0, max_results := 100) -> ([]FffGrepMatch, bool) {
    if finder.handle == nil {
        return nil, false
    }
    
    query_c := strings.clone_to_cstring(query)
    defer delete(query_c)
    
    result := fff_live_grep(
        rawptr(finder.handle),
        query_c,
        c.uchar(mode),  // 0=plain, 1=regex, 2=fuzzy
        nil,            // current_file
        c.uint(max_results),
        10,             // max_results_per_file
        2,              // context_lines
        false,          // invert_match
    )
    
    if result == nil {
        return nil, false
    }
    defer fff_free_result(result)
    
    if !result.success {
        return nil, false
    }
    
    // Parsear JSON
    return nil, false
}
```

### Opción 2: Uso como Proceso Externo (Alternativa Simple)

Si no queremos depender de la biblioteca compartida, podríamos usar el CLI de fff (si existe) o compilar un wrapper.

**Ventajas:**
- Más simple, sin FFI
- Aislamiento de procesos

**Desventajas:**
- Overhead de IPC
- No hay CLI standalone documentado para fff (es una biblioteca)

### Opción 3: Integración Parcial vía Dyncall (Experimental)

Usar dyncall para cargar la biblioteca dinámicamente en runtime.

**Ventajas:**
- Carga lazy de la biblioteca
- Graceful degradation si no está disponible

**Desventajas:**
- Más complejo
- Requiere dyncall bindings

## Estrategia de Build y Distribución

### Opción A: Librería Compartida del Sistema

Requiere que el usuario instale fff por separado:

```bash
# Instalación vía el script oficial de fff
curl -L https://dmtrkovalenko.dev/install-fff-mcp.sh | bash

# O compilar desde fuente
cd fff.nvim
cargo build --release -p fff-c
```

wayu detecta la librería en tiempo de ejecución.

### Opción B: Bundling de la Librería (Recomendado)

Incluir las librerías precompiladas en el repositorio de wayu:

```
wayu/
└── lib/
    ├── libfff_c.dylib    (macOS arm64/x64)
    ├── libfff_c.so       (Linux x64/arm64)
    └── fff_c.dll         (Windows)
```

El build script de wayu:
1. Detecta la plataforma
2. Copia la librería correspondiente a `bin/`
3. RPATH configurado para encontrarla

### Build Configuration para Odin

```bash
# macOS
odin build src -out:wayu \
    -extra-linker-flags:"-rpath @loader_path -L./lib -lfff_c"

# Linux  
odin build src -out:wayu \
    -extra-linker-flags:"-Wl,-rpath,'\$ORIGIN' -L./lib -lfff_c"
```

## Casos de Uso para wayu

### 1. Búsqueda Dinámica de Comandos

```odin
// En la TUI, permitir fuzzy search sobre todos los comandos disponibles
finder := fff_create("/usr/local/bin")
defer fff_destroy_finder(&finder)

// Usuario tipea "path" -> encuentra wayu-path, path_helper, etc.
results := fff_search_files(finder, query)
```

### 2. Exploración de Directorios para PATH

```odin
// Al agregar entradas al PATH, permitir fuzzy find de directorios
finder := fff_create("/home/user")
results := fff_search_files(finder, "proyectos/go/bin")
// Muestra coincidencias fuzzy mientras el usuario escribe
```

### 3. Búsqueda en Historial/Configuración

```odin
// Indexar ~/.config/wayu/ para búsqueda rápida
finder := fff_create(WAYU_CONFIG)
results := fff_search_files(finder, "alias git")
// Encuentra archivos de alias relacionados con git
```

### 4. Live Grep en Plugins

```odin
// Buscar en el código de plugins
finder := fff_create(PLUGIN_DIR)
matches := fff_grep(finder, "func handle_", mode=2) // fuzzy grep
```

## Plan de Implementación Sugerido

### Fase 1: FFI Wrapper Básico (2-3 días)
1. Crear `src/fff.odin` con foreign declarations
2. Implementar `fff_create`, `fff_destroy_finder`
3. Implementar `fff_search_files` con parsing JSON básico
4. Test manual con biblioteca precompilada

### Fase 2: Integración TUI (3-4 días)
1. Crear nueva vista `View_FFF_SEARCH` en TUI
2. Integrar con el sistema de input existente
3. Mostrar resultados en tiempo real mientras se escribe
4. Permitir selección con preview

### Fase 3: Casos de Uso Específicos (2-3 días)
1. Búsqueda de comandos wayu
2. Explorador de directorios para PATH
3. Búsqueda en configuración

### Fase 4: Build y Distribución (1-2 días)
1. Script de descarga de librerías precompiladas
2. Integración con Taskfile
3. Documentación

## Ejemplo de Uso Completo

```odin
package main

import "core:fmt"
import "core:os"

main :: proc() {
    // Crear finder para buscar comandos
    finder, ok := fff_create("/usr/local/bin", ai_mode=true)
    if !ok {
        fmt.eprintln("Failed to create file finder")
        os.exit(1)
    }
    defer fff_destroy_finder(&finder)
    
    // Esperar scan inicial
    fff_wait_for_scan(finder, 5000)
    
    // Búsqueda interactiva
    query := "git"
    results, found := fff_search_files(finder, query, page_size=10)
    if !found {
        fmt.println("No results found")
        return
    }
    defer fff_free_search_results(results)
    
    // Mostrar resultados
    for item in results {
        fmt.printf("%s (%s) - score: %d\n", 
            item.file_name, 
            item.relative_path,
            item.total_frecency_score)
    }
    
    // Grep en archivos encontrados
    grep_results, _ := fff_grep(finder, "main", mode=2)
    for match in grep_results {
        fmt.printf("%s:%d: %s\n", 
            match.file_path, 
            match.line_number,
            match.match_text)
    }
}
```

## Recursos

- **Repositorio**: https://github.com/dmtrKovalenko/fff.nvim
- **API C**: `crates/fff-c/src/lib.rs`
- **Ejemplo Node.js**: `packages/fff-node/src/ffi.ts`
- **Instalación**: `curl -L https://dmtrkovalenko.dev/install-fff-mcp.sh | bash`

## Notas Técnicas

1. **Seguridad de Memoria**: Siempre usar `defer fff_free_result()` después de cada llamada
2. **Null Pointers**: Verificar `result.success` antes de acceder a campos
3. **Strings C**: Convertir con `strings.clone_to_cstring()` y liberar después
4. **JSON**: Usar `core:encoding/json` para parsear resultados
5. **Hilos**: fff usa hilos internamente, no hay problema de blocking para wayu
6. **Señales**: La biblioteca maneja SIGINT/SIGTERM internamente
