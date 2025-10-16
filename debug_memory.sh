#!/bin/bash
# Script para detectar problemas de memoria en el TUI

echo "=== Análisis de Memoria del TUI ==="
echo ""

# Compilar con debug
echo "1. Compilando con símbolos de debug..."
odin build ./src -out:./bin/wayu_debug -debug -o:none
echo "   ✓ Compilado"
echo ""

# Ejecutar con MallocStackLogging para capturar stack traces
echo "2. Ejecutando con MallocStackLogging..."
echo "   (El programa se ejecutará y crasheará si hay problemas)"
echo ""

export MallocStackLogging=1
export MallocScribble=1
export MallocPreScribble=1
export MallocGuardEdges=1

# Ejecutar y capturar el crash
timeout 3s ./bin/wayu_debug --tui 2>&1

EXIT_CODE=$?

echo ""
echo "--- Resultado del análisis ---"
echo "Exit code: $EXIT_CODE"

if [ $EXIT_CODE -eq 134 ]; then
    echo "❌ ABORT detectado - Error de memoria confirmado"
    echo ""
    echo "Posibles causas:"
    echo "  - Double free"
    echo "  - Use after free"
    echo "  - Heap corruption"
    echo "  - Buffer overflow"
elif [ $EXIT_CODE -eq 139 ]; then
    echo "❌ SEGFAULT detectado"
elif [ $EXIT_CODE -eq 124 ]; then
    echo "⚠️  Timeout - puede estar funcionando o colgado"
else
    echo "Salió con código: $EXIT_CODE"
fi

echo ""
echo "=== Para más información, ejecuta: ==="
echo "lldb ./bin/wayu_debug"
echo "  (lldb) run --tui"
echo "  (cuando crashee, escribe 'bt' para ver stack trace)"
