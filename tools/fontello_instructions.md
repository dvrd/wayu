# Crear fuente Odin con Fontello (Web)

## Pasos:

1. Ve a https://fontello.com/

2. Arrastra el archivo `~/.config/wayu/icons/odin_symbol.svg` a la página

3. Selecciona el icono (aparecerá en la sección "Custom Icons")

4. Clic en el nombre del icono (por defecto es "icon-1") y cámbialo a:
   - Nombre: `odin`
   - Código: `E0F0` (hex)

5. Clic en "Download webfont" (botón rojo arriba)

6. Descomprime el ZIP descargado

7. Instala la fuente:
   ```bash
   cp fontello-*/fontello.ttf ~/Library/Fonts/BerkeleyMonoOdin.ttf
   ```

8. En tu terminal (iTerm2), cambia la fuente a "BerkeleyMonoOdin"

9. El icono aparecerá con el código `\ue0f0`

## Configuración wayu.toml:
```toml
odin = { format = "{dir}{git_branch}\ue0f0 {character}", detect = ["ols.json", "*.odin"] }
```
