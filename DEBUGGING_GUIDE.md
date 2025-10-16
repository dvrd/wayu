# Guía de Debugging para el TUI

## Problema Actual
El TUI está crasheando con error de malloc (double-free o use-after-free).

## Método 1: Usando LLDB (Recomendado)

Esto te dará el **stack trace exacto** donde ocurre el crash:

```bash
./run_lldb.sh
```

Cuando el programa crashee, lldb mostrará automáticamente:
- El backtrace (qué función estaba ejecutándose)
- Los registros del CPU
- La línea exacta del código

**Copia TODO el output** y compártelo.

## Método 2: Análisis de Memoria

```bash
./debug_memory.sh
```

Esto ejecuta el programa con guardas de memoria activadas para detectar:
- Double free
- Use after free
- Heap corruption
- Buffer overflow

## Método 3: LLDB Manual (Más Control)

```bash
# 1. Compila con debug
odin build ./src -out:./bin/wayu_debug -debug -o:none

# 2. Ejecuta lldb
lldb ./bin/wayu_debug

# 3. Dentro de lldb, ejecuta:
(lldb) run --tui

# 4. Cuando crashee, ejecuta:
(lldb) bt             # Muestra backtrace completo
(lldb) frame select 0 # Selecciona el frame del crash
(lldb) p *state       # Imprime el estado (si aplica)
(lldb) memory read $rsp -c 50  # Lee el stack

# 5. Para salir:
(lldb) quit
```

## Lo Que Necesito

Por favor ejecuta **Método 1 (./run_lldb.sh)** y comparte:

1. **El backtrace completo** - muestra la cadena de llamadas de funciones
2. **El mensaje de error** - exactamente qué dice malloc
3. **El exit code** - 134 (abort), 139 (segfault), etc.

Con esa información puedo identificar exactamente qué línea está causando el problema.

## Información Adicional

Si quieres más contexto, también puedes ejecutar:

```bash
# Ver todos los mallocs/frees
export MallocStackLogging=1
./bin/wayu_debug --tui 2>&1

# Cuando crashee, en otra terminal:
leaks wayu_debug
```

## Posibles Causas (Hipótesis)

Basado en el código, los lugares más probables de crash son:

1. **tui_state_destroy()** - libera el cache
2. **clear_view_cache()** - libera strings individuales
3. **screen_destroy()** - libera buffers 2D
4. **Defer statements** - el orden de cleanup puede estar mal

Pero necesito el backtrace para confirmarlo.
