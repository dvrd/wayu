#!/bin/bash
# Abrir Fontello con el SVG de Odin

echo "=== Abriendo Fontello para crear fuente Odin ==="
echo ""
echo "Pasos a seguir en la web:"
echo "1. Arrastra el archivo: ~/.config/wayu/icons/odin.svg"
echo "2. El icono aparecerá en 'Custom Icons'"
echo "3. Haz clic en el icono para seleccionarlo"
echo "4. Cambia el nombre a 'odin' y código a 'E0F0'"
echo "5. Click 'Download webfont' (botón rojo)"
echo "6. Instala la fuente descargada"
echo ""

# Abrir Fontello en navegador
open "https://fontello.com/"

# Mostrar ruta del SVG
echo "SVG listo en:"
ls -la ~/.config/wayu/icons/odin.svg
