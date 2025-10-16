# TUI Box Generator - Documentación

Script de Python para generar y validar cajas TUI (Terminal User Interface) con dimensiones matemáticamente correctas.

## Propósito

Este script sirve para:

1. **Generar ejemplos para documentación** - Crear renders de cajas con dimensiones garantizadas
2. **Validar renders de la aplicación** - Verificar que wayu renderice correctamente
3. **Testing automatizado** - Parte del sistema de pruebas para el TUI

## Instalación

### Prerequisitos

```bash
# Instalar wcwidth para cálculo correcto de emoji y CJK
pip install wcwidth
```

## Uso

### 1. Generar una Caja Simple

```bash
python3 scripts/tui_box_generator.py generate \
  --content "Hello World" \
  --width 20 \
  --padding 2
```

**Salida:**
```
Box Configuration:
Box Dimensions:
  Content:  20
  Padding:  L=2 R=2 T=0 B=0
  Border:   1
  Total:    26

Rendered Box:
┌────────────────────────┐
│  Hello World           │
└────────────────────────┘

✅ All 3 lines have correct width: 26 visual columns
```

### 2. Generar Caja con Múltiples Líneas

```bash
python3 scripts/tui_box_generator.py generate \
  --content "Line 1" "Line 2" "Line 3" \
  --width 30 \
  --padding 2
```

### 3. Generar con Emoji

```bash
python3 scripts/tui_box_generator.py generate \
  --content "📂 PATH Management" "🔑 Aliases" "💾 Constants" \
  --width 40 \
  --padding 2
```

**Nota:** El script calcula correctamente el ancho visual de emoji (2 columnas).

### 4. Alineación del Contenido

```bash
# Alineación izquierda (default)
python3 scripts/tui_box_generator.py generate \
  --content "Text" --width 20 --alignment left

# Alineación centrada
python3 scripts/tui_box_generator.py generate \
  --content "Text" --width 20 --alignment center

# Alineación derecha
python3 scripts/tui_box_generator.py generate \
  --content "Text" --width 20 --alignment right
```

### 5. Generar Todos los Ejemplos de Documentación

```bash
# Genera todos los ejemplos para docs
python3 scripts/tui_box_generator.py generate-docs > docs/examples.md
```

Este comando genera:
- Ejemplo 1: Menú Principal (76 columnas)
- Ejemplo 2: Vista de PATH (76 columnas)
- Ejemplo 3: Caja Simple (13 columnas)
- Ejemplo 4: Caja con Padding (8 columnas)
- Ejemplo 5: Footer/Status Bar (76 columnas)

### 6. Validar un Archivo Renderizado

```bash
# Validar que un archivo tenga el ancho correcto
python3 scripts/tui_box_generator.py validate output.txt --expected-width 76
```

**Ejemplo de validación:**
```bash
# Capturar output de wayu TUI
./bin/wayu --tui > /tmp/wayu_output.txt

# Validar dimensiones
python3 scripts/tui_box_generator.py validate /tmp/wayu_output.txt --expected-width 76
```

## Algoritmo de Cálculo

### Fórmula de Dimensiones

```
total_width = content_width + horizontal_frame_size

donde:
    horizontal_frame_size = border_left + padding_left +
                           padding_right + border_right

Ejemplo:
    content_width = 70
    h_frame = 1 + 2 + 2 + 1 = 6
    total_width = 70 + 6 = 76
```

### Ancho Visual vs String Length

El script usa `wcwidth` para calcular correctamente:

| Carácter | `len()` Python | Ancho Visual | Diferencia |
|----------|----------------|--------------|------------|
| `a` | 1 | 1 | 0 |
| `📂` | 1 | 2 | +1 |
| `你` | 1 | 2 | +1 |
| `\033[32m` | 5 | 0 | -5 |

**Ejemplo:**
```python
text = "📂 PATH"
len(text)           # 6 (Python)
wcswidth(text)      # 7 (Visual en terminal)
```

Por eso el script usa `wcwidth` en lugar de `len()`.

## Estructura del Código

### Clase `TUIBox`

```python
box = TUIBox(
    content_width=70,      # Ancho del contenido
    padding_left=2,        # Padding izquierdo
    padding_right=2,       # Padding derecho
    padding_top=0,         # Padding superior
    padding_bottom=0,      # Padding inferior
    border_width=1,        # 0 = sin borde, 1 = borde simple
    margin_left=0,         # Margin izquierdo
    margin_right=0,        # Margin derecho
    margin_top=0,          # Margin superior
    margin_bottom=0,       # Margin inferior
)

# Renderizar
lines = ["Line 1", "Line 2"]
rendered = box.render(lines, alignment="left")

# Imprimir
for line in rendered:
    print(line)
```

### Métodos Principales

- `calculate_dimensions()` - Calcula frame size total
- `get_total_width()` - Ancho total incluyendo frame
- `get_interior_width()` - Ancho entre bordes
- `get_visual_width(text)` - Ancho visual con emoji/ANSI
- `render(lines)` - Renderiza la caja
- `print_dimensions()` - Muestra dimensiones para debug

### Función de Validación

```python
validate_box(lines, expected_width=76)
# Returns: True si todas las líneas tienen el ancho esperado
```

## Ejemplos de Testing

### Test 1: Validar Output de wayu TUI

```bash
#!/bin/bash
# test_tui_render.sh

# Ejecutar wayu TUI y capturar output
./bin/wayu --tui > /tmp/wayu_main_menu.txt <<EOF
q
EOF

# Validar dimensiones
python3 scripts/tui_box_generator.py validate \
  /tmp/wayu_main_menu.txt \
  --expected-width 76

if [ $? -eq 0 ]; then
  echo "✅ TUI render test passed"
else
  echo "❌ TUI render test failed"
  exit 1
fi
```

### Test 2: Comparar con Referencia

```bash
#!/bin/bash
# test_tui_reference.sh

# Generar referencia correcta
python3 scripts/tui_box_generator.py generate \
  --content "wayu v3.0" "Main Menu" \
  --width 70 --padding 2 > /tmp/reference.txt

# Comparar con output real
# (comparación visual o diff)
diff /tmp/reference.txt /tmp/wayu_output.txt
```

### Test 3: Probar Diferentes Anchos de Terminal

```bash
#!/bin/bash
# test_responsive_width.sh

# Simular diferentes anchos de terminal
for width in 80 100 120; do
  echo "Testing width: $width"

  COLUMNS=$width ./bin/wayu --tui > /tmp/wayu_${width}.txt <<EOF
q
EOF

  # Validar que no exceda el ancho
  max_line_width=$(wc -L < /tmp/wayu_${width}.txt)
  if [ $max_line_width -le $width ]; then
    echo "  ✅ Width $width OK (max: $max_line_width)"
  else
    echo "  ❌ Width $width FAIL (max: $max_line_width > $width)"
  fi
done
```

## Integración con Tests de wayu

### Estructura de Tests Propuesta

```
tests/
├── unit/                    # Tests unitarios en Odin
│   └── test_tui_render.odin
├── integration/             # Tests de integración
│   └── test_tui_workflow.odin
└── visual/                  # Tests visuales (nuevo)
    ├── test_tui_dimensions.sh
    ├── test_tui_alignment.sh
    └── references/          # Renders de referencia
        ├── main_menu.txt
        ├── path_view.txt
        └── alias_view.txt
```

### Test Unitario en Odin (Ejemplo)

```odin
// tests/unit/test_tui_render.odin

@(test)
test_render_main_menu_dimensions :: proc(t: ^testing.T) {
    menu := create_main_menu()
    rendered := render_main_menu(&menu)
    defer delete(rendered)

    // Exportar a archivo temporal
    write_to_file("/tmp/test_render.txt", rendered)

    // Validar con Python script
    result := os.system("python3 scripts/tui_box_generator.py validate /tmp/test_render.txt --expected-width 76")

    testing.expect(t, result == 0, "Main menu should have width 76")
}
```

### Test Visual Automatizado

```bash
#!/bin/bash
# tests/visual/test_all_views.sh

SCRIPT="python3 scripts/tui_box_generator.py"

# Generar referencias si no existen
if [ ! -d "tests/visual/references" ]; then
  mkdir -p tests/visual/references

  echo "Generando referencias..."
  $SCRIPT generate-docs > tests/visual/references/all_examples.md
fi

# Capturar renders reales
echo "Capturando renders de wayu..."
./bin/wayu --tui <<EOF > /tmp/wayu_main.txt
q
EOF

# Validar cada vista
echo "Validando dimensiones..."
$SCRIPT validate /tmp/wayu_main.txt --expected-width 76

if [ $? -eq 0 ]; then
  echo "✅ All visual tests passed"
else
  echo "❌ Visual tests failed"
  exit 1
fi
```

## Debugging

### Ver Dimensiones Detalladas

```python
from tui_box_generator import TUIBox

box = TUIBox(content_width=70, padding_left=2, padding_right=2)
box.print_dimensions()
```

**Output:**
```
Box Dimensions:
  Content:  70
  Padding:  L=2 R=2 T=0 B=0
  Border:   1
  Margin:   L=0 R=0 T=0 B=0
  Interior: 74
  H Frame:  6
  V Frame:  2
  Total:    76
```

### Verificar Ancho Visual de un String

```python
from tui_box_generator import TUIBox

box = TUIBox()
text = "📂 PATH Management"
width = box.get_visual_width(text)
print(f"Visual width: {width}")  # Visual width: 19 (emoji = 2 cols)
```

### Debug de Alineación

Si una caja se ve desalineada en el terminal:

1. **Capturar el output:**
   ```bash
   ./bin/wayu --tui > /tmp/debug.txt
   ```

2. **Ver con cat -A para caracteres especiales:**
   ```bash
   cat -A /tmp/debug.txt
   ```

3. **Validar con el script:**
   ```bash
   python3 scripts/tui_box_generator.py validate /tmp/debug.txt
   ```

4. **Ver diferencias línea por línea:**
   ```python
   with open('/tmp/debug.txt') as f:
       for i, line in enumerate(f):
           print(f"Line {i}: len={len(line)} visual={wcswidth(line)}")
   ```

## Problemas Comunes

### 1. Emoji se ven mal alineados

**Causa:** El terminal puede renderizar emoji con ancho diferente (1 vs 2 columnas).

**Solución:** Verificar configuración del terminal. La mayoría de terminales modernos usan 2 columnas para emoji.

**Test:**
```bash
echo "📂 test" | wc -m  # Cuenta caracteres
# vs
python3 -c "from wcwidth import wcswidth; print(wcswidth('📂 test'))"  # Ancho visual
```

### 2. Líneas con diferentes anchos

**Causa:** Probable bug en la lógica de padding.

**Solución:** Validar con el script:
```bash
python3 scripts/tui_box_generator.py validate archivo.txt
# Mostrará exactamente qué líneas tienen ancho incorrecto
```

### 3. Códigos ANSI aparecen en el render

**Causa:** Terminal no soporta ANSI o los códigos están mal formados.

**Solución:**
```bash
# Ver códigos ANSI
cat -A archivo.txt

# Limpiar ANSI para debug
sed 's/\x1b\[[0-9;]*m//g' archivo.txt
```

### 4. wcwidth no está instalado

**Causa:** Biblioteca no instalada.

**Solución:**
```bash
pip install wcwidth

# Verificar instalación
python3 -c "from wcwidth import wcswidth; print('OK')"
```

## Referencias

- **wcwidth:** https://github.com/jquast/wcwidth
- **Box Drawing Characters:** https://en.wikipedia.org/wiki/Box-drawing_character
- **ANSI Escape Codes:** https://en.wikipedia.org/wiki/ANSI_escape_code
- **Unicode Width:** https://www.unicode.org/reports/tr11/

## Licencia

Parte del proyecto wayu. Ver LICENSE en el directorio raíz.

---

**Última actualización:** 2025-10-15
**Versión:** 1.0.0
