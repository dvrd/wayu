#!/bin/bash
# Parchear Berkeley Mono Nerd Font con icono OFICIAL de Odin

set -e

FONT_NAME="BerkeleyMonoNerdFont"
ODIN_CODE="E0F0"  # Código Private Use Area para Odin

echo "=== Parcheando Berkeley Mono con icono OFICIAL de Odin ==="

# 1. Usar SVG del símbolo Odin (solo la O, sin fondo azul)
# El símbolo está en: ~/.config/wayu/icons/odin_symbol.svg
SVG_FILE="/Users/kakurega/dev/projects/wayu/icons/odin_symbol.svg"

if [[ ! -f "$SVG_FILE" ]]; then
    echo "❌ No se encontró odin_symbol.svg"
    echo "Debe estar en: $SVG_FILE"
    exit 1
fi

echo "✓ Usando símbolo Odin (solo la O estilizada, sin fondo)"

# 2. Buscar fuente Berkeley Mono
FONT_FILE=$(find ~/Library/Fonts -name "${FONT_NAME}-Regular.ttf" -o -name "${FONT_NAME}-Regular.otf" 2>/dev/null | head -1)

if [[ -z "$FONT_FILE" ]]; then
    echo "❌ No se encontró Berkeley Mono Regular"
    echo "Fuentes disponibles:"
    ls ~/Library/Fonts | grep -i berkeley || echo "Ninguna"
    exit 1
fi

echo "✓ Fuente encontrada: $(basename "$FONT_FILE")"

# 3. Descargar font-patcher si no existe
if ! command -v font-patcher &> /dev/null; then
    echo "📥 Descargando font-patcher..."
    curl -L -o /tmp/FontPatcher.zip \
        "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.2.1/FontPatcher.zip" 2>/dev/null
    unzip -q -o /tmp/FontPatcher.zip -d /tmp/font-patcher
    chmod +x /tmp/font-patcher/font-patcher
    FONT_PATCHER="/tmp/font-patcher/font-patcher"
else
    FONT_PATCHER="font-patcher"
fi

# Configurar PYTHONPATH para fontforge en macOS
if [[ "$OSTYPE" == "darwin"* ]]; then
    # Encontrar el site-packages donde está fontforge.so (no solo cualquiera)
    FONTFORGE_SO=$(find /opt/homebrew/lib -name "fontforge.so" 2>/dev/null | head -1)
    if [[ -n "$FONTFORGE_SO" ]]; then
        FONTFORGE_PY=$(dirname "$FONTFORGE_SO")
        export PYTHONPATH="$FONTFORGE_PY:$PYTHONPATH"
        echo "✓ Python path configurado: $FONTFORGE_PY"
    fi
fi

# 4. Parchear fuente
OUTPUT_DIR="$HOME/Library/Fonts"
echo "🎨 Parcheando fuente (puede tardar 1-2 minutos)..."

cd "$OUTPUT_DIR"
$FONT_PATCHER \
    --complete \
    --custom "$SVG_FILE" \
    --name "BerkeleyMonoOdin" \
    --outputdir "$OUTPUT_DIR" \
    "$FONT_FILE" 2>&1 | tail -10

# 5. Verificar resultado
PATCHED=$(find "$OUTPUT_DIR" -name "*BerkeleyMonoOdin*" 2>/dev/null | head -1)

if [[ -n "$PATCHED" ]]; then
    echo ""
    echo "✅ ¡Fuente parcheada exitosamente!"
    echo "   Archivo: $(basename "$PATCHED")"
    echo ""
    echo "📋 Configuración para wayu.toml:"
    echo "   odin = { format = \"{dir}{git_branch}\\u$ODIN_CODE {character}\", ... }"
    echo ""
    echo "🔧 El icono se asignó al código: \\u$ODIN_CODE"
    echo ""
    echo "⚠️  PASOS FINALES:"
    echo "   1. Cierra y abre tu terminal (iTerm2/Terminal)"
    echo "   2. Cambia la fuente a: BerkeleyMonoOdin Nerd Font"
    echo "   3. Recarga zsh: exec zsh"
    echo ""
    echo "   El icono de Odin aparecerá en proyectos Odin como:"
    echo "   ~/dev/wayu main  dev-2026-04 ❯"
else
    echo "❌ Error al crear fuente parcheada"
    exit 1
fi
