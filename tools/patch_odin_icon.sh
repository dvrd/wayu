#!/bin/bash
# Script para parchear fuente Nerd Font con icono de Odin
# Requiere: font-patcher de Nerd Fonts, Python3, fontforge

set -e

FONT_NAME="${1:-JetBrainsMono}"
FONT_VARIANT="${2:-Regular}"
ODIN_ICON_CODE="${3:-E0F0}"  # Código en Private Use Area

echo "=== Parcheando fuente con icono de Odin ==="
echo "Fuente: $FONT_NAME $FONT_VARIANT"
echo "Código icono: $ODIN_ICON_CODE"

# 1. Verificar dependencias
if ! command -v font-patcher &> /dev/null; then
    echo "❌ font-patcher no encontrado"
    echo "Descargando..."
    
    # Descargar font-patcher
    PATCHER_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/FontPatcher.zip"
    curl -L -o /tmp/FontPatcher.zip "$PATCHER_URL"
    unzip -o /tmp/FontPatcher.zip -d /tmp/font-patcher
    chmod +x /tmp/font-patcher/font-patcher
    FONT_PATCHER="/tmp/font-patcher/font-patcher"
else
    FONT_PATCHER="font-patcher"
fi

# 2. Crear SVG del icono de Odin (martillo estilizado)
mkdir -p ~/.config/wayu/icons

cat > ~/.config/wayu/icons/odin.svg << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg width="24" height="24" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
  <!-- Martillo de Odin estilizado -->
  <path d="M12 2L14 6H10L12 2Z" fill="currentColor"/>
  <rect x="11" y="6" width="2" height="12" fill="currentColor"/>
  <path d="M8 18H16V20H8V18Z" fill="currentColor"/>
  <circle cx="12" cy="21" r="1.5" fill="currentColor"/>
</svg>
EOF

echo "✓ Icono SVG creado en ~/.config/wayu/icons/odin.svg"

# 3. Encontrar la fuente
if [[ "$OSTYPE" == "darwin"* ]]; then
    FONT_DIR="$HOME/Library/Fonts"
else
    FONT_DIR="$HOME/.local/share/fonts"
fi

# Buscar fuente
FONT_FILE=$(find "$FONT_DIR" -name "*${FONT_NAME}*${FONT_VARIANT}*.ttf" -o -name "*${FONT_NAME}*${FONT_VARIANT}*.otf" 2>/dev/null | head -1)

if [[ -z "$FONT_FILE" ]]; then
    echo "❌ Fuente no encontrada en $FONT_DIR"
    echo "Descargando $FONT_NAME..."
    
    # Descargar JetBrains Mono si no existe
    JETBRAINS_URL="https://github.com/JetBrains/JetBrainsMono/releases/latest/download/JetBrainsMono-2.304.zip"
    curl -L -o /tmp/jetbrains.zip "$JETBRAINS_URL"
    unzip -o /tmp/jetbrains.zip -d /tmp/jetbrains
    
    mkdir -p "$FONT_DIR"
    cp /tmp/jetbrains/fonts/ttf/*${FONT_VARIANT}*.ttf "$FONT_DIR/" 2>/dev/null || \
    cp /tmp/jetbrains/fonts/ttf/*.ttf "$FONT_DIR/"
    
    FONT_FILE=$(find "$FONT_DIR" -name "*${FONT_NAME}*${FONT_VARIANT}*.ttf" 2>/dev/null | head -1)
fi

if [[ -z "$FONT_FILE" ]]; then
    echo "❌ No se pudo encontrar o descargar la fuente"
    exit 1
fi

echo "✓ Fuente encontrada: $FONT_FILE"

# 4. Parchear con el icono personalizado
OUTPUT_DIR="$HOME/.local/share/fonts/NerdFontsCustom"
mkdir -p "$OUTPUT_DIR"

echo "🎨 Parcheando fuente..."
$FONT_PATCHER \
    --complete \
    --custom ~/.config/wayu/icons/odin.svg \
    --name "${FONT_NAME}Odin" \
    --outputdir "$OUTPUT_DIR" \
    "$FONT_FILE"

# 5. Resultado
PATCHED_FONT=$(find "$OUTPUT_DIR" -name "*${FONT_NAME}*Nerd*" | head -1)

if [[ -n "$PATCHED_FONT" ]]; then
    echo ""
    echo "✅ Fuente parcheada creada:"
    echo "   $PATCHED_FONT"
    echo ""
    echo "📋 Para usar el icono en wayu.toml:"
    echo "   odin = { format = \"{dir}{git_branch}\\u$ODIN_ICON_CODE {character}\", ... }"
    echo ""
    echo "📝 O en el prompt:"
    echo "   echo -e \"\\u$ODIN_ICON_CODE Odin\""
    echo ""
    echo "⚠️  Instala la fuente manualmente:"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "   cp \"$PATCHED_FONT\" ~/Library/Fonts/"
    else
        echo "   cp \"$PATCHED_FONT\" ~/.local/share/fonts/"
        echo "   fc-cache -fv"
    fi
else
    echo "❌ Error al parchear la fuente"
    exit 1
fi
