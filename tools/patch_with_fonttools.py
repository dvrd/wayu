#!/usr/bin/env python3
"""
Agregar glifo a fuente usando fonttools
"""
import sys
import os
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib.tables import ttProgram

# Configuración
FONT_PATH = os.path.expanduser("~/Library/Fonts/BerkeleyMonoNerdFont-Regular.ttf")
OUTPUT_PATH = os.path.expanduser("~/Library/Fonts/BerkeleyMonoOdin-Regular.ttf")
UNICODE_CODE = 0xE0F0

def main():
    print("=== Agregando glifo Odin a fuente ===")
    
    font = TTFont(FONT_PATH)
    
    # Crear glifo
    glyph_set = font.getGlyphSet()
    pen = TTGlyphPen(glyph_set)
    
    # O estilizada
    pen.moveTo((50, 100))
    pen.lineTo((50, 450))
    pen.lineTo((100, 500))
    pen.lineTo((500, 500))
    pen.lineTo((550, 450))
    pen.lineTo((550, 100))
    pen.lineTo((500, 50))
    pen.lineTo((100, 50))
    pen.closePath()
    
    pen.moveTo((150, 150))
    pen.lineTo((450, 150))
    pen.lineTo((450, 450))
    pen.lineTo((150, 450))
    pen.closePath()
    
    glyph = pen.glyph()
    
    # Crear programa de hints
    prog = ttProgram.Program()
    prog.fromBytecode(b'')
    glyph.program = prog
    
    glyph_name = "uniE0F0"
    
    # Agregar
    font['glyf'][glyph_name] = glyph
    print(f"✓ Glifo agregado: {glyph_name}")
    
    for table in font['cmap'].tables:
        if table.platformID == 3:
            table.cmap[UNICODE_CODE] = glyph_name
            print(f"✓ Unicode: U+{UNICODE_CODE:04X}")
    
    font['hmtx'][glyph_name] = (600, 0)
    
    # Recalcular bounding boxes
    for name in font['glyf'].keys():
        glyph = font['glyf'][name]
        if hasattr(glyph, 'program') and glyph.program:
            glyph.recalcBounds(font['glyf'])
    
    font.save(OUTPUT_PATH)
    print(f"✓ Guardado: {OUTPUT_PATH}")
    print(f"\n📋 Usa: \\ue0f0")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
