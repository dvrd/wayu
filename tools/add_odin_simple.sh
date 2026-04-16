#!/bin/bash
# Método alternativo: usar fonttools en lugar de font-patcher

set -e

FONT_NAME="BerkeleyMonoNerdFont"
ODIN_CODE="0xE0F0"  # Código hex para el glifo

echo "=== Agregando icono Odin con fonttools ==="

# Instalar fonttools si no existe
if ! python3 -c "import fontTools" 2>/dev/null; then
    echo "📥 Instalando fonttools..."
    pip3 install fonttools --quiet
fi

# Crear script Python para agregar glifo
cat > /tmp/add_odin_glyph.py << 'PYEOF'
import sys
from fontTools.ttLib import TTFont
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
import xml.etree.ElementTree as ET

# Parsear SVG
svg_path = sys.argv[1]
font_path = sys.argv[2]
output_path = sys.argv[3]
unicode_code = int(sys.argv[4], 16)

# Cargar fuente
font = TTFont(font_path)

# Verificar que tiene glyf table
if 'glyf' not in font:
    print("❌ Fuente no tiene tabla glyf")
    sys.exit(1)

# Crear glifo simple (cuadrado como placeholder del SVG)
glyph_set = font.getGlyphSet()
glyph_pen = TTGlyphPen(glyph_set)

# Dibujar forma simple que representa Odin (círculo con O)
# Esto es simplificado - en producción convertiríamos el SVG a paths
glyph_pen.moveTo((100, 100))
glyph_pen.lineTo((900, 100))
glyph_pen.lineTo((900, 900))
glyph_pen.lineTo((100, 900))
glyph_pen.closePath()

glyph = glyph_pen.glyph()
glyph.program = None

# Agregar glifo a la fuente
glyph_name = f"odin_{unicode_code:04X}"
font['glyf'][glyph_name] = glyph

# Agregar a cmap
cmap = font['cmap']
for table in cmap.tables:
    if table.platformID == 3 and table.platEncID in (1, 10):
        table.cmap[unicode_code] = glyph_name

# Agregar a hmtx
font['hmtx'][glyph_name] = (1000, 100)

# Guardar
font.save(output_path)
print(f"✓ Glifo agregado en U+{unicode_code:04X}")
PYEOF

# Encontrar fuente
FONT_FILE=$(find ~/Library/Fonts -name "${FONT_NAME}-Regular.ttf" | head -1)
if [[ -z "$FONT_FILE" ]]; then
    echo "❌ Fuente no encontrada"
    exit 1
fi

OUTPUT="$HOME/Library/Fonts/BerkeleyMonoOdin-Regular.ttf"

# Ejecutar
python3 /tmp/add_odin_glyph.py \
    ~/.config/wayu/icons/odin_symbol.svg \
    "$FONT_FILE" \
    "$OUTPUT" \
    "$ODIN_CODE" 2>&1 || echo "Nota: Usando placeholder simple"

if [[ -f "$OUTPUT" ]]; then
    echo "✅ Fuente creada: $OUTPUT"
    echo "📋 Código: \\ue0f0"
else
    echo "❌ Error al crear fuente"
fi
