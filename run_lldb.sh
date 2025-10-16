#!/bin/bash
# Script para ejecutar el TUI bajo lldb y capturar el crash

echo "=== Ejecutando TUI bajo LLDB ==="
echo ""
echo "Compilando con símbolos de debug..."
odin build ./src -out:./bin/wayu_debug -debug -o:none

echo ""
echo "Iniciando lldb..."
echo "Comandos que se ejecutarán:"
echo "  1. run --tui"
echo "  2. bt (backtrace cuando crashee)"
echo ""
echo "Presiona Enter para continuar..."
read

lldb -o "run --tui" -o "bt" -o "register read" -o "frame info" ./bin/wayu_debug

echo ""
echo "=== Fin de LLDB ==="
